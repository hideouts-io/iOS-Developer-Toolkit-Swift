import Foundation
import Testing
@testable import DeviceKit
import DeviceTestSupport
import ToolkitCore

private func withFakeDevice(_ configure: (FakeDeviceServer) -> Void, _ body: (FakeDeviceServer) async throws -> Void) async throws {
    let server = try FakeDeviceServer()
    let fileSystem = FakeAFCFileSystem(files: [:])
    server.register(service: AFCClient.mediaServiceName) { channel in try await fileSystem.serve(channel) }
    server.register(service: NotificationProxy.serviceName) { channel in
        let messages = PlistMessageConnection(channel: channel)
        while try await channel.hasMoreData() {
            let message = try await messages.receive(timeout: 5)
            if message["Command"]?.stringValue == "Shutdown" { break }
        }
    }
    configure(server)
    try await server.start()
    do {
        try await body(server)
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

private func removeTestBackupRoot(_ root: URL) {
    do { try FileManager.default.removeItem(at: root) }
    catch { Issue.record("Could not remove the task-owned backup fixture: \(error.localizedDescription)") }
}

/// Scripted DeviceLink peer.
struct FakeDeviceLink {
    let channel: DeviceChannel
    var messages: PlistMessageConnection { PlistMessageConnection(channel: channel) }

    func handshake() async throws -> PlistValue {
        try await messages.send(["DLMessageVersionExchange", 300, 0], format: .binary)
        let versions = try await messages.receive(timeout: 5)
        #expect(versions[1]?.stringValue == "DLVersionsOk")
        try await messages.send(["DLMessageDeviceReady"], format: .binary)
        let hello = try await messages.receive(timeout: 5)
        #expect(hello[1]?["MessageName"]?.stringValue == "Hello")
        try await messages.send(["DLMessageProcessMessage", ["MessageName": "Response", "ErrorCode": 0, "ProtocolVersion": 2.1]], format: .binary)
        return try await messages.receive(timeout: 5)
    }

    func expectStatus(_ code: Int) async throws -> PlistValue {
        let status = try await messages.receive(timeout: 5)
        #expect(status[0]?.stringValue == "DLMessageStatusResponse")
        #expect(status[1]?.intValue == code)
        return status
    }

    func length(_ value: Int) -> Data {
        var data = Data()
        data.appendBigEndian(UInt32(value))
        return data
    }

    func upload(_ files: [(String, Data)]) async throws {
        for (name, content) in files {
            try await channel.write(length(name.utf8.count) + Data(name.utf8))
            try await channel.write(length(name.utf8.count) + Data(name.utf8))
            if !content.isEmpty {
                try await channel.write(length(content.count + 1) + Data([0x0C]) + content)
            }
            try await channel.write(length(1) + Data([0x00]))
        }
        try await channel.write(length(0))
    }

    /// Reads the host's reply to DLMessageDownloadFiles.
    func receiveDownloads() async throws -> [String: Data?] {
        var results: [String: Data?] = [:]
        while true {
            let nameLength = Int(try await channel.read(exactly: 4, timeout: 5).readBigEndianUInt32(at: 0))
            if nameLength == 0 { break }
            let name = String(decoding: try await channel.read(exactly: nameLength, timeout: 5), as: UTF8.self)
            var content = Data()
            var failed = false
            while true {
                let blockLength = Int(try await channel.read(exactly: 4, timeout: 5).readBigEndianUInt32(at: 0))
                let code = try await channel.read(exactly: 1, timeout: 5)[0]
                let payload = blockLength > 1 ? try await channel.read(exactly: blockLength - 1, timeout: 5) : Data()
                if code == 0x0C { content.append(payload); continue }
                failed = code != 0x00
                break
            }
            results[name] = failed ? nil : content
        }
        return results
    }
}

/// A controlled AFC sync-lock peer; only status 19 represents temporary contention.
private func serveSyncLock(_ channel: DeviceChannel, lockStatuses: [UInt64], unlockStatus: UInt64, operations: LockedValue<[UInt64]>) async throws {
    var remainingStatuses = lockStatuses
    while try await channel.hasMoreData() {
        let request = try await channel.read(exactly: 40, timeout: 5)
        let length = Int(request.readLittleEndianUInt64(at: 8))
        let number = request.readLittleEndianUInt64(at: 24)
        let operation = request.readLittleEndianUInt64(at: 32)
        let body = try await channel.read(exactly: length - 40, timeout: 5)
        operations.withLock { $0.append(operation) }
        var response = Data()
        if operation == 0x0D {
            response.appendLittleEndian(UInt64(1))
            try await channel.write(AFCClient.encode(operation: 0x0E, packetNumber: number, header: response, payload: Data()))
        } else {
            let code: UInt64
            if operation == 0x1B, body.readLittleEndianUInt64(at: 8) == AFCClient.LockOperation.exclusive.rawValue {
                #expect(!remainingStatuses.isEmpty)
                code = remainingStatuses.isEmpty ? 1 : remainingStatuses.removeFirst()
            } else if operation == 0x1B, body.readLittleEndianUInt64(at: 8) == AFCClient.LockOperation.unlock.rawValue {
                code = unlockStatus
            } else {
                code = 0
            }
            response.appendLittleEndian(code)
            try await channel.write(AFCClient.encode(operation: 0x01, packetNumber: number, header: response, payload: Data()))
        }
    }
}

private func serveMissingSyncLock(_ channel: DeviceChannel, operations: LockedValue<[UInt64]>) async throws {
    while try await channel.hasMoreData() {
        let request = try await channel.read(exactly: 40, timeout: 5)
        let length = Int(request.readLittleEndianUInt64(at: 8))
        let number = request.readLittleEndianUInt64(at: 24)
        let operation = request.readLittleEndianUInt64(at: 32)
        try #require(length >= 40)
        _ = try await channel.read(exactly: length - 40, timeout: 5)
        operations.withLock { $0.append(operation) }
        try #require(operation == 0x0D)
        var response = Data()
        response.appendLittleEndian(UInt64(8))
        try await channel.write(AFCClient.encode(operation: 0x01, packetNumber: number, header: response, payload: Data()))
    }
}

@Suite("AFC and MobileBackup2 (fake device)", .serialized)
struct BackupAndAFCTests {
    @Test func afcListsReadsAndWrites() async throws {
        let fileSystem = FakeAFCFileSystem(files: ["/DCIM/100APPLE/IMG_0001.JPG": Data("jpeg".utf8), "/Downloads/readme.txt": Data(repeating: 0x61, count: 3000)])
        try await withFakeDevice({ _ in }) { server in
            server.register(service: AFCClient.mediaServiceName) { channel in
                try await fileSystem.serve(channel)
            }
            let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "afc-test")
            defer { try? FileManager.default.removeItem(at: directory) }
            try await DeviceSession.with(server.target, usbmux: server.client) { session in
                let afc = try await AFCClient.openMedia(session)
                #expect(try await afc.listDirectory("/") == ["DCIM", "Downloads"])
                let info = try await afc.fileInfo("/Downloads/readme.txt")
                #expect(info.size == 3000)
                #expect(!info.isDirectory)
                #expect(try await afc.fileInfo("/DCIM").isDirectory)
                let destination = directory.appendingPathComponent("readme.txt")
                #expect(try await afc.download("/Downloads/readme.txt", to: destination, chunkSize: 1024) == 3000)
                #expect(try Data(contentsOf: destination).count == 3000)
                let source = directory.appendingPathComponent("upload.ipa")
                try SecureFileIO.writeNewFile(Data(repeating: 7, count: 2500), to: source)
                try await afc.makeDirectory("/PublicStaging")
                try await afc.upload(source, to: "/PublicStaging/upload.ipa", chunkSize: 1000)
                let walk = try await afc.walk("/")
                #expect(walk.contains("/PublicStaging/upload.ipa"))
                do {
                    _ = try await afc.fileInfo("/missing")
                    Issue.record("expected not found")
                } catch let error as ToolkitError {
                    #expect(error.kind == .fileSystem)
                    #expect(error.message.contains("does not exist"))
                }
                await afc.close()
            }
            #expect(await fileSystem.files["/PublicStaging/upload.ipa"]?.count == 2500)
        }
    }

    @Test func fullBackupConversation() async throws {
        let statusPlist = try PlistValue(dictionaryLiteral: ("SnapshotState", "finished")).encoded()
        try await withFakeDevice({ $0.domainValues["com.apple.mobile.backup"] = ["WillEncrypt": true] }) { server in
            let udid = server.udid
            server.register(service: MobileBackup2.serviceName) { channel in
                let link = FakeDeviceLink(channel: channel)
                let request = try await link.handshake()
                #expect(request[1]?["MessageName"]?.stringValue == "Backup")
                #expect(request[1]?["TargetIdentifier"]?.stringValue == udid)
                #expect(request[1]?["Options"]?["ForceFullBackup"]?.boolValue == true)

                try await link.messages.send(["DLMessageCreateDirectory", .string("\(udid)/Snapshot"), 0, 5.0], format: .binary)
                _ = try await link.expectStatus(0)

                try await link.messages.send(["DLMessageUploadFiles", [], 0, 40.0], format: .binary)
                try await link.upload([
                    ("\(udid)/Snapshot/Status.plist", statusPlist),
                    ("\(udid)/Snapshot/ab/ab12cd", Data(repeating: 0x42, count: 70_000)),
                    ("\(udid)/Snapshot/empty", Data()),
                ])
                _ = try await link.expectStatus(0)

                try await link.messages.send(["DLMessageMoveFiles", .dictionary(["\(udid)/Snapshot/Status.plist": .string("\(udid)/Status.plist")]), 0, 70.0], format: .binary)
                _ = try await link.expectStatus(0)

                // A path that tries to leave the backup folder is refused, not followed.
                try await link.messages.send(["DLMessageCreateDirectory", "../../escape"], format: .binary)
                _ = try await link.expectStatus(-1)

                try await link.messages.send(["DLMessageGetFreeDiskSpace"], format: .binary)
                let space = try await link.expectStatus(0)
                #expect((space[3]?.int64Value ?? 0) > 0)

                try await link.messages.send(["DLMessageContentsOfDirectory", .string(udid)], format: .binary)
                let contents = try await link.expectStatus(0)
                #expect(contents[3]?["Status.plist"]?["DLFileType"]?.stringValue == "DLFileTypeRegular")

                try await link.messages.send(["DLMessageDownloadFiles", [.string("\(udid)/Status.plist"), .string("\(udid)/missing")], 0, 90.0], format: .binary)
                let downloads = try await link.receiveDownloads()
                #expect(downloads["\(udid)/Status.plist"] == .some(statusPlist))
                #expect(downloads["\(udid)/missing"] == .some(nil))
                let multi = try await link.expectStatus(-13)
                #expect(multi[3]?["\(udid)/missing"] != nil)

                try await link.messages.send(["DLMessageRemoveFiles", [.string("\(udid)/Snapshot/empty")], 0, 95.0], format: .binary)
                _ = try await link.expectStatus(0)

                try await link.messages.send(["DLMessageProcessMessage", ["ErrorCode": 0]], format: .binary)
                _ = try? await link.messages.receive(timeout: 2)
            }
            let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-test")
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent("escape")) }
            defer { try? FileManager.default.removeItem(at: root) }
            let events = LockedValue<[BackupEvent]>([])
            let result = try await DeviceSession.with(server.target, usbmux: server.client) { session in
                try await MobileBackup2.backup(session, options: BackupOptions(destinationRoot: root, forceFullBackup: true)) { event in
                    events.withLock { $0.append(event) }
                }
            }
            #expect(result.lastPathComponent == udid)
            let backup = root.appendingPathComponent(udid)
            #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Status.plist").path))
            #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Info.plist").path))
            #expect(try Data(contentsOf: backup.appendingPathComponent("Snapshot/ab/ab12cd")).count == 70_000)
            #expect(!FileManager.default.fileExists(atPath: backup.appendingPathComponent("Snapshot/empty").path))
            #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
            let info = try PlistValue.decode(try Data(contentsOf: backup.appendingPathComponent("Info.plist")))
            #expect(info["Target Identifier"]?.stringValue == udid)
            #expect(info["Device Name"]?.stringValue == "Test iPhone")
            let recorded = events.current
            #expect(recorded.contains(.encryption(true)))
            #expect(recorded.contains(.progress(40)))
            #expect(recorded.contains(.bytesReceived(Int64(statusPlist.count + 70_000))))
            guard case .finished(let finishedURL)? = recorded.last else {
                Issue.record("expected a finished event last")
                return
            }
            #expect(finishedURL.standardizedFileURL.path == backup.standardizedFileURL.path)
        }
    }

    @Test func maliciousUploadPathAbortsBackup() async throws {
        try await withFakeDevice({ $0.domainValues["com.apple.mobile.backup"] = ["WillEncrypt": false] }) { server in
            server.register(service: MobileBackup2.serviceName) { channel in
                let link = FakeDeviceLink(channel: channel)
                _ = try await link.handshake()
                try await link.messages.send(["DLMessageUploadFiles", [], 0, 10.0], format: .binary)
                try await link.upload([("../../evil.txt", Data("x".utf8))])
                _ = try? await link.messages.receive(timeout: 2)
            }
            let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-evil")
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                _ = try await DeviceSession.with(server.target, usbmux: server.client) { session in
                    try await MobileBackup2.backup(session, options: BackupOptions(destinationRoot: root, forceFullBackup: true)) { _ in }
                }
                Issue.record("expected the backup to stop")
            } catch let error as ToolkitError {
                #expect(error.kind == .protocolViolation)
            }
            #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("evil.txt").path))
        }
    }

    @Test func deviceReportedErrorsAreActionable() async throws {
        try await withFakeDevice({ $0.domainValues["com.apple.mobile.backup"] = ["WillEncrypt": false] }) { server in
            server.register(service: MobileBackup2.serviceName) { channel in
                let link = FakeDeviceLink(channel: channel)
                _ = try await link.handshake()
                try await link.messages.send(["DLMessageProcessMessage", ["ErrorCode": 208, "ErrorDescription": "Device locked"]], format: .binary)
                _ = try? await link.messages.receive(timeout: 2)
            }
            let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-locked")
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                _ = try await DeviceSession.with(server.target, usbmux: server.client) { session in
                    try await MobileBackup2.backup(session, options: BackupOptions(destinationRoot: root, forceFullBackup: false)) { _ in }
                }
                Issue.record("expected failure")
            } catch let error as ToolkitError {
                #expect(error.kind == .deviceLocked)
            }
        }
    }

    /// Controlled peers exercise production framing and completion; these are synthetic backups.
    @Test(arguments: [
        PlistValue.array(["DLMessageDisconnect"]),
        PlistValue.array(["DLMessageProcessMessage"]),
        PlistValue.array(["DLMessageProcessMessage", "not a dictionary"]),
        PlistValue.array(["DLMessageProcessMessage", .dictionary([:])]),
        PlistValue.array(["DLMessageProcessMessage", ["ErrorCode": "0"]]),
        PlistValue.array(["DLMessageProcessMessage", ["ErrorCode": .real(0)]]),
        PlistValue.array(["DLMessageProcessMessage", ["ErrorCode": false]]),
        PlistValue.array(["DLMessageProcessMessage", ["ErrorCode": 208]]),
    ])
    func incompleteTerminalResponseRetainsPartialBackup(_ terminal: PlistValue) async throws {
        try await withFakeDevice({ $0.domainValues["com.apple.mobile.backup"] = ["WillEncrypt": false] }) { server in
            let partial = Data("partial backup payload".utf8)
            let udid = server.udid
            server.register(service: MobileBackup2.serviceName) { channel in
                let link = FakeDeviceLink(channel: channel)
                _ = try await link.handshake()
                try await link.messages.send(["DLMessageUploadFiles", [], 0, 100.0], format: .binary)
                try await link.upload([("\(udid)/partial", partial)])
                _ = try await link.expectStatus(0)
                try await link.messages.send(terminal, format: .binary)
                _ = try? await link.messages.receive(timeout: 2)
            }
            let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-terminal")
            defer { removeTestBackupRoot(root) }
            let events = LockedValue<[BackupEvent]>([])
            do {
                _ = try await DeviceSession.with(server.target, usbmux: server.client) { session in
                    try await MobileBackup2.backup(session, options: BackupOptions(destinationRoot: root, forceFullBackup: true)) { event in
                        events.withLock { $0.append(event) }
                    }
                }
                Issue.record("An invalid terminal response completed the backup")
            } catch let error as ToolkitError {
                if terminal[0]?.stringValue == "DLMessageDisconnect" {
                    #expect(error.kind == .deviceDisconnected)
                } else if terminal[1]?["ErrorCode"]?.int64Value == 208 {
                    #expect(error.kind == .deviceLocked)
                } else {
                    #expect(error.kind == .protocolViolation)
                }
            }
            #expect(try Data(contentsOf: root.appendingPathComponent("\(udid)/partial")) == partial)
            #expect(!events.current.contains(.progress(100)))
            #expect(!events.current.contains { if case .finished = $0 { return true }; return false })
        }
    }

    @Test(arguments: [
        PlistValue.dictionary([:]),
        PlistValue.dictionary(["SnapshotState": "pending"]),
        PlistValue.dictionary(["SnapshotState": false]),
    ])
    func terminalZeroRequiresFinishedSnapshot(_ status: PlistValue) async throws {
        try await withFakeDevice({ $0.domainValues["com.apple.mobile.backup"] = ["WillEncrypt": false] }) { server in
            let udid = server.udid
            let statusData = try status.encoded()
            server.register(service: MobileBackup2.serviceName) { channel in
                let link = FakeDeviceLink(channel: channel)
                _ = try await link.handshake()
                try await link.messages.send(["DLMessageUploadFiles", [], 0, 100.0], format: .binary)
                try await link.upload([("\(udid)/Status.plist", statusData)])
                _ = try await link.expectStatus(0)
                try await link.messages.send(["DLMessageProcessMessage", ["ErrorCode": 0]], format: .binary)
                _ = try? await link.messages.receive(timeout: 2)
            }
            let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-snapshot")
            defer { removeTestBackupRoot(root) }
            let events = LockedValue<[BackupEvent]>([])
            do {
                _ = try await DeviceSession.with(server.target, usbmux: server.client) { session in
                    try await MobileBackup2.backup(session, options: BackupOptions(destinationRoot: root, forceFullBackup: true)) { event in
                        events.withLock { $0.append(event) }
                    }
                }
                Issue.record("An unfinished snapshot completed the backup")
            } catch let error as ToolkitError {
                #expect(error.kind == .protocolViolation)
            }
            #expect(try Data(contentsOf: root.appendingPathComponent("\(udid)/Status.plist")) == statusData)
            #expect(!events.current.contains(.progress(100)))
            #expect(!events.current.contains { if case .finished = $0 { return true }; return false })
        }
    }

    @Test func missingSnapshotStatusIsRejectedWithoutRemovingTheBackup() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-status-missing")
        defer { removeTestBackupRoot(root) }
        #expect(throws: ToolkitError.self) { try MobileBackup2.validateFinishedSnapshot(in: root) }
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Status.plist").path))
    }

    @Test func malformedSnapshotStatusIsRejectedAndPreserved() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-status-malformed")
        defer { removeTestBackupRoot(root) }
        let statusURL = root.appendingPathComponent("Status.plist")
        let contents = Data("not a property list".utf8)
        try SecureFileIO.writeNewFile(contents, to: statusURL)
        #expect(throws: ToolkitError.self) { try MobileBackup2.validateFinishedSnapshot(in: root) }
        #expect(try Data(contentsOf: statusURL) == contents)
    }

    @Test func snapshotStatusDirectoryIsRejectedAndPreserved() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-status-directory")
        defer { removeTestBackupRoot(root) }
        let statusURL = root.appendingPathComponent("Status.plist")
        try SecureFileIO.createPrivateDirectory(at: statusURL)
        #expect(throws: ToolkitError.self) { try MobileBackup2.validateFinishedSnapshot(in: root) }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: statusURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func snapshotStatusSymbolicLinkIsRejectedWithoutReadingItsTarget() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-status-link")
        defer { removeTestBackupRoot(root) }
        let target = root.appendingPathComponent("owned-target.plist")
        let contents = try PlistValue.dictionary(["SnapshotState": "finished"]).encoded()
        try SecureFileIO.writeNewFile(contents, to: target)
        let statusURL = root.appendingPathComponent("Status.plist")
        try FileManager.default.createSymbolicLink(at: statusURL, withDestinationURL: target)
        #expect(throws: ToolkitError.self) { try MobileBackup2.validateFinishedSnapshot(in: root) }
        #expect(try Data(contentsOf: target) == contents)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: statusURL.path) == target.path)
    }

    @Test func oversizedSnapshotStatusIsRejectedAndPreserved() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-status-oversized")
        defer { removeTestBackupRoot(root) }
        let statusURL = root.appendingPathComponent("Status.plist")
        let contents = Data(repeating: 0x41, count: (1 << 20) + 1)
        try SecureFileIO.writeNewFile(contents, to: statusURL)
        #expect(throws: ToolkitError.self) { try MobileBackup2.validateFinishedSnapshot(in: root) }
        #expect(try Data(contentsOf: statusURL) == contents)
    }

    @Test func cancellationAfterTransferCannotCompleteBackup() async throws {
        try await withFakeDevice({ $0.domainValues["com.apple.mobile.backup"] = ["WillEncrypt": false] }) { server in
            let transfer = AsyncStream<Void>.makeStream()
            let operations = LockedValue<[UInt64]>([])
            let notifications = LockedValue<[String]>([])
            let notificationCompletion = AsyncStream<Void>.makeStream()
            server.register(service: AFCClient.mediaServiceName) { channel in
                try await serveSyncLock(channel, lockStatuses: [0], unlockStatus: 0, operations: operations)
            }
            server.register(service: NotificationProxy.serviceName) { channel in
                let messages = PlistMessageConnection(channel: channel)
                while try await channel.hasMoreData() {
                    let message = try await messages.receive(timeout: 5)
                    if let name = message["Name"]?.stringValue { notifications.withLock { $0.append(name) } }
                    if message["Command"]?.stringValue == "Shutdown" {
                        notificationCompletion.continuation.yield(())
                        notificationCompletion.continuation.finish()
                        break
                    }
                }
            }
            let udid = server.udid
            let partial = Data("cancelled backup payload".utf8)
            server.register(service: MobileBackup2.serviceName) { channel in
                let link = FakeDeviceLink(channel: channel)
                _ = try await link.handshake()
                try await link.messages.send(["DLMessageUploadFiles", [], 0, 100.0], format: .binary)
                try await link.upload([("\(udid)/partial", partial)])
                _ = try await link.expectStatus(0)
                transfer.continuation.yield(())
                transfer.continuation.finish()
                _ = try? await link.messages.receive(timeout: 5)
            }
            let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-cancel")
            defer { removeTestBackupRoot(root) }
            let events = LockedValue<[BackupEvent]>([])
            let backup = Task {
                try await DeviceSession.with(server.target, usbmux: server.client) { session in
                    try await MobileBackup2.backup(session, options: BackupOptions(destinationRoot: root, forceFullBackup: true)) { event in
                        events.withLock { $0.append(event) }
                    }
                }
            }
            for await _ in transfer.stream { backup.cancel() }
            do {
                _ = try await backup.value
                Issue.record("A cancelled backup completed")
            } catch is CancellationError {
                // Expected cancellation from the production channel's pending read.
            }
            try await withTimeout(5, operation: "Receiving cancelled-backup sync completion notifications") {
                for await _ in notificationCompletion.stream { break }
            }
            #expect(operations.current == [0x0D, 0x1B, 0x1B, 0x14])
            #expect(notifications.current == [
                "com.apple.itunes-mobdev.syncWillStart",
                "com.apple.itunes-mobdev.syncLockRequest",
                "com.apple.itunes-mobdev.syncDidStart",
                "com.apple.itunes-mobdev.syncDidFinish",
            ])
            #expect(try Data(contentsOf: root.appendingPathComponent("\(udid)/partial")) == partial)
            #expect(!events.current.contains(.progress(100)))
            #expect(!events.current.contains { if case .finished = $0 { return true }; return false })
        }
    }

    @Test func nonTransientSyncLockFailureAbortsBeforeBackupRequest() async throws {
        try await withFakeDevice({ $0.domainValues["com.apple.mobile.backup"] = ["WillEncrypt": false] }) { server in
            let operations = LockedValue<[UInt64]>([])
            let startedBackup = LockedValue(false)
            server.register(service: AFCClient.mediaServiceName) { channel in
                try await serveSyncLock(channel, lockStatuses: [10], unlockStatus: 0, operations: operations)
            }
            server.register(service: MobileBackup2.serviceName) { _ in startedBackup.withLock { $0 = true } }
            let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-lock-denied")
            defer { removeTestBackupRoot(root) }
            let events = LockedValue<[BackupEvent]>([])
            do {
                _ = try await DeviceSession.with(server.target, usbmux: server.client) { session in
                    try await MobileBackup2.backup(session, options: BackupOptions(destinationRoot: root, forceFullBackup: true)) { event in
                        events.withLock { $0.append(event) }
                    }
                }
                Issue.record("Backup continued after the lock was denied")
            } catch let error as ToolkitError {
                #expect(error.kind == .permissionDenied)
            }
            #expect(!startedBackup.current)
            #expect(operations.current == [0x0D, 0x1B, 0x1B, 0x14])
            #expect(!events.current.contains(.progress(100)))
            #expect(!events.current.contains { if case .finished = $0 { return true }; return false })
        }
    }

    @Test func transientSyncLockContentionIsRetried() async throws {
        try await withFakeDevice({ $0.domainValues["com.apple.mobile.backup"] = ["WillEncrypt": false] }) { server in
            let operations = LockedValue<[UInt64]>([])
            server.register(service: AFCClient.mediaServiceName) { channel in
                try await serveSyncLock(channel, lockStatuses: [19, 0], unlockStatus: 0, operations: operations)
            }
            let udid = server.udid
            let status = try PlistValue.dictionary(["SnapshotState": "finished"]).encoded()
            server.register(service: MobileBackup2.serviceName) { channel in
                let link = FakeDeviceLink(channel: channel)
                _ = try await link.handshake()
                try await link.messages.send(["DLMessageUploadFiles", [], 0, 100.0], format: .binary)
                try await link.upload([("\(udid)/Status.plist", status)])
                _ = try await link.expectStatus(0)
                try await link.messages.send(["DLMessageProcessMessage", ["ErrorCode": 0]], format: .binary)
                _ = try? await link.messages.receive(timeout: 2)
            }
            let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-lock-busy")
            defer { removeTestBackupRoot(root) }
            let events = LockedValue<[BackupEvent]>([])
            let result = try await DeviceSession.with(server.target, usbmux: server.client) { session in
                try await MobileBackup2.backup(session, options: BackupOptions(destinationRoot: root, forceFullBackup: true)) { event in
                    events.withLock { $0.append(event) }
                }
            }
            #expect(result.lastPathComponent == udid)
            #expect(operations.current == [0x0D, 0x1B, 0x1B, 0x1B, 0x14])
            #expect(events.current.contains(.progress(100)))
            #expect(events.current.last == .finished(result))
        }
    }

    @Test func syncLockReleaseFailureRetainsValidatedOutputWithoutCompleting() async throws {
        try await withFakeDevice({ $0.domainValues["com.apple.mobile.backup"] = ["WillEncrypt": false] }) { server in
            let operations = LockedValue<[UInt64]>([])
            server.register(service: AFCClient.mediaServiceName) { channel in
                try await serveSyncLock(channel, lockStatuses: [0], unlockStatus: 10, operations: operations)
            }
            let udid = server.udid
            let status = try PlistValue.dictionary(["SnapshotState": "finished"]).encoded()
            server.register(service: MobileBackup2.serviceName) { channel in
                let link = FakeDeviceLink(channel: channel)
                _ = try await link.handshake()
                try await link.messages.send(["DLMessageUploadFiles", [], 0, 100.0], format: .binary)
                try await link.upload([("\(udid)/Status.plist", status)])
                _ = try await link.expectStatus(0)
                try await link.messages.send(["DLMessageProcessMessage", ["ErrorCode": 0]], format: .binary)
                _ = try? await link.messages.receive(timeout: 2)
            }
            let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-release-denied")
            defer { removeTestBackupRoot(root) }
            let events = LockedValue<[BackupEvent]>([])
            do {
                _ = try await DeviceSession.with(server.target, usbmux: server.client) { session in
                    try await MobileBackup2.backup(session, options: BackupOptions(destinationRoot: root, forceFullBackup: true)) { event in
                        events.withLock { $0.append(event) }
                    }
                }
                Issue.record("A failed sync-lock release completed the backup")
            } catch let error as ToolkitError {
                #expect(error.kind == .permissionDenied)
            }
            #expect(try Data(contentsOf: root.appendingPathComponent("\(udid)/Status.plist")) == status)
            #expect(operations.current == [0x0D, 0x1B, 0x1B, 0x14])
            #expect(!events.current.contains(.progress(100)))
            #expect(!events.current.contains { if case .finished = $0 { return true }; return false })
        }
    }

    @Test func missingSyncLockIsReportedWhileAValidatedBackupCompletes() async throws {
        try await withFakeDevice({ $0.domainValues["com.apple.mobile.backup"] = ["WillEncrypt": false] }) { server in
            let operations = LockedValue<[UInt64]>([])
            let notifications = LockedValue<[String]>([])
            let notificationCompletion = AsyncStream<Void>.makeStream()
            server.register(service: AFCClient.mediaServiceName) { channel in
                try await serveMissingSyncLock(channel, operations: operations)
            }
            server.register(service: NotificationProxy.serviceName) { channel in
                let messages = PlistMessageConnection(channel: channel)
                while try await channel.hasMoreData() {
                    let message = try await messages.receive(timeout: 5)
                    if let name = message["Name"]?.stringValue { notifications.withLock { $0.append(name) } }
                    if message["Command"]?.stringValue == "Shutdown" {
                        notificationCompletion.continuation.yield(())
                        notificationCompletion.continuation.finish()
                        break
                    }
                }
            }
            let udid = server.udid
            let status = try PlistValue.dictionary(["SnapshotState": "finished"]).encoded()
            server.register(service: MobileBackup2.serviceName) { channel in
                let link = FakeDeviceLink(channel: channel)
                _ = try await link.handshake()
                try await link.messages.send(["DLMessageUploadFiles", [], 0, 100.0], format: .binary)
                try await link.upload([("\(udid)/Status.plist", status)])
                _ = try await link.expectStatus(0)
                try await link.messages.send(["DLMessageProcessMessage", ["ErrorCode": 0]], format: .binary)
                _ = try? await link.messages.receive(timeout: 2)
            }
            let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-lock-unavailable")
            defer { removeTestBackupRoot(root) }
            let events = LockedValue<[BackupEvent]>([])
            let result = try await DeviceSession.with(server.target, usbmux: server.client) { session in
                try await MobileBackup2.backup(session, options: BackupOptions(destinationRoot: root, forceFullBackup: true)) { event in
                    events.withLock { $0.append(event) }
                }
            }
            try await withTimeout(5, operation: "Receiving missing-lock sync completion notifications") {
                for await _ in notificationCompletion.stream { break }
            }
            #expect(try Data(contentsOf: result.appendingPathComponent("Status.plist")) == status)
            #expect(operations.current == [0x0D])
            #expect(notifications.current == [
                "com.apple.itunes-mobdev.syncWillStart",
                "com.apple.itunes-mobdev.syncDidFinish",
            ])
            #expect(events.current.contains {
                if case .status(let message) = $0 {
                    return message.contains("concurrent sync exclusion") && message.contains("unavailable")
                }
                return false
            })
            #expect(events.current.filter { $0 == .progress(100) }.count == 1)
            #expect(events.current.last == .finished(result))
        }
    }

    @Test func syncLockUsesNotificationsAndAFCLock() async throws {
        let fileSystem = FakeAFCFileSystem(files: [:])
        let notifications = LockedValue<[String]>([])
        let notificationCompletion = AsyncStream<Void>.makeStream()
        try await withFakeDevice({ $0.domainValues["com.apple.mobile.backup"] = ["WillEncrypt": false] }) { server in
            server.register(service: AFCClient.mediaServiceName) { channel in try await fileSystem.serve(channel) }
            server.register(service: NotificationProxy.serviceName) { channel in
                let messages = PlistMessageConnection(channel: channel)
                while let message = try? await messages.receive(timeout: 5) {
                    if let name = message["Name"]?.stringValue { notifications.withLock { $0.append(name) } }
                    if message["Command"]?.stringValue == "Shutdown" {
                        notificationCompletion.continuation.yield(())
                        notificationCompletion.continuation.finish()
                        break
                    }
                }
            }
            server.register(service: MobileBackup2.serviceName) { channel in
                let link = FakeDeviceLink(channel: channel)
                _ = try await link.handshake()
                let status = try PlistValue.dictionary(["SnapshotState": "finished"]).encoded()
                try await link.messages.send(["DLMessageUploadFiles", [], 0, 90.0], format: .binary)
                try await link.upload([("\(server.udid)/Status.plist", status)])
                _ = try await link.expectStatus(0)
                try await link.messages.send(["DLMessageProcessMessage", ["ErrorCode": 0]], format: .binary)
                _ = try? await link.messages.receive(timeout: 2)
            }
            let root = try SecureFileIO.makeTemporaryDirectory(prefix: "backup-lock")
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try await DeviceSession.with(server.target, usbmux: server.client) { session in
                try await MobileBackup2.backup(session, options: BackupOptions(destinationRoot: root, forceFullBackup: false)) { _ in }
            }
            try await withTimeout(5, operation: "Receiving backup sync completion notifications") {
                for await _ in notificationCompletion.stream { break }
            }
            #expect(await fileSystem.lockOperations == [AFCClient.LockOperation.exclusive.rawValue, AFCClient.LockOperation.unlock.rawValue])
            #expect(notifications.current == [
                "com.apple.itunes-mobdev.syncWillStart",
                "com.apple.itunes-mobdev.syncLockRequest",
                "com.apple.itunes-mobdev.syncDidStart",
                "com.apple.itunes-mobdev.syncDidFinish",
            ])
        }
    }

    @Test func progressExtraction() {
        #expect(DeviceLink.progress(in: ["DLMessageUploadFiles", [], 0, 42.5]) == 42.5)
        #expect(DeviceLink.progress(in: ["DLMessageUploadFiles", [], 12.0]) == 12.0)
        #expect(DeviceLink.progress(in: ["DLMessageUploadFiles", [], 0, 500.0]) == nil)
        #expect(DeviceLink.progress(in: ["DLMessageDisconnect"]) == nil)
    }
}
