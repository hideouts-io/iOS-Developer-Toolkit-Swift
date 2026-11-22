import CSQLite
import CryptoKit
import Foundation
import ToolkitCore

public struct SecurityAcquisitionResult: Sendable {
    public let evidenceRoot: String
    public let acquisitionMethod: SecurityAcquisitionMethod
    public let observations: [EvidenceObservation]
    public let filesExamined: Int
    public let bytesExamined: Int64
    public let warnings: [String]

    public init(evidenceRoot: String, acquisitionMethod: SecurityAcquisitionMethod, observations: [EvidenceObservation], filesExamined: Int, bytesExamined: Int64, warnings: [String]) {
        self.evidenceRoot = evidenceRoot
        self.acquisitionMethod = acquisitionMethod
        self.observations = observations
        self.filesExamined = filesExamined
        self.bytesExamined = bytesExamined
        self.warnings = warnings
    }
}

private struct SecurityEvidenceFile: Sendable {
    let url: URL
    let logicalPath: String
    let artifactType: String
}

private struct SecurityTextValue {
    let field: String
    let value: String
    let wasTruncated: Bool
    let wasOmittedBinary: Bool
}

private final class ReadOnlySQLite {
    private var database: OpaquePointer?

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        let uri = url.standardizedFileURL.absoluteString + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed"
            if let database { sqlite3_close(database) }
            database = nil
            throw ToolkitError(.invalidInput, message: "Could not safely read the SQLite evidence file.", technicalDetail: "\(url.path): \(message)")
        }
        try execute("PRAGMA query_only = ON")
        try execute("PRAGMA trusted_schema = OFF")
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func rows(_ sql: String, bindings: [Int64]) throws -> (rows: [[String?]], omittedBLOBCells: Int) {
        guard let database else { throw ToolkitError(.internalInconsistency, message: "The SQLite evidence connection is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(database, context: "prepare", sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            guard sqlite3_bind_int64(statement, Int32(index + 1), value) == SQLITE_OK else {
                throw sqliteError(database, context: "bind", sql: sql)
            }
        }
        var result: [[String?]] = []
        var omittedBLOBCells = 0
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return (result, omittedBLOBCells) }
            guard status == SQLITE_ROW else { throw sqliteError(database, context: "read", sql: sql) }
            let count = sqlite3_column_count(statement)
            var row: [String?] = []
            row.reserveCapacity(Int(count))
            for index in 0..<count {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_NULL: row.append(nil)
                case SQLITE_INTEGER: row.append(String(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT: row.append(String(sqlite3_column_double(statement, index)))
                case SQLITE_TEXT:
                    let pointer = sqlite3_column_text(statement, index)
                    let byteCount = Int(sqlite3_column_bytes(statement, index))
                    if byteCount == 0 {
                        row.append("")
                    } else {
                        guard let pointer, let text = String(bytes: UnsafeBufferPointer(start: pointer, count: byteCount), encoding: .utf8) else {
                            throw ToolkitError(.invalidInput, message: "SQLite contains a text cell that is not valid UTF-8.")
                        }
                        row.append(text)
                    }
                case SQLITE_BLOB:
                    omittedBLOBCells += 1
                    row.append(nil)
                default:
                    throw ToolkitError(.invalidInput, message: "SQLite returned an unsupported column type.")
                }
            }
            result.append(row)
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw ToolkitError(.internalInconsistency, message: "The SQLite evidence connection is closed.") }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw sqliteError(database, context: "configure", sql: sql) }
    }

    private func sqliteError(_ database: OpaquePointer, context: String, sql: String) -> ToolkitError {
        ToolkitError(.invalidInput, message: "Could not safely read the SQLite evidence file.", technicalDetail: "SQLite \(context): \(String(cString: sqlite3_errmsg(database)))\nQuery: \(sql)")
    }
}

public enum SecurityEvidenceAcquisition {
    private static let textExtensions: Set<String> = ["txt", "log", "json", "jsonl", "xml", "html", "csv", "tsv", "ips", "crash", "mobileconfig", "plist"]
    private static let sqliteExtensions: Set<String> = ["db", "sqlite", "sqlite3", "sqlitedb", "storedata"]
    private static let maximumWarnings = 200

    public static func acquire(_ request: SecurityScanRequest, hashTypes: [SecurityIndicatorType]) throws -> SecurityAcquisitionResult {
        guard request.maximumFiles > 0, request.maximumFileBytes > 0, request.maximumTotalBytes > 0, request.maximumSQLiteRows > 0 else {
            throw ToolkitError.invalidInput("Security-analysis limits must all be positive.")
        }
        try Task.checkCancellation()
        let root = request.evidenceRoot.standardizedFileURL
        guard root.path.hasPrefix("/"), FileManager.default.fileExists(atPath: root.path) else {
            throw ToolkitError.invalidInput("The selected evidence path does not exist or is not absolute.")
        }
        let rootValues = try root.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isSymbolicLink != true else { throw ToolkitError.invalidInput("The selected evidence root must not be a symbolic link.") }
        if request.acquisitionMethod == .sysdiagnose, rootValues.isRegularFile == true {
            throw ToolkitError.invalidInput("Select an unpacked sysdiagnose folder. Archive extraction is intentionally not performed in the app.")
        }

        var warnings: [String] = []
        let files: [SecurityEvidenceFile]
        if request.acquisitionMethod == .backup {
            let result = try backupFiles(root: root, maximumFiles: request.maximumFiles)
            files = result.files
            warnings = result.warnings
        } else if rootValues.isDirectory == true {
            let result = try directoryFiles(root: root, maximumFiles: request.maximumFiles)
            files = result.files
            warnings = result.warnings
            if files.count >= request.maximumFiles { appendWarning("Evidence inventory stopped at the \(request.maximumFiles)-file safety limit.", to: &warnings) }
        } else if rootValues.isRegularFile == true {
            files = [SecurityEvidenceFile(url: root, logicalPath: root.lastPathComponent, artifactType: "imported-file")]
        } else {
            throw ToolkitError.invalidInput("The selected evidence path is not a regular file or folder.")
        }

        var walBases: Set<String> = []
        for file in files where file.logicalPath.hasSuffix("-wal") {
            if try hasNonEmptyWAL(at: file.url) {
                walBases.insert(String(file.logicalPath.dropLast(4)))
            }
        }
        if rootValues.isRegularFile == true, let file = files.first,
           try hasNonEmptyWAL(at: URL(fileURLWithPath: file.url.path + "-wal")) {
            walBases.insert(file.logicalPath)
        }
        for file in files where walBases.contains(file.logicalPath) {
            appendWarning("SQLite WAL companion for \(file.logicalPath) was not applied; uncheckpointed rows may be missing and content coverage is incomplete.", to: &warnings)
        }

        let algorithms = Array(Set(hashTypes.compactMap(hashAlgorithm))).sorted()
        var observations: [EvidenceObservation] = []
        var bytesExamined: Int64 = 0
        var filesExamined = 0
        for file in files {
            try Task.checkCancellation()
            let size: Int64
            do { size = Int64(try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            catch { appendWarning("Could not read metadata for \(file.logicalPath): \(error.localizedDescription)", to: &warnings); continue }
            observations.append(contentsOf: pathObservations(file, method: request.acquisitionMethod))
            guard size <= request.maximumFileBytes else {
                appendWarning("Skipped content for \(file.logicalPath): \(size) bytes exceeds the per-file limit.", to: &warnings)
                continue
            }
            guard size <= request.maximumTotalBytes - bytesExamined else {
                appendWarning("Content acquisition stopped at the \(request.maximumTotalBytes)-byte total safety limit.", to: &warnings)
                break
            }
            do {
                let fileObservations = try contentObservations(file, method: request.acquisitionMethod, maximumSQLiteRows: request.maximumSQLiteRows, algorithms: algorithms)
                observations.append(contentsOf: fileObservations.observations)
                for warning in fileObservations.warnings { appendWarning(warning, to: &warnings) }
                bytesExamined += size
                filesExamined += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                appendWarning("Could not parse \(file.logicalPath): \((error as? ToolkitError)?.message ?? error.localizedDescription)", to: &warnings)
            }
        }
        return SecurityAcquisitionResult(evidenceRoot: root.path, acquisitionMethod: request.acquisitionMethod, observations: observations, filesExamined: filesExamined, bytesExamined: bytesExamined, warnings: warnings)
    }

    private static func directoryFiles(root: URL, maximumFiles: Int) throws -> (files: [SecurityEvidenceFile], warnings: [String]) {
        let rootPath = root.resolvingSymlinksInPath().path
        var warnings: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { url, error in
            appendWarning("Could not enumerate \(url.lastPathComponent): \(error.localizedDescription)", to: &warnings)
            return true
        }) else {
            throw ToolkitError.fileSystem("Could not enumerate the evidence folder.", path: root.path)
        }
        var files: [SecurityEvidenceFile] = []
        for case let candidate as URL in enumerator {
            try Task.checkCancellation()
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                appendWarning("Skipped \(candidate.lastPathComponent): symbolic links are not accepted as evidence.", to: &warnings)
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let resolved = candidate.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(rootPath + "/") else { throw ToolkitError.invalidInput("An evidence path escaped the selected folder.") }
            files.append(SecurityEvidenceFile(url: resolved, logicalPath: String(resolved.path.dropFirst(rootPath.count + 1)), artifactType: "file"))
            if files.count >= maximumFiles { break }
        }
        return (files.sorted { $0.logicalPath < $1.logicalPath }, warnings)
    }

    private static func backupFiles(root: URL, maximumFiles: Int) throws -> (files: [SecurityEvidenceFile], warnings: [String]) {
        let rootPath = root.resolvingSymlinksInPath().path
        let manifest = root.appendingPathComponent("Manifest.db")
        let info = root.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: manifest.path), FileManager.default.fileExists(atPath: info.path) else {
            throw ToolkitError.invalidInput("Backup analysis requires a decrypted iTunes-style backup containing Manifest.db and Info.plist.")
        }
        for requiredFile in [manifest, info] {
            let values = try requiredFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ToolkitError.invalidInput("Backup analysis requires \(requiredFile.lastPathComponent) to be a regular file, not a symbolic link.")
            }
        }
        if try hasNonEmptyWAL(at: root.appendingPathComponent("Manifest.db-wal")) {
            throw ToolkitError(
                .invalidInput,
                message: "Backup inventory cannot be verified while a nonempty Manifest.db-wal is present.",
                recovery: "Provide a consistent backup snapshot with a checkpointed Manifest.db, then scan it again."
            )
        }
        var files = Array([
            SecurityEvidenceFile(url: info, logicalPath: "Info.plist", artifactType: "backup-metadata"),
            SecurityEvidenceFile(url: manifest, logicalPath: "Manifest.db", artifactType: "backup-manifest"),
        ].prefix(maximumFiles))
        var warnings: [String] = []
        guard files.count < maximumFiles else {
            appendWarning("Backup inventory stopped at the \(maximumFiles)-file safety limit.", to: &warnings)
            return (files, warnings)
        }
        let database = try ReadOnlySQLite(url: manifest)
        var missingPayloadCount = 0
        var firstMissingPath: String?
        let inventoryQueryLimit = maximumFiles == Int.max ? Int64.max : Int64(maximumFiles + 1)
        let manifestRows = try database.rows("SELECT fileID, domain, relativePath FROM Files WHERE flags = 1 LIMIT ?", bindings: [inventoryQueryLimit]).rows
        for (index, row) in manifestRows.enumerated() {
            try Task.checkCancellation()
            if index == maximumFiles {
                appendWarning("Backup inventory stopped at the \(maximumFiles)-file safety limit; additional Manifest.db rows were not examined.", to: &warnings)
                break
            }
            guard row.count == 3, let fileID = row[0], let domain = row[1], let relativePath = row[2], validBackupFileID(fileID) else {
                appendWarning("Skipped a Manifest.db row with an unsafe or malformed fileID.", to: &warnings)
                continue
            }
            guard validBackupLogicalPath(domain: domain, relativePath: relativePath) else {
                appendWarning("Skipped backup file \(fileID): its logical domain or relative path is unsafe or malformed.", to: &warnings)
                continue
            }
            let candidate = root.appendingPathComponent(String(fileID.prefix(2))).appendingPathComponent(fileID).standardizedFileURL
            guard candidate.path.hasPrefix(root.path + "/") else { appendWarning("Skipped backup file \(fileID): path escapes the backup root.", to: &warnings); continue }
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                missingPayloadCount += 1
                if firstMissingPath == nil { firstMissingPath = "\(domain)/\(relativePath)" }
                continue
            }
            let values: URLResourceValues
            do {
                values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            } catch {
                appendWarning("Could not inspect backup file \(fileID): \(error.localizedDescription)", to: &warnings)
                continue
            }
            guard values.isRegularFile == true else { appendWarning("Skipped backup file \(fileID): it is not a regular file.", to: &warnings); continue }
            guard values.isSymbolicLink != true else { appendWarning("Skipped backup file \(fileID): symbolic links are not accepted as evidence.", to: &warnings); continue }
            let bucketValues = try candidate.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey])
            let resolved = candidate.resolvingSymlinksInPath()
            guard bucketValues.isSymbolicLink != true, resolved.path.hasPrefix(rootPath + "/") else {
                appendWarning("Skipped backup file \(fileID): its path traverses a symbolic link or escapes the backup root.", to: &warnings)
                continue
            }
            files.append(SecurityEvidenceFile(url: resolved, logicalPath: "\(domain)/\(relativePath)", artifactType: "backup-artifact"))
            if files.count >= maximumFiles {
                if index + 1 < manifestRows.count {
                    appendWarning("Backup inventory stopped at the \(maximumFiles)-file safety limit; additional Manifest.db rows were not examined.", to: &warnings)
                }
                break
            }
        }
        if missingPayloadCount > 0 {
            warnings.insert("Missing \(missingPayloadCount) backup payload\(missingPayloadCount == 1 ? "" : "s") referenced by Manifest.db (first: \(firstMissingPath ?? "unknown")); content coverage is incomplete.", at: 0)
        }
        return (files, warnings)
    }

    /// Raw hashes describe the file independently of parser success. Backup filenames are storage
    /// identifiers, so format dispatch uses the validated logical path or a verified binary header.
    private static func contentObservations(_ file: SecurityEvidenceFile, method: SecurityAcquisitionMethod, maximumSQLiteRows: Int, algorithms: [String]) throws -> (observations: [EvidenceObservation], warnings: [String]) {
        try Task.checkCancellation()
        let ext = URL(fileURLWithPath: file.logicalPath).pathExtension.lowercased()
        let content = try Data(contentsOf: file.url, options: [.mappedIfSafe])
        try Task.checkCancellation()
        var observations = hashObservations(file, content: content, method: method, algorithms: algorithms)
        var warnings: [String] = []
        try Task.checkCancellation()
        do {
            if sqliteExtensions.contains(ext) || content.starts(with: Data("SQLite format 3\0".utf8)) {
                let parsed = try sqliteObservations(file, method: method, maximumRows: maximumSQLiteRows)
                observations.append(contentsOf: parsed.observations)
                warnings.append(contentsOf: parsed.warnings)
            } else if textExtensions.contains(ext) || content.starts(with: Data("bplist00".utf8)) {
                let parsed = try textObservations(file, content: content, method: method)
                observations.append(contentsOf: parsed.observations)
                warnings.append(contentsOf: parsed.warnings)
            } else {
                try Task.checkCancellation()
                return (observations, ["Content parsing is unsupported for \(file.logicalPath); only path metadata and requested raw hashes were acquired."])
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return (observations, ["Could not parse \(file.logicalPath): \((error as? ToolkitError)?.message ?? error.localizedDescription). Path metadata and requested raw hashes remain available; content coverage is incomplete."])
        }
        try Task.checkCancellation()
        return (observations, warnings)
    }

    private static func textObservations(_ file: SecurityEvidenceFile, content: Data, method: SecurityAcquisitionMethod) throws -> (observations: [EvidenceObservation], warnings: [String]) {
        let ext = URL(fileURLWithPath: file.logicalPath).pathExtension.lowercased()
        let values: [SecurityTextValue]
        if ext == "plist" || ext == "mobileconfig" || content.starts(with: Data("bplist00".utf8)) {
            let object = try PropertyListSerialization.propertyList(from: content, options: [], format: nil)
            values = flatten(object, prefix: "plist")
        } else if ext == "json" {
            let object = try JSONSerialization.jsonObject(with: content)
            values = flatten(object, prefix: "json")
        } else {
            guard let text = String(data: content, encoding: .utf8), !text.contains("\0") else {
                throw ToolkitError.invalidInput("The text evidence is not valid UTF-8 or contains binary NUL bytes.")
            }
            values = text.split(whereSeparator: \Character.isNewline).enumerated().map {
                SecurityTextValue(field: "line:\($0.offset + 1)", value: String($0.element.prefix(32_768)), wasTruncated: $0.element.count > 32_768, wasOmittedBinary: false)
            }
        }
        let truncatedCount = values.filter(\.wasTruncated).count
        let omittedBinaryCount = values.filter(\.wasOmittedBinary).count
        var warnings: [String] = []
        if truncatedCount > 0 { warnings.append("Truncated \(truncatedCount) text value\(truncatedCount == 1 ? "" : "s") in \(file.logicalPath) at the 32,768-character safety limit; content coverage is incomplete.") }
        if omittedBinaryCount > 0 { warnings.append("Omitted \(omittedBinaryCount) binary plist value\(omittedBinaryCount == 1 ? "" : "s") in \(file.logicalPath) above the 4,096-byte safety limit; content coverage is incomplete.") }
        let observations = values.filter { !$0.wasOmittedBinary }.map { entry in
            EvidenceObservation(artifactType: file.artifactType, artifactPath: file.logicalPath, sourceFile: file.url.path, observedType: "text", observedValue: entry.value, database: nil, table: nil, recordID: entry.field, timestamp: nil, acquisitionMethod: method)
        }
        return (observations, warnings)
    }

    private static func sqliteObservations(_ file: SecurityEvidenceFile, method: SecurityAcquisitionMethod, maximumRows: Int) throws -> (observations: [EvidenceObservation], warnings: [String]) {
        let database = try ReadOnlySQLite(url: file.url)
        let tables = try database.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name LIMIT 101", bindings: []).rows.compactMap { $0.first ?? nil }
        var observations: [EvidenceObservation] = []
        var warnings: [String] = []
        var remaining = maximumRows
        var truncatedValueCount = 0
        var omittedBLOBCells = 0
        var perTableLimitReached = false
        var totalRowBudgetReached = false
        if tables.count > 100 { warnings.append("SQLite table limit omitted one or more tables in \(file.logicalPath) after 100 tables; content coverage is incomplete.") }
        for table in tables.prefix(100) {
            try Task.checkCancellation()
            let quoted = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
            let columns = try database.rows("PRAGMA table_info(\(quoted))", bindings: []).rows.compactMap { $0.count > 1 ? $0[1] : nil }
            guard !columns.isEmpty else { continue }
            if remaining == 0 {
                if !(try database.rows("SELECT 1 FROM \(quoted) LIMIT 1", bindings: []).rows).isEmpty { totalRowBudgetReached = true }
                continue
            }
            let limit = min(remaining, 5_000)
            let query: (rows: [[String?]], omittedBLOBCells: Int)
            let hasRowID: Bool
            do { query = try database.rows("SELECT rowid, * FROM \(quoted) LIMIT ?", bindings: [Int64(limit + 1)]); hasRowID = true }
            catch is CancellationError { throw CancellationError() }
            catch { query = try database.rows("SELECT * FROM \(quoted) LIMIT ?", bindings: [Int64(limit + 1)]); hasRowID = false }
            let rows = query.rows
            omittedBLOBCells += query.omittedBLOBCells
            if rows.count > limit {
                if remaining <= 5_000 { totalRowBudgetReached = true }
                else { perTableLimitReached = true }
            }
            for (rowIndex, row) in rows.prefix(limit).enumerated() {
                try Task.checkCancellation()
                let values = hasRowID ? Array(row.dropFirst()) : row
                let recordID = hasRowID ? (row.first ?? nil) ?? String(rowIndex + 1) : String(rowIndex + 1)
                for (column, value) in zip(columns, values) {
                    guard let value, !value.isEmpty else { continue }
                    if value.count > 32_768 { truncatedValueCount += 1 }
                    observations.append(EvidenceObservation(artifactType: "sqlite-record", artifactPath: file.logicalPath, sourceFile: file.url.path, observedType: "text", observedValue: String(value.prefix(32_768)), database: file.logicalPath, table: table, recordID: "\(recordID):\(column)", timestamp: nil, acquisitionMethod: method))
                }
                remaining -= 1
            }
        }
        if perTableLimitReached { warnings.append("SQLite per-table row limit omitted rows in \(file.logicalPath) after 5,000 rows per table; content coverage is incomplete.") }
        if totalRowBudgetReached { warnings.append("SQLite total row budget omitted rows in \(file.logicalPath) after \(maximumRows) rows; content coverage is incomplete.") }
        if truncatedValueCount > 0 { warnings.append("Truncated \(truncatedValueCount) SQLite value\(truncatedValueCount == 1 ? "" : "s") in \(file.logicalPath) at the 32,768-character safety limit; content coverage is incomplete.") }
        if omittedBLOBCells > 0 { warnings.append("Omitted \(omittedBLOBCells) SQLite BLOB value\(omittedBLOBCells == 1 ? "" : "s") in \(file.logicalPath); content coverage is incomplete.") }
        return (observations, warnings)
    }

    private static func pathObservations(_ file: SecurityEvidenceFile, method: SecurityAcquisitionMethod) -> [EvidenceObservation] {
        [
            EvidenceObservation(artifactType: file.artifactType, artifactPath: file.logicalPath, sourceFile: file.url.path, observedType: "path", observedValue: file.logicalPath, database: nil, table: nil, recordID: nil, timestamp: nil, acquisitionMethod: method),
            EvidenceObservation(artifactType: file.artifactType, artifactPath: file.logicalPath, sourceFile: file.url.path, observedType: "filename", observedValue: URL(fileURLWithPath: file.logicalPath).lastPathComponent, database: nil, table: nil, recordID: nil, timestamp: nil, acquisitionMethod: method),
        ]
    }

    private static func hashObservations(_ file: SecurityEvidenceFile, content: Data, method: SecurityAcquisitionMethod, algorithms: [String]) -> [EvidenceObservation] {
        algorithms.map { algorithm in
            let digest: String
            switch algorithm {
            case "md5": digest = Insecure.MD5.hash(data: content).map { String(format: "%02x", $0) }.joined()
            case "sha1": digest = Insecure.SHA1.hash(data: content).map { String(format: "%02x", $0) }.joined()
            default: digest = SecureFileIO.sha256(of: content)
            }
            return EvidenceObservation(artifactType: file.artifactType, artifactPath: file.logicalPath, sourceFile: file.url.path, observedType: algorithm, observedValue: digest, database: nil, table: nil, recordID: nil, timestamp: nil, acquisitionMethod: method)
        }
    }

    private static func flatten(_ value: Any, prefix: String) -> [SecurityTextValue] {
        if let dictionary = value as? [String: Any] {
            return dictionary.sorted { $0.key < $1.key }.flatMap { key, value in
                flatten(value, prefix: prefix.isEmpty ? key : "\(prefix).\(key)")
            }
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { flatten($0.element, prefix: "\(prefix)[\($0.offset)]") }
        }
        if let data = value as? Data {
            if data.count <= 4_096 { return [SecurityTextValue(field: prefix, value: data.map { String(format: "%02x", $0) }.joined(), wasTruncated: false, wasOmittedBinary: false)] }
            return [SecurityTextValue(field: prefix, value: "[binary data omitted]", wasTruncated: false, wasOmittedBinary: true)]
        }
        if value is NSNull { return [] }
        let rendered = String(describing: value)
        return rendered.isEmpty ? [] : [SecurityTextValue(field: prefix, value: String(rendered.prefix(32_768)), wasTruncated: rendered.count > 32_768, wasOmittedBinary: false)]
    }

    private static func hashAlgorithm(_ type: SecurityIndicatorType) -> String? {
        switch type {
        case .md5: return "md5"
        case .sha1: return "sha1"
        case .sha256, .certificateSHA256: return "sha256"
        default: return nil
        }
    }

    private static func validBackupFileID(_ value: String) -> Bool {
        (40...64).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }

    private static func validBackupLogicalPath(domain: String, relativePath: String) -> Bool {
        !domain.isEmpty && !domain.contains("/") && !domain.contains("\0") && domain != "." && domain != ".."
            && !relativePath.isEmpty && !relativePath.hasPrefix("/") && !relativePath.contains("\0")
            && !relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    private static func appendWarning(_ warning: String, to warnings: inout [String]) {
        if warnings.count < maximumWarnings { warnings.append(warning) }
        else if warnings.count == maximumWarnings { warnings.append("Additional acquisition warnings were omitted after the 200-warning limit.") }
    }

    private static func hasNonEmptyWAL(at url: URL) throws -> Bool {
        var details = stat()
        if lstat(url.path, &details) == 0 {
            guard (details.st_mode & S_IFMT) == S_IFREG else {
                throw ToolkitError.invalidInput("The SQLite WAL companion at \(url.lastPathComponent) must be a regular file, not a symbolic link or special file.")
            }
            return details.st_size > 0
        }
        let code = errno
        if code == ENOENT { return false }
        throw ToolkitError.fileSystem("Could not inspect the SQLite WAL companion.", path: url.path, underlying: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
    }
}
