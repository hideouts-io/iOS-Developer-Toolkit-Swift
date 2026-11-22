import CryptoKit
import DeviceKit
import Foundation
import Testing
import ToolkitCore
@testable import ToolkitFeatures

@Suite("Required evidence finalization", .serialized)
struct EvidenceFinalizationTests {
    private func device() -> Device {
        Device(kind: .physical, udid: "SYNTHETIC-EVIDENCE-DEVICE", name: "Synthetic evidence device")
    }

    private func manifest(for device: Device) -> CollectionManifest {
        CollectionManifest(applicationVersion: ToolkitVersion.current, targetUDID: device.udid, targetName: device.name, targetModel: nil, targetOSVersion: nil, targetBuild: nil, options: CollectionOptions(durationSeconds: 0), startedAt: Date(), finishedAt: Date(), outcome: .complete, stoppedEarly: false, steps: [])
    }

    @Test func publishesReadableManifestWithIndependentlyVerifiedHashes() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "evidence-finalize")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = device()
        let folder = try CaseWorkflow.createCaseFolder(in: root, target: device.target)
        let raw = Data("sanitized acquired bytes".utf8)
        let rawURL = folder.appendingPathComponent("snapshots/raw.txt")
        try SecureFileIO.writeNewFile(raw, to: rawURL)

        try EvidenceCollector.finalize(manifest: manifest(for: device), device: device, caseFolder: folder)

        let stored = try JSONOutput.decoder().decode(CollectionManifest.self, from: Data(contentsOf: folder.appendingPathComponent(CaseWorkflow.manifestFileName)))
        #expect(stored.outcome == .complete)
        #expect(stored.targetUDID == device.udid)
        #expect(try Data(contentsOf: rawURL) == raw)
        let text = try String(contentsOf: folder.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        let paths = try text.split(separator: "\n").map { line in
            let fields = line.components(separatedBy: "  ")
            #expect(fields.count == 2)
            let path = try #require(fields.last)
            let expectedHash = try #require(fields.first)
            let bytes = try Data(contentsOf: SecureFileIO.safeChild(of: folder, relativePath: path))
            let actualHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(actualHash == expectedHash)
            return path
        }
        #expect(Set(paths) == Set(["snapshots/raw.txt", "snapshots/device-record.json", CaseWorkflow.manifestFileName]))
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("SHA256SUMS").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test(arguments: ["snapshots/device-record.json", "SHA256SUMS", "manifest.json"])
    func refusesRequiredArtifactCollisionsWithoutChangingExistingBytes(path: String) throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "evidence-collision")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = device()
        let folder = try CaseWorkflow.createCaseFolder(in: root, target: device.target)
        let sentinel = Data("existing evidence must remain unchanged".utf8)
        let url = folder.appendingPathComponent(path)
        try SecureFileIO.writeNewFile(sentinel, to: url)

        do {
            try EvidenceCollector.finalize(manifest: manifest(for: device), device: device, caseFolder: folder)
            Issue.record("A required artifact collision was reported as finalized.")
        } catch let error as ToolkitError {
            #expect(error.kind == .fileSystem)
            #expect(error.message.contains(path))
            #expect(error.recovery?.contains(folder.path) == true)
            #expect(error.technicalDetail?.contains("Cause:") == true)
        }
        #expect(try Data(contentsOf: url) == sentinel)
        #expect(SecureFileIO.regularFiles(under: folder).map(\.relativePath) == [path])
    }

    @Test func unwritableMetadataRetainsAcquiredFilesAndReportsTheirLocation() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "evidence-unwritable")
        let device = device()
        let folder = try CaseWorkflow.createCaseFolder(in: root, target: device.target)
        let snapshots = folder.appendingPathComponent("snapshots")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: snapshots.path)
            try? FileManager.default.removeItem(at: root)
        }
        let raw = Data("retained partial evidence".utf8)
        let rawURL = snapshots.appendingPathComponent("raw.txt")
        try SecureFileIO.writeNewFile(raw, to: rawURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: snapshots.path)

        do {
            try EvidenceCollector.finalize(manifest: manifest(for: device), device: device, caseFolder: folder)
            Issue.record("An unwritable device record was reported as finalized.")
        } catch let error as ToolkitError {
            #expect(error.kind == .fileSystem)
            #expect(error.message.contains("snapshots/device-record.json"))
            #expect(error.recovery?.contains(folder.path) == true)
        }
        #expect(try Data(contentsOf: rawURL) == raw)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(CaseWorkflow.manifestFileName).path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("SHA256SUMS").path))
    }

    @Test func checksumReadFailureCannotPublishCompletedManifest() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "evidence-hash-failure")
        let device = device()
        let folder = try CaseWorkflow.createCaseFolder(in: root, target: device.target)
        let rawURL = folder.appendingPathComponent("snapshots/raw.txt")
        let raw = Data("retained unreadable evidence".utf8)
        try SecureFileIO.writeNewFile(raw, to: rawURL)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rawURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rawURL.path)

        do {
            try EvidenceCollector.finalize(manifest: manifest(for: device), device: device, caseFolder: folder)
            Issue.record("An unreadable required hash input was reported as finalized.")
        } catch let error as ToolkitError {
            #expect(error.kind == .fileSystem)
            #expect(error.message.contains("SHA256SUMS"))
            #expect(error.technicalDetail?.contains("calculate its hash") == true)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(CaseWorkflow.manifestFileName).path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("SHA256SUMS").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rawURL.path)
        #expect(try Data(contentsOf: rawURL) == raw)
    }

    @Test func checksumPersistenceFailureCannotPublishCompletedManifest() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "evidence-checksum-write")
        let device = device()
        let folder = try CaseWorkflow.createCaseFolder(in: root, target: device.target)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)

        do {
            try EvidenceCollector.finalize(manifest: manifest(for: device), device: device, caseFolder: folder)
            Issue.record("An unwritable checksum destination was reported as finalized.")
        } catch let error as ToolkitError {
            #expect(error.kind == .fileSystem)
            #expect(error.message.contains("SHA256SUMS"))
            #expect(error.recovery?.contains(folder.path) == true)
            #expect(error.technicalDetail?.contains("Could not create the file") == true)
        }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("snapshots/device-record.json").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(CaseWorkflow.manifestFileName).path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("SHA256SUMS").path))
    }

    @Test func symlinkCoverageCannotPublishCompletedManifestOrReplaceALink() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "evidence-manifest-write")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = device()
        let folder = try CaseWorkflow.createCaseFolder(in: root, target: device.target)
        let manifestURL = folder.appendingPathComponent(CaseWorkflow.manifestFileName)
        let missingDestination = root.appendingPathComponent("missing-target.json").path
        try FileManager.default.createSymbolicLink(atPath: manifestURL.path, withDestinationPath: missingDestination)

        do {
            try EvidenceCollector.finalize(manifest: manifest(for: device), device: device, caseFolder: folder)
            Issue.record("An existing manifest link was replaced or reported as finalized.")
        } catch let error as ToolkitError {
            #expect(error.kind == .fileSystem)
            #expect(error.message.contains("SHA256SUMS"))
            #expect(error.technicalDetail?.contains("symbolic link") == true)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: manifestURL.path) == missingDestination)
        #expect(!FileManager.default.fileExists(atPath: missingDestination))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("SHA256SUMS").path))
    }

    @Test func unreadableNestedFolderCannotBeOmittedFromChecksumCoverage() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "evidence-nested-hash")
        let device = device()
        let folder = try CaseWorkflow.createCaseFolder(in: root, target: device.target)
        let nested = folder.appendingPathComponent("artifacts/nested")
        try SecureFileIO.createNewPrivateDirectory(at: nested)
        let rawURL = nested.appendingPathComponent("raw.txt")
        let raw = Data("coverage cannot silently omit these bytes".utf8)
        try SecureFileIO.writeNewFile(raw, to: rawURL)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: nested.path)

        do {
            try EvidenceCollector.finalize(manifest: manifest(for: device), device: device, caseFolder: folder)
            Issue.record("An unreadable nested folder was silently omitted from the finalized checksums.")
        } catch let error as ToolkitError {
            #expect(error.kind == .fileSystem)
            #expect(error.message.contains("SHA256SUMS"))
            #expect(error.technicalDetail?.contains("enumerate every case file") == true)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(CaseWorkflow.manifestFileName).path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("SHA256SUMS").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path)
        #expect(try Data(contentsOf: rawURL) == raw)
    }

    @Test func emptyChecksumListRemainsVerifiableUntilAnArtifactAppears() throws {
        let folder = try SecureFileIO.makeTemporaryDirectory(prefix: "empty-hashes")
        defer { try? FileManager.default.removeItem(at: folder) }
        let checksum = try HashManifest.write(for: folder)

        #expect(try String(contentsOf: checksum, encoding: .utf8) == "\n")
        #expect(try HashManifest.verify(folder: folder).isEmpty)
        try SecureFileIO.writeNewFile(Data("new artifact".utf8), to: folder.appendingPathComponent("artifact.txt"))
        #expect(try HashManifest.verify(folder: folder) == ["artifact.txt"])
    }

    @Test func checksumDestinationNameCannotEscapeItsFolder() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "hash-name")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("case")
        try SecureFileIO.createNewPrivateDirectory(at: folder)

        #expect(throws: ToolkitError.self) { _ = try HashManifest.write(for: folder, fileName: "../outside") }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
    }
}
