import CSQLite
import CryptoKit
import Foundation
import Testing
import ToolkitCore
@testable import ToolkitFeatures

@Suite("Backup Artifact Acquisition")
struct BackupArtifactAcquisitionTests {
    @Test func parsesExtensionlessMappedArtifactsAndHashesEveryRawFileWithoutChangingSources() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-artifacts")
        defer { try? FileManager.default.removeItem(at: root) }
        let sqlite = try payload(root, domain: "HomeDomain", relativePath: "Library/History.db")
        try createSQLite(sqlite.url, statements: ["CREATE TABLE Events (message TEXT)", "INSERT INTO Events VALUES ('sqlite.example')"])
        let plist = try payload(root, domain: "HomeDomain", relativePath: "Library/Preferences/network.plist")
        try SecureFileIO.writeNewFile(try PropertyListSerialization.data(fromPropertyList: ["Host": "plist.example"], format: .binary, options: 0), to: plist.url)
        let json = try payload(root, domain: "AppDomain-test", relativePath: "Documents/network.json")
        try SecureFileIO.writeNewFile(Data("{\"endpoint\":\"json.example\"}".utf8), to: json.url)
        let text = try payload(root, domain: "HomeDomain", relativePath: "Library/Logs/session.log")
        try SecureFileIO.writeNewFile(Data("text.example\nsecond.example\n".utf8), to: text.url)
        let xmlPlist = try payload(root, domain: "HomeDomain", relativePath: "Library/Preferences/xml.plist")
        try SecureFileIO.writeNewFile(try PropertyListSerialization.data(fromPropertyList: ["Host": "xml.example"], format: .xml, options: 0), to: xmlPlist.url)
        let payloads = [sqlite, plist, json, text, xmlPlist]
        try createBackupMetadata(root, payloads: payloads)
        let files = payloads.map(\.url) + [root.appendingPathComponent("Info.plist"), root.appendingPathComponent("Manifest.db")]
        let snapshots = try files.map { ($0, try Data(contentsOf: $0)) }

        let acquired = try SecurityEvidenceAcquisition.acquire(request(root, maximumFiles: 100, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 100), hashTypes: [.md5, .sha1, .sha256, .certificateSHA256])

        #expect(acquired.warnings.isEmpty)
        #expect(acquired.filesExamined == files.count)
        #expect(acquired.bytesExamined == snapshots.reduce(Int64(0)) { $0 + Int64($1.1.count) })
        #expect(payloads.allSatisfy { $0.url.pathExtension.isEmpty })
        #expect(acquired.observations.contains { $0.artifactPath == sqlite.logicalPath && $0.observedValue == "sqlite.example" && $0.database == sqlite.logicalPath && $0.table == "Events" && $0.recordID == "1:message" })
        #expect(acquired.observations.contains { $0.artifactPath == plist.logicalPath && $0.observedValue == "plist.example" && $0.recordID == "plist.Host" })
        #expect(acquired.observations.contains { $0.artifactPath == xmlPlist.logicalPath && $0.observedValue == "xml.example" && $0.recordID == "plist.Host" })
        #expect(acquired.observations.contains { $0.artifactPath == json.logicalPath && $0.observedValue == "json.example" && $0.recordID == "json.endpoint" })
        #expect(acquired.observations.contains { $0.artifactPath == text.logicalPath && $0.observedValue == "text.example" && $0.recordID == "line:1" })
        for (url, bytes) in snapshots {
            #expect(try Data(contentsOf: url) == bytes)
            let hashes = acquired.observations.filter { URL(fileURLWithPath: $0.sourceFile).resolvingSymlinksInPath() == url.resolvingSymlinksInPath() && ["md5", "sha1", "sha256"].contains($0.observedType) }
            #expect(hashes.count == 3)
            #expect(hashes.contains { $0.observedType == "md5" && $0.observedValue == hex(Insecure.MD5.hash(data: bytes)) })
            #expect(hashes.contains { $0.observedType == "sha1" && $0.observedValue == hex(Insecure.SHA1.hash(data: bytes)) })
            #expect(hashes.contains { $0.observedType == "sha256" && $0.observedValue == hex(SHA256.hash(data: bytes)) })
        }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == Set(["Info.plist", "Manifest.db"] + payloads.map { String($0.fileID.prefix(2)) }))
    }

    @Test func corruptAndUnsupportedArtifactsRetainHashesWithExplicitCoverageWarnings() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let json = try payload(root, domain: "HomeDomain", relativePath: "Library/broken.json")
        let sqlite = try payload(root, domain: "HomeDomain", relativePath: "Library/broken.db")
        let plist = try payload(root, domain: "HomeDomain", relativePath: "Library/broken.plist")
        let text = try payload(root, domain: "HomeDomain", relativePath: "Library/broken.txt")
        let unknown = try payload(root, domain: "HomeDomain", relativePath: "Library/unknown.bin")
        let payloads = [json, sqlite, plist, text, unknown]
        for file in payloads { try SecureFileIO.writeNewFile(Data([0xff, 0x00, 0x7b]), to: file.url) }
        try createBackupMetadata(root, payloads: payloads)

        let acquired = try SecurityEvidenceAcquisition.acquire(request(root, maximumFiles: 100, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 100), hashTypes: [.sha256])

        for file in payloads {
            #expect(acquired.warnings.contains { $0.contains(file.logicalPath) && ($0.contains("Could not parse") || $0.contains("unsupported")) })
            #expect(acquired.observations.contains { $0.artifactPath == file.logicalPath && $0.observedType == "sha256" && $0.observedValue == hex(SHA256.hash(data: Data([0xff, 0x00, 0x7b]))) })
            #expect(!acquired.observations.contains { $0.artifactPath == file.logicalPath && $0.observedType == "text" })
            #expect(try Data(contentsOf: file.url) == Data([0xff, 0x00, 0x7b]))
        }
    }

    @Test func mappedSQLiteWALKeepsRawHashesAndMarksReportsIncomplete() async throws {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-sqlite-wal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.db")
        try createSQLite(source, statements: ["CREATE TABLE Events (message TEXT)"])
        let snapshot = try walSnapshot(source, statements: ["INSERT INTO Events VALUES ('uncheckpointed.example')"])
        let backup = directory.appendingPathComponent("backup")
        try SecureFileIO.createPrivateDirectory(at: backup)
        let database = try payload(backup, domain: "HomeDomain", relativePath: "Library/History.db")
        let wal = try payload(backup, domain: "HomeDomain", relativePath: "Library/History.db-wal")
        try SecureFileIO.writeNewFile(snapshot.database, to: database.url)
        try SecureFileIO.writeNewFile(snapshot.wal, to: wal.url)
        try createBackupMetadata(backup, payloads: [database, wal])
        let scan = request(backup, maximumFiles: 100, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 100)

        let acquired = try SecurityEvidenceAcquisition.acquire(scan, hashTypes: [.sha256])

        #expect(!acquired.observations.contains { $0.artifactPath == database.logicalPath && $0.observedValue == "uncheckpointed.example" })
        #expect(acquired.warnings.contains { $0.contains(database.logicalPath) && $0.contains("WAL") && $0.contains("incomplete") })
        for (file, bytes) in [(database, snapshot.database), (wal, snapshot.wal)] {
            #expect(acquired.observations.contains { $0.artifactPath == file.logicalPath && $0.observedType == "sha256" && $0.observedValue == hex(SHA256.hash(data: bytes)) })
            #expect(try Data(contentsOf: file.url) == bytes)
        }

        let report = try await SecurityAnalysisEngine.analyze(scan)
        #expect(report.statusSummary.contains("coverage is incomplete"))
        #expect(report.acquisitionWarnings.contains { $0.contains(database.logicalPath) && $0.contains("WAL") })
        let exported = directory.appendingPathComponent("coverage.json")
        try SecurityReportWriter.write(report, format: .json, to: exported)
        let decoded = try JSONDecoder().decode(SecurityAnalysisReport.self, from: Data(contentsOf: exported))
        #expect(decoded.statusSummary.contains("coverage is incomplete"))
        #expect(decoded.acquisitionWarnings.contains { $0.contains(database.logicalPath) && $0.contains("WAL") })
    }

    @Test func uncheckpointedManifestWALFailsBeforeInventory() throws {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-manifest-wal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("manifest-source.db")
        try createSQLite(source, statements: ["CREATE TABLE Files (fileID TEXT, domain TEXT, relativePath TEXT, flags INTEGER)"])
        let snapshot = try walSnapshot(source, statements: ["INSERT INTO Files VALUES ('0123456789abcdef0123456789abcdef01234567', 'HomeDomain', 'Library/new.db', 1)"])
        let backup = directory.appendingPathComponent("backup")
        try SecureFileIO.createPrivateDirectory(at: backup)
        try SecureFileIO.writeNewFile(try PropertyListSerialization.data(fromPropertyList: ["Device Name": "Synthetic Test"], format: .xml, options: 0), to: backup.appendingPathComponent("Info.plist"))
        let manifest = backup.appendingPathComponent("Manifest.db")
        let wal = backup.appendingPathComponent("Manifest.db-wal")
        try SecureFileIO.writeNewFile(snapshot.database, to: manifest)
        try SecureFileIO.writeNewFile(snapshot.wal, to: wal)

        do {
            _ = try SecurityEvidenceAcquisition.acquire(request(backup, maximumFiles: 2, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 100), hashTypes: [])
            Issue.record("An uncheckpointed Manifest.db WAL unexpectedly produced a complete backup inventory.")
        } catch {
            let failure = try #require(error as? ToolkitError)
            #expect(failure.message.contains("Manifest.db-wal"))
            #expect(failure.message.contains("cannot be verified"))
        }
        #expect(try Data(contentsOf: manifest) == snapshot.database)
        #expect(try Data(contentsOf: wal) == snapshot.wal)
    }

    @Test func rejectsUnsafeLogicalPathsAndSymlinkedPayloadsAndBuckets() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-paths")
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("backup")
        try SecureFileIO.createPrivateDirectory(at: backup)
        let traversal = try payload(backup, domain: "HomeDomain", relativePath: "../outside.txt")
        let absolute = try payload(backup, domain: "HomeDomain", relativePath: "/outside.txt")
        let domain = try payload(backup, domain: "../HomeDomain", relativePath: "Library/invalid-domain.txt")
        let linkedFile = try payload(backup, domain: "HomeDomain", relativePath: "Library/linked.txt")
        let linkedBucket = try payload(backup, domain: "HomeDomain", relativePath: "Library/linked-bucket.txt")
        for file in [traversal, absolute, domain] { try SecureFileIO.writeNewFile(Data("rejected.example".utf8), to: file.url) }
        let outside = root.appendingPathComponent("outside.txt")
        try SecureFileIO.writeNewFile(Data("outside.example".utf8), to: outside)
        try FileManager.default.createSymbolicLink(at: linkedFile.url, withDestinationURL: outside)
        // This otherwise empty bucket is owned by this test; replace only that directory.
        let bucket = linkedBucket.url.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: bucket.path).isEmpty)
        try FileManager.default.removeItem(at: bucket)
        let outsideBucket = root.appendingPathComponent("outside-bucket")
        try SecureFileIO.createPrivateDirectory(at: outsideBucket)
        try SecureFileIO.writeNewFile(Data("outside-bucket.example".utf8), to: outsideBucket.appendingPathComponent(linkedBucket.fileID))
        try FileManager.default.createSymbolicLink(at: bucket, withDestinationURL: outsideBucket)
        let payloads = [traversal, absolute, domain, linkedFile, linkedBucket]
        try createBackupMetadata(backup, payloads: payloads)

        let acquired = try SecurityEvidenceAcquisition.acquire(request(backup, maximumFiles: 100, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 100), hashTypes: [.sha256])

        #expect(acquired.filesExamined == 2)
        for file in payloads { #expect(acquired.warnings.contains { $0.contains(file.fileID) }) }
        #expect(!acquired.observations.contains { $0.observedValue.contains("outside.example") || $0.observedValue.contains("outside-bucket.example") || $0.observedValue.contains("rejected.example") })
        #expect(!acquired.observations.contains { $0.sourceFile == outside.path || $0.sourceFile.hasPrefix(outsideBucket.path + "/") })
    }

    @Test func keepsInventoryByteAndSQLiteRowLimitsForMappedArtifacts() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-limits")
        defer { try? FileManager.default.removeItem(at: root) }
        let sqlite = try payload(root, domain: "HomeDomain", relativePath: "Library/History.db")
        try createSQLite(sqlite.url, statements: ["CREATE TABLE Events (message TEXT)", "INSERT INTO Events VALUES ('one.example'), ('two.example'), ('three.example')"])
        try createBackupMetadata(root, payloads: [sqlite])
        let inventory = try SecurityEvidenceAcquisition.acquire(request(root, maximumFiles: 1, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 1), hashTypes: [.sha256])
        #expect(inventory.filesExamined == 1)
        #expect(inventory.warnings.contains { $0.contains("1-file safety limit") })
        let rowLimited = try SecurityEvidenceAcquisition.acquire(request(root, maximumFiles: 100, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 1), hashTypes: [.sha256])
        #expect(rowLimited.observations.filter { $0.artifactPath == sqlite.logicalPath && $0.table == "Events" }.count == 1)
        #expect(rowLimited.observations.contains { $0.artifactPath == sqlite.logicalPath && $0.observedType == "sha256" })
        let fileLimited = try SecurityEvidenceAcquisition.acquire(request(root, maximumFiles: 100, maximumFileBytes: 100, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 100), hashTypes: [.sha256])
        #expect(!fileLimited.observations.contains { $0.artifactPath == sqlite.logicalPath && $0.observedType == "sha256" })
        #expect(fileLimited.warnings.contains { $0.contains(sqlite.logicalPath) && $0.contains("per-file limit") })
        let totalLimited = try SecurityEvidenceAcquisition.acquire(request(root, maximumFiles: 100, maximumFileBytes: 1_000_000, maximumTotalBytes: 1, maximumSQLiteRows: 100), hashTypes: [.sha256])
        #expect(totalLimited.filesExamined == 0)
        #expect(totalLimited.bytesExamined == 0)
        #expect(totalLimited.warnings.contains { $0.contains("total safety limit") })
    }

    @Test func missingPayloadAndTruncatedTextRemainIncompleteInEveryReportFormat() async throws {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-coverage-reports")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appendingPathComponent("backup")
        try SecureFileIO.createPrivateDirectory(at: backup)
        let missing = try payload(backup, domain: "HomeDomain", relativePath: "Library/missing.log")
        let text = try payload(backup, domain: "HomeDomain", relativePath: "Library/long.log")
        let exactText = try payload(backup, domain: "HomeDomain", relativePath: "Library/exact.log")
        let source = Data((String(repeating: "x", count: 32_769) + "\n").utf8)
        try SecureFileIO.writeNewFile(source, to: text.url)
        try SecureFileIO.writeNewFile(Data(String(repeating: "x", count: 32_768).utf8), to: exactText.url)
        try createBackupMetadata(backup, payloads: [missing, text, exactText])
        let scan = request(backup, maximumFiles: 100, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 100)

        let acquired = try SecurityEvidenceAcquisition.acquire(scan, hashTypes: [])
        #expect(acquired.filesExamined == 4)
        #expect(acquired.warnings.contains { $0.contains("Missing 1 backup payload") && $0.contains(missing.logicalPath) })
        #expect(acquired.warnings.contains { $0.contains("Truncated 1 text value") && $0.contains(text.logicalPath) })
        #expect(!acquired.warnings.contains { $0.contains("Truncated") && $0.contains(exactText.logicalPath) })
        #expect(acquired.observations.contains { $0.artifactPath == text.logicalPath && $0.recordID == "line:1" && $0.observedValue.count == 32_768 })
        #expect(acquired.observations.contains { $0.artifactPath == exactText.logicalPath && $0.recordID == "line:1" && $0.observedValue.count == 32_768 })
        #expect(!acquired.observations.contains { $0.artifactPath == missing.logicalPath })
        #expect(try Data(contentsOf: text.url) == source)

        let report = try await SecurityAnalysisEngine.analyze(scan)
        #expect(report.correlatedFindings.isEmpty)
        #expect(report.statusSummary.contains("coverage is incomplete"))
        #expect(report.acquisitionWarnings.contains { $0.contains("Missing 1 backup payload") && $0.contains(missing.logicalPath) })
        #expect(report.acquisitionWarnings.contains { $0.contains("Truncated 1 text value") && $0.contains(text.logicalPath) })
        for format in SecurityReportFormat.allCases {
            let destination = directory.appendingPathComponent("coverage.\(format.rawValue)")
            try SecurityReportWriter.write(report, format: format, to: destination)
            let data = try Data(contentsOf: destination)
            switch format {
            case .json:
                let decoded = try JSONDecoder().decode(SecurityAnalysisReport.self, from: data)
                #expect(decoded.statusSummary.contains("coverage is incomplete"))
                #expect(decoded.acquisitionWarnings.contains { $0.contains("Missing 1 backup payload") && $0.contains(missing.logicalPath) })
                #expect(decoded.acquisitionWarnings.contains { $0.contains("Truncated 1 text value") && $0.contains(text.logicalPath) })
            case .csv, .html:
                let output = try #require(String(data: data, encoding: .utf8))
                #expect(output.contains("Missing 1 backup payload"))
                #expect(output.contains("Truncated 1 text value"))
                #expect(output.contains("coverage is incomplete"))
                if format == .csv { #expect(output.contains("status_summary")) }
            }
        }
    }

    @Test func tableLimitReportsOnlyWhenMoreThanOneHundredTablesExist() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-table-coverage")
        defer { try? FileManager.default.removeItem(at: root) }
        let exact = try payload(root, domain: "HomeDomain", relativePath: "Library/exact.db")
        let overflow = try payload(root, domain: "HomeDomain", relativePath: "Library/overflow.db")
        let hundredTables = (0..<100).map { String(format: "CREATE TABLE T%03d (message TEXT)", $0) }
        try createSQLite(exact.url, statements: ["BEGIN"] + hundredTables + ["COMMIT"])
        try createSQLite(overflow.url, statements: ["BEGIN"] + hundredTables + ["CREATE TABLE T100 (message TEXT)", "INSERT INTO T100 VALUES ('unexamined.example')", "COMMIT"])
        try createBackupMetadata(root, payloads: [exact, overflow])

        let acquired = try SecurityEvidenceAcquisition.acquire(request(root, maximumFiles: 100, maximumFileBytes: 2_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 1_000), hashTypes: [])

        #expect(acquired.warnings.contains { $0.contains("SQLite table limit") && $0.contains(overflow.logicalPath) })
        #expect(!acquired.warnings.contains { $0.contains("SQLite table limit") && $0.contains(exact.logicalPath) })
        #expect(!acquired.observations.contains { $0.artifactPath == overflow.logicalPath && $0.observedValue == "unexamined.example" })
    }

    @Test func perTableRowLimitReportsOnlyWhenAdditionalRowsExist() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-table-rows")
        defer { try? FileManager.default.removeItem(at: root) }
        let exact = try payload(root, domain: "HomeDomain", relativePath: "Library/exact.db")
        let overflow = try payload(root, domain: "HomeDomain", relativePath: "Library/overflow.db")
        try createSQLite(exact.url, statements: rowStatements(count: 5_000))
        try createSQLite(overflow.url, statements: rowStatements(count: 5_001))
        try createBackupMetadata(root, payloads: [exact, overflow])

        let acquired = try SecurityEvidenceAcquisition.acquire(request(root, maximumFiles: 100, maximumFileBytes: 2_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 6_000), hashTypes: [])

        #expect(acquired.observations.filter { $0.artifactPath == exact.logicalPath && $0.table == "Events" }.count == 5_000)
        #expect(acquired.observations.filter { $0.artifactPath == overflow.logicalPath && $0.table == "Events" }.count == 5_000)
        #expect(acquired.warnings.contains { $0.contains("SQLite per-table row limit") && $0.contains(overflow.logicalPath) })
        #expect(!acquired.warnings.contains { $0.contains("SQLite per-table row limit") && $0.contains(exact.logicalPath) })
    }

    @Test func totalSQLiteRowBudgetReportsOnlyWhenAnotherTableHasRows() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-total-rows")
        defer { try? FileManager.default.removeItem(at: root) }
        let exact = try payload(root, domain: "HomeDomain", relativePath: "Library/exact.db")
        let overflow = try payload(root, domain: "HomeDomain", relativePath: "Library/overflow.db")
        try createSQLite(exact.url, statements: ["CREATE TABLE Events (message TEXT)", "INSERT INTO Events VALUES ('first.example')"])
        try createSQLite(overflow.url, statements: ["CREATE TABLE Events (message TEXT)", "INSERT INTO Events VALUES ('first.example')", "CREATE TABLE Later (message TEXT)", "INSERT INTO Later VALUES ('unexamined.example')"])
        try createBackupMetadata(root, payloads: [exact, overflow])

        let acquired = try SecurityEvidenceAcquisition.acquire(request(root, maximumFiles: 100, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 1), hashTypes: [])

        #expect(acquired.observations.filter { $0.artifactPath == exact.logicalPath && $0.table == "Events" }.count == 1)
        #expect(acquired.observations.filter { $0.artifactPath == overflow.logicalPath && $0.table == "Events" }.count == 1)
        #expect(!acquired.observations.contains { $0.artifactPath == overflow.logicalPath && $0.table == "Later" })
        #expect(acquired.warnings.contains { $0.contains("SQLite total row budget") && $0.contains(overflow.logicalPath) })
        #expect(!acquired.warnings.contains { $0.contains("SQLite total row budget") && $0.contains(exact.logicalPath) })
    }

    @Test func binaryPlistValueOverLimitIsAnExplicitCoverageGap() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-plist-coverage")
        defer { try? FileManager.default.removeItem(at: root) }
        let exact = try payload(root, domain: "HomeDomain", relativePath: "Library/exact.plist")
        let overflow = try payload(root, domain: "HomeDomain", relativePath: "Library/overflow.plist")
        try SecureFileIO.writeNewFile(try PropertyListSerialization.data(fromPropertyList: ["Blob": Data(repeating: 0xab, count: 4_096)], format: .binary, options: 0), to: exact.url)
        let source = try PropertyListSerialization.data(fromPropertyList: ["Blob": Data(repeating: 0xcd, count: 4_097)], format: .binary, options: 0)
        try SecureFileIO.writeNewFile(source, to: overflow.url)
        try createBackupMetadata(root, payloads: [exact, overflow])

        let acquired = try SecurityEvidenceAcquisition.acquire(request(root, maximumFiles: 100, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 100), hashTypes: [.sha256])

        #expect(acquired.warnings.contains { $0.contains("Omitted 1 binary plist value") && $0.contains(overflow.logicalPath) })
        #expect(!acquired.warnings.contains { $0.contains("binary plist value") && $0.contains(exact.logicalPath) })
        #expect(acquired.observations.contains { $0.artifactPath == exact.logicalPath && $0.recordID == "plist.Blob" && $0.observedValue.count == 8_192 })
        #expect(!acquired.observations.contains { $0.artifactPath == overflow.logicalPath && $0.recordID == "plist.Blob" })
        #expect(acquired.observations.contains { $0.artifactPath == overflow.logicalPath && $0.observedType == "sha256" && $0.observedValue == hex(SHA256.hash(data: source)) })
        #expect(try Data(contentsOf: overflow.url) == source)
    }

    @Test func missingFirstManifestRowsCannotHideInventoryTruncation() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-missing-inventory")
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = try (1...4).map { index in
            try payload(root, domain: "HomeDomain", relativePath: "Library/missing-\(index).log")
        }
        let later = try payload(root, domain: "HomeDomain", relativePath: "Library/later.log")
        let source = Data("later.example".utf8)
        try SecureFileIO.writeNewFile(source, to: later.url)
        try createBackupMetadata(root, payloads: missing + [later])

        let acquired = try SecurityEvidenceAcquisition.acquire(request(root, maximumFiles: 3, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 100), hashTypes: [])

        #expect(acquired.filesExamined == 2)
        #expect(acquired.warnings.contains { $0.contains("Backup inventory stopped at the 3-file safety limit") })
        #expect(!acquired.observations.contains { $0.artifactPath == later.logicalPath })
        #expect(try Data(contentsOf: later.url) == source)
    }

    @Test func nonNullSQLiteBlobIsAnExplicitCoverageGap() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-blob-coverage")
        defer { try? FileManager.default.removeItem(at: root) }
        let sqlite = try payload(root, domain: "HomeDomain", relativePath: "Library/blob.db")
        try createSQLite(sqlite.url, statements: ["CREATE TABLE Events (payload BLOB)", "INSERT INTO Events VALUES (X'CAFE')"])
        let source = try Data(contentsOf: sqlite.url)
        try createBackupMetadata(root, payloads: [sqlite])

        let acquired = try SecurityEvidenceAcquisition.acquire(request(root, maximumFiles: 100, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 100), hashTypes: [.sha256])

        #expect(acquired.warnings.contains { $0.contains("Omitted 1 SQLite BLOB value") && $0.contains(sqlite.logicalPath) })
        #expect(!acquired.observations.contains { $0.artifactPath == sqlite.logicalPath && $0.recordID == "1:payload" })
        #expect(acquired.observations.contains { $0.artifactPath == sqlite.logicalPath && $0.observedType == "sha256" && $0.observedValue == hex(SHA256.hash(data: source)) })
        #expect(try Data(contentsOf: sqlite.url) == source)
    }

    @Test func SQLiteTextPreservesBytesAfterEmbeddedNUL() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-sqlite-nul")
        defer { try? FileManager.default.removeItem(at: root) }
        let sqlite = try payload(root, domain: "HomeDomain", relativePath: "Library/nul.db")
        try createSQLite(sqlite.url, statements: [
            "CREATE TABLE Events (message TEXT)",
            "INSERT INTO Events VALUES (CAST(X'7072650061667465722E6578616D706C65' AS TEXT))",
        ])
        let source = try Data(contentsOf: sqlite.url)
        try createBackupMetadata(root, payloads: [sqlite])

        let acquired = try SecurityEvidenceAcquisition.acquire(request(root, maximumFiles: 100, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 100), hashTypes: [.sha256])

        #expect(acquired.observations.contains { $0.artifactPath == sqlite.logicalPath && $0.table == "Events" && $0.recordID == "1:message" && $0.observedValue == "pre\u{0}after.example" })
        #expect(acquired.observations.contains { $0.artifactPath == sqlite.logicalPath && $0.observedType == "sha256" && $0.observedValue == hex(SHA256.hash(data: source)) })
        #expect(try Data(contentsOf: sqlite.url) == source)
    }

    @Test func cancelledAcquisitionDoesNotReadMappedArtifacts() async throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        try createBackupMetadata(root, payloads: [])
        let scan = request(root, maximumFiles: 100, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 100)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SecurityEvidenceAcquisition.acquire(scan, hashTypes: [.sha256])
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled acquisition unexpectedly returned a result.")
        } catch is CancellationError {
            // Cancellation must propagate rather than become a successful acquisition.
        }
    }

    private struct Payload {
        let fileID: String
        let domain: String
        let relativePath: String
        let url: URL
        var logicalPath: String { "\(domain)/\(relativePath)" }
    }

    private func payload(_ root: URL, domain: String, relativePath: String) throws -> Payload {
        let fileID = hex(Insecure.SHA1.hash(data: Data("\(domain)-\(relativePath)".utf8)))
        let bucket = root.appendingPathComponent(String(fileID.prefix(2)))
        try SecureFileIO.createPrivateDirectory(at: bucket)
        return Payload(fileID: fileID, domain: domain, relativePath: relativePath, url: bucket.appendingPathComponent(fileID))
    }

    private func createBackupMetadata(_ root: URL, payloads: [Payload]) throws {
        try SecureFileIO.writeNewFile(try PropertyListSerialization.data(fromPropertyList: ["Device Name": "Synthetic Test"], format: .xml, options: 0), to: root.appendingPathComponent("Info.plist"))
        let url = root.appendingPathComponent("Manifest.db")
        try createSQLite(url, statements: ["CREATE TABLE Files (fileID TEXT, domain TEXT, relativePath TEXT, flags INTEGER)"])
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ToolkitError.fileSystem("Could not open the synthetic backup manifest.", path: url.path)
        }
        defer { sqlite3_close(database) }
        for file in payloads {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO Files VALUES (?, ?, ?, 1)", -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ToolkitError(.internalInconsistency, message: "Could not prepare the synthetic manifest row.")
            }
            defer { sqlite3_finalize(statement) }
            // SQLITE_STATIC is valid while these nested C strings remain alive through sqlite3_step.
            let status = file.fileID.withCString { identifier in
                file.domain.withCString { domain in
                    file.relativePath.withCString { relativePath in
                        guard sqlite3_bind_text(statement, 1, identifier, -1, nil) == SQLITE_OK,
                              sqlite3_bind_text(statement, 2, domain, -1, nil) == SQLITE_OK,
                              sqlite3_bind_text(statement, 3, relativePath, -1, nil) == SQLITE_OK else { return SQLITE_ERROR }
                        return sqlite3_step(statement)
                    }
                }
            }
            guard status == SQLITE_DONE else { throw ToolkitError(.internalInconsistency, message: "Could not insert the synthetic manifest row.") }
        }
    }

    private func createSQLite(_ url: URL, statements: [String]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ToolkitError.fileSystem("Could not create the synthetic SQLite file.", path: url.path)
        }
        defer { sqlite3_close(database) }
        for sql in statements {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw ToolkitError(.internalInconsistency, message: "Could not initialize the synthetic SQLite file.")
            }
        }
    }

    private func walSnapshot(_ url: URL, statements: [String]) throws -> (database: Data, wal: Data) {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ToolkitError.fileSystem("Could not open the synthetic SQLite WAL source.", path: url.path)
        }
        defer { sqlite3_close(database) }
        for sql in ["PRAGMA journal_mode=WAL", "PRAGMA wal_autocheckpoint=0"] + statements {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw ToolkitError(.internalInconsistency, message: "Could not create the synthetic SQLite WAL fixture.")
            }
        }
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let walBytes = try Data(contentsOf: wal)
        guard !walBytes.isEmpty else { throw ToolkitError(.internalInconsistency, message: "The synthetic SQLite WAL is empty.") }
        return (try Data(contentsOf: url), walBytes)
    }

    private func rowStatements(count: Int) -> [String] {
        [
            "CREATE TABLE Events (message TEXT)",
            "WITH RECURSIVE sequence(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM sequence WHERE n < \(count)) INSERT INTO Events SELECT 'row-' || n FROM sequence",
        ]
    }

    private func request(_ root: URL, maximumFiles: Int, maximumFileBytes: Int64, maximumTotalBytes: Int64, maximumSQLiteRows: Int) -> SecurityScanRequest {
        SecurityScanRequest(evidenceRoot: root, acquisitionMethod: .backup, intelligence: [], maximumFiles: maximumFiles, maximumFileBytes: maximumFileBytes, maximumTotalBytes: maximumTotalBytes, maximumSQLiteRows: maximumSQLiteRows)
    }

    private func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
