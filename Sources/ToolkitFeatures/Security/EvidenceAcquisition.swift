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

    func rows(_ sql: String, bindings: [Int64]) throws -> [[String?]] {
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
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
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
                    row.append(sqlite3_column_text(statement, index).map { String(cString: $0) })
                default: row.append(nil)
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
            guard bytesExamined + size <= request.maximumTotalBytes else {
                appendWarning("Content acquisition stopped at the \(request.maximumTotalBytes)-byte total safety limit.", to: &warnings)
                break
            }
            do {
                let fileObservations = try contentObservations(file, method: request.acquisitionMethod, maximumSQLiteRows: request.maximumSQLiteRows, algorithms: algorithms)
                observations.append(contentsOf: fileObservations)
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
        var files = [
            SecurityEvidenceFile(url: info, logicalPath: "Info.plist", artifactType: "backup-metadata"),
            SecurityEvidenceFile(url: manifest, logicalPath: "Manifest.db", artifactType: "backup-manifest"),
        ]
        var warnings: [String] = []
        let database = try ReadOnlySQLite(url: manifest)
        for row in try database.rows("SELECT fileID, domain, relativePath FROM Files WHERE flags = 1 LIMIT ?", bindings: [Int64(maximumFiles)]) {
            try Task.checkCancellation()
            guard row.count == 3, let fileID = row[0], let domain = row[1], let relativePath = row[2], validBackupFileID(fileID) else {
                appendWarning("Skipped a Manifest.db row with an unsafe or malformed fileID.", to: &warnings)
                continue
            }
            let candidate = root.appendingPathComponent(String(fileID.prefix(2))).appendingPathComponent(fileID).standardizedFileURL
            guard candidate.path.hasPrefix(root.path + "/") else { appendWarning("Skipped backup file \(fileID): path escapes the backup root.", to: &warnings); continue }
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            let values: URLResourceValues
            do {
                values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            } catch {
                appendWarning("Could not inspect backup file \(fileID): \(error.localizedDescription)", to: &warnings)
                continue
            }
            guard values.isRegularFile == true else { appendWarning("Skipped backup file \(fileID): it is not a regular file.", to: &warnings); continue }
            guard values.isSymbolicLink != true else { appendWarning("Skipped backup file \(fileID): symbolic links are not accepted as evidence.", to: &warnings); continue }
            files.append(SecurityEvidenceFile(url: candidate, logicalPath: "\(domain)/\(relativePath.drop(while: { $0 == "/" }))", artifactType: "backup-artifact"))
            if files.count >= maximumFiles {
                appendWarning("Backup inventory stopped at the \(maximumFiles)-file safety limit.", to: &warnings)
                break
            }
        }
        return (files, warnings)
    }

    private static func contentObservations(_ file: SecurityEvidenceFile, method: SecurityAcquisitionMethod, maximumSQLiteRows: Int, algorithms: [String]) throws -> [EvidenceObservation] {
        try Task.checkCancellation()
        let ext = file.url.pathExtension.lowercased()
        if sqliteExtensions.contains(ext) { return try sqliteObservations(file, method: method, maximumRows: maximumSQLiteRows) }
        guard textExtensions.contains(ext) || file.url.lastPathComponent == "Info.plist" || !algorithms.isEmpty else { return [] }
        let content = try Data(contentsOf: file.url, options: [.mappedIfSafe])
        var observations: [EvidenceObservation] = []
        if textExtensions.contains(ext) || file.url.lastPathComponent == "Info.plist" {
            observations.append(contentsOf: try textObservations(file, content: content, method: method))
        }
        observations.append(contentsOf: hashObservations(file, content: content, method: method, algorithms: algorithms))
        return observations
    }

    private static func textObservations(_ file: SecurityEvidenceFile, content: Data, method: SecurityAcquisitionMethod) throws -> [EvidenceObservation] {
        let ext = file.url.pathExtension.lowercased()
        let values: [(String, String)]
        if ext == "plist" || ext == "mobileconfig" || content.starts(with: Data("bplist00".utf8)) {
            let object = try PropertyListSerialization.propertyList(from: content, options: [], format: nil)
            values = flatten(object, prefix: "plist")
        } else if ext == "json" {
            let object = try JSONSerialization.jsonObject(with: content)
            values = flatten(object, prefix: "json")
        } else {
            values = String(decoding: content, as: UTF8.self).split(whereSeparator: \Character.isNewline).enumerated().map { ("line:\($0.offset + 1)", String($0.element.prefix(32_768))) }
        }
        return values.map { field, value in
            EvidenceObservation(artifactType: file.artifactType, artifactPath: file.logicalPath, sourceFile: file.url.path, observedType: "text", observedValue: value, database: nil, table: nil, recordID: field, timestamp: nil, acquisitionMethod: method)
        }
    }

    private static func sqliteObservations(_ file: SecurityEvidenceFile, method: SecurityAcquisitionMethod, maximumRows: Int) throws -> [EvidenceObservation] {
        let database = try ReadOnlySQLite(url: file.url)
        let tables = try database.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name LIMIT 100", bindings: []).compactMap { $0.first ?? nil }
        var observations: [EvidenceObservation] = []
        var remaining = maximumRows
        for table in tables where remaining > 0 {
            try Task.checkCancellation()
            let quoted = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
            let columns = try database.rows("PRAGMA table_info(\(quoted))", bindings: []).compactMap { $0.count > 1 ? $0[1] : nil }
            guard !columns.isEmpty else { continue }
            let limit = min(remaining, 5_000)
            let rows: [[String?]]
            let hasRowID: Bool
            do { rows = try database.rows("SELECT rowid, * FROM \(quoted) LIMIT ?", bindings: [Int64(limit)]); hasRowID = true }
            catch { rows = try database.rows("SELECT * FROM \(quoted) LIMIT ?", bindings: [Int64(limit)]); hasRowID = false }
            for (rowIndex, row) in rows.enumerated() {
                try Task.checkCancellation()
                let values = hasRowID ? Array(row.dropFirst()) : row
                let recordID = hasRowID ? (row.first ?? nil) ?? String(rowIndex + 1) : String(rowIndex + 1)
                for (column, value) in zip(columns, values) {
                    guard let value, !value.isEmpty else { continue }
                    observations.append(EvidenceObservation(artifactType: "sqlite-record", artifactPath: file.logicalPath, sourceFile: file.url.path, observedType: "text", observedValue: String(value.prefix(32_768)), database: file.logicalPath, table: table, recordID: "\(recordID):\(column)", timestamp: nil, acquisitionMethod: method))
                }
                remaining -= 1
                if remaining <= 0 { break }
            }
        }
        return observations
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

    private static func flatten(_ value: Any, prefix: String) -> [(String, String)] {
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().flatMap { key in flatten(dictionary[key] as Any, prefix: prefix.isEmpty ? key : "\(prefix).\(key)") }
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { flatten($0.element, prefix: "\(prefix)[\($0.offset)]") }
        }
        if let data = value as? Data, data.count <= 4_096 { return [(prefix, data.map { String(format: "%02x", $0) }.joined())] }
        if value is NSNull { return [] }
        let rendered = String(describing: value)
        return rendered.isEmpty ? [] : [(prefix, String(rendered.prefix(32_768)))]
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

    private static func appendWarning(_ warning: String, to warnings: inout [String]) {
        if warnings.count < maximumWarnings { warnings.append(warning) }
        else if warnings.count == maximumWarnings { warnings.append("Additional acquisition warnings were omitted after the 200-warning limit.") }
    }
}
