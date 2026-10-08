import CSQLite
import Foundation
import Testing
import ToolkitCore
@testable import ToolkitFeatures

@Suite("Security Analysis")
struct SecurityAnalysisTests {
    @Test func importsSTIXEqualityAndORWhileRecordingUnsupportedPatterns() throws {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "security-stix")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("indicators.stix2")
        let document = """
        {"type":"bundle","objects":[
          {"type":"indicator","id":"indicator--one","name":"Known domains","confidence":85,"pattern_type":"stix","pattern":"[domain-name:value = 'bad.example' OR domain-name:value = 'worse.example']"},
          {"type":"indicator","id":"indicator--two","pattern_type":"stix","pattern":"[domain-name:value LIKE '%.invalid']"}
        ]}
        """
        try SecureFileIO.writeNewFile(Data(document.utf8), to: source)
        let bundle = try load(source)
        #expect(bundle.indicators.map(\.value) == ["bad.example", "worse.example"])
        #expect(bundle.indicators.allSatisfy { $0.provenance.sha256 == SecureFileIO.sha256(of: Data(document.utf8)) })
        #expect(bundle.warnings.count == 1)
        #expect(bundle.warnings[0].contains("safe equality/OR subset"))
    }

    @Test func rejectsUnsupportedOrEmptyIntelligence() throws {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "security-bad-ioc")
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty.json")
        try SecureFileIO.writeNewFile(Data("{\"indicators\":[]}".utf8), to: empty)
        #expect(throws: ToolkitError.self) { try load(empty) }
        let wrongType = directory.appendingPathComponent("wrong.json")
        try SecureFileIO.writeNewFile(Data("{\"indicators\":[{\"id\":\"x\",\"type\":\"registry-key\",\"value\":\"x\"}]}".utf8), to: wrongType)
        #expect(throws: ToolkitError.self) { try load(wrongType) }
    }

    @Test func nativeAnalysisMatchesAndNeverClaimsClean() async throws {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "security-match")
        defer { try? FileManager.default.removeItem(at: directory) }
        let evidence = directory.appendingPathComponent("evidence", isDirectory: true)
        try SecureFileIO.createPrivateDirectory(at: evidence)
        try SecureFileIO.writeNewFile(Data("Connected to sub.bad.example during the test.\n".utf8), to: evidence.appendingPathComponent("network.log"))
        let ioc = directory.appendingPathComponent("ioc.json")
        try SecureFileIO.writeNewFile(Data("{\"indicators\":[{\"id\":\"domain-1\",\"type\":\"domain\",\"value\":\"bad.example\",\"name\":\"Test domain\",\"confidence\":90}]}".utf8), to: ioc)
        let report = try await SecurityAnalysisEngine.analyze(request(evidence, method: .importedEvidence, intelligence: [try load(ioc)]))
        #expect(report.scannerExecutions.map(\.status) == [.completed])
        #expect(report.correlatedFindings.count == 1)
        #expect(report.correlatedFindings[0].classification == .highConfidenceIOCMatch)
        #expect(report.statusSummary.contains("manual forensic review"))

        let noMatch = try await SecurityAnalysisEngine.analyze(request(evidence, method: .importedEvidence, intelligence: []))
        #expect(noMatch.correlatedFindings.isEmpty)
        #expect(noMatch.statusSummary.contains("not proof that the device is clean"))
    }

    @Test func acquisitionIsBoundedAndRefusesSymlinkRoots() throws {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "security-bounds")
        defer { try? FileManager.default.removeItem(at: directory) }
        let evidence = directory.appendingPathComponent("evidence", isDirectory: true)
        try SecureFileIO.createPrivateDirectory(at: evidence)
        try SecureFileIO.writeNewFile(Data(repeating: 0x41, count: 100), to: evidence.appendingPathComponent("large.txt"))
        let bounded = SecurityScanRequest(evidenceRoot: evidence, acquisitionMethod: .importedEvidence, intelligence: [], maximumFiles: 10, maximumFileBytes: 10, maximumTotalBytes: 100, maximumSQLiteRows: 100)
        let acquired = try SecurityEvidenceAcquisition.acquire(bounded, hashTypes: [])
        #expect(acquired.filesExamined == 0)
        #expect(acquired.warnings.contains { $0.contains("per-file limit") })

        let linked = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: evidence)
        #expect(throws: ToolkitError.self) { try SecurityEvidenceAcquisition.acquire(request(linked, method: .importedEvidence, intelligence: []), hashTypes: []) }
    }

    @Test func backupManifestRejectsUnsafeFileIdentifiers() throws {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "security-backup")
        defer { try? FileManager.default.removeItem(at: directory) }
        try SecureFileIO.writeNewFile(try PropertyListSerialization.data(fromPropertyList: ["Device Name": "Test"], format: .xml, options: 0), to: directory.appendingPathComponent("Info.plist"))
        let manifest = directory.appendingPathComponent("Manifest.db")
        try createManifest(manifest, fileID: "../../outside", domain: "HomeDomain", relativePath: "Library/test.txt")
        let acquired = try SecurityEvidenceAcquisition.acquire(request(directory, method: .backup, intelligence: []), hashTypes: [])
        #expect(acquired.warnings.contains { $0.contains("unsafe or malformed fileID") })
        #expect(acquired.observations.allSatisfy { !$0.sourceFile.contains("outside") })
    }

    @Test func backupManifestMustNotBeASymbolicLink() throws {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "security-backup-link")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appendingPathComponent("backup", isDirectory: true)
        try SecureFileIO.createPrivateDirectory(at: backup)
        try SecureFileIO.writeNewFile(try PropertyListSerialization.data(fromPropertyList: ["Device Name": "Test"], format: .xml, options: 0), to: backup.appendingPathComponent("Info.plist"))
        let outside = directory.appendingPathComponent("outside.db")
        try createManifest(outside, fileID: String(repeating: "a", count: 40), domain: "HomeDomain", relativePath: "Library/test.txt")
        try FileManager.default.createSymbolicLink(at: backup.appendingPathComponent("Manifest.db"), withDestinationURL: outside)
        #expect(throws: ToolkitError.self) { try SecurityEvidenceAcquisition.acquire(request(backup, method: .backup, intelligence: []), hashTypes: []) }
    }

    @Test func normalizesExistingMVTResultsWithoutImplyingRerun() async throws {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "security-mvt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = directory.appendingPathComponent("safari_history_detected.json")
        try SecureFileIO.writeNewFile(Data("[{\"matched_indicator\":\"bad.example\",\"timestamp\":\"2026-09-28T12:00:00Z\",\"url\":\"https://bad.example/\"}]".utf8), to: result)
        let report = try await SecurityAnalysisEngine.analyze(request(directory, method: .mvtResults, intelligence: []))
        #expect(report.findings.count == 1)
        #expect(report.findings[0].scanner == "MVT Output Adapter")
        #expect(report.findings[0].detectionBasis.contains("toolkit did not rerun MVT"))
        #expect(report.correlatedFindings[0].matchedIndicator == "bad.example")
    }

    @Test func mvtResultImportHonorsConfiguredBounds() async throws {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "security-mvt-bounds")
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 1...2 {
            let result = directory.appendingPathComponent("result-\(index)_detected.json")
            try SecureFileIO.writeNewFile(Data("[{\"matched_indicator\":\"indicator-\(index)\"}]".utf8), to: result)
        }
        let bounded = SecurityScanRequest(evidenceRoot: directory, acquisitionMethod: .mvtResults, intelligence: [], maximumFiles: 1, maximumFileBytes: 1_000, maximumTotalBytes: 1_000, maximumSQLiteRows: 100)
        let report = try await SecurityAnalysisEngine.analyze(bounded)
        #expect(report.filesExamined == 1)
        #expect(report.findings.count == 1)
        #expect(report.acquisitionWarnings.contains { $0.contains("1-file safety limit") })
    }

    @Test func scannerFailuresRemainExplicitCoverageGaps() async throws {
        let missing = URL(fileURLWithPath: "/tmp/idt-security-evidence-that-does-not-exist")
        let report = try await SecurityAnalysisEngine.analyze(request(missing, method: .importedEvidence, intelligence: []))
        #expect(report.scannerExecutions.map(\.status) == [.failed])
        #expect(report.scannerExecutions[0].errorMessage?.contains("selected evidence path") == true)
        #expect(report.statusSummary.contains("coverage is incomplete"))
    }

    @Test func exportsAllFormatsPrivatelyWithoutOverwriting() async throws {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "security-reports")
        defer { try? FileManager.default.removeItem(at: directory) }
        let evidence = directory.appendingPathComponent("evidence.txt")
        try SecureFileIO.writeNewFile(Data("ordinary evidence".utf8), to: evidence)
        let report = try await SecurityAnalysisEngine.analyze(request(evidence, method: .importedEvidence, intelligence: []))
        for format in SecurityReportFormat.allCases {
            let destination = directory.appendingPathComponent("report.\(format.rawValue)")
            try SecurityReportWriter.write(report, format: format, to: destination)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let content = try String(contentsOf: destination, encoding: .utf8)
            #expect(content.contains(report.analysisID))
            if format == .csv {
                #expect(content.contains("analysis_id,started_at,finished_at,acquisition_method"))
                #expect(content.contains("scanner_statuses,acquisition_warnings,limitations"))
            }
            #expect(throws: ToolkitError.self) { try SecurityReportWriter.write(report, format: format, to: destination) }
        }
        #expect(SecurityReportWriter.renderHTML(report).contains("not proof that the device is clean"))
        #expect(SecurityReportWriter.renderHTML(report).contains("Acquisition Warnings"))
    }

    @Test func staleCheckAcceptsStandardISOTimestamps() throws {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "security-stale")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ioc.json")
        try SecureFileIO.writeNewFile(Data("{\"indicators\":[{\"id\":\"x\",\"type\":\"domain\",\"value\":\"example.invalid\"}]}".utf8), to: source)
        let bundle = try ThreatIntelligence.loadLocalFile(source, sourceName: "test", organization: "test", sourceURL: nil, version: nil, commit: nil, publishedAt: "2026-01-01T00:00:00Z", signatureStatus: "not-provided", importedAt: "2026-01-01T00:00:00Z", maximumBytes: 1_000_000)
        let reference = try #require(ISO8601DateFormatter().date(from: "2026-03-15T00:00:00Z"))
        #expect(try ThreatIntelligence.isStale(bundle, referenceDate: reference, maximumAgeDays: 30))
    }

    private func load(_ url: URL) throws -> IntelligenceBundle {
        try ThreatIntelligence.loadLocalFile(url, sourceName: "Test", organization: "Test lab", sourceURL: nil, version: "1", commit: nil, publishedAt: nil, signatureStatus: "not-provided", importedAt: "2026-09-28T12:00:00Z", maximumBytes: 1_000_000)
    }

    private func request(_ root: URL, method: SecurityAcquisitionMethod, intelligence: [IntelligenceBundle]) -> SecurityScanRequest {
        SecurityScanRequest(evidenceRoot: root, acquisitionMethod: method, intelligence: intelligence, maximumFiles: 100, maximumFileBytes: 1_000_000, maximumTotalBytes: 5_000_000, maximumSQLiteRows: 1_000)
    }

    private func createManifest(_ url: URL, fileID: String, domain: String, relativePath: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw ToolkitError.fileSystem("Could not create the test backup manifest.", path: url.path)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TABLE Files (fileID TEXT, domain TEXT, relativePath TEXT, flags INTEGER)", nil, nil, nil) == SQLITE_OK else {
            throw ToolkitError(.internalInconsistency, message: "Could not create the test Files table.")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO Files VALUES (?, ?, ?, 1)", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ToolkitError(.internalInconsistency, message: "Could not prepare the test Files insert.")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, fileID, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, domain, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 3, relativePath, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw ToolkitError(.internalInconsistency, message: "Could not write the test Files row.")
        }
    }
}
