import CryptoKit
import Darwin
import DeviceKit
import Foundation
import Testing
import ToolkitCore
@testable import ToolkitFeatures

private struct FirmwareSafetyFixture {
    let directory: URL
    let ipsw: URL
    let helper: URL
    let cache: URL
    let log: URL

    func selection(mode: FirmwareInstall.Mode) -> FirmwareInstallSelection {
        FirmwareInstallSelection(ipsw: ipsw, target: .udid("00008150-000B33334444002E"), productType: "iPhone18,1",
                                 deviceClass: "v53ap", chipID: 0x8150, boardID: 0x0C, mode: mode)
    }

    func validate(selection: FirmwareInstallSelection, runner: CommandRunning, transport: PersonalizationTransport) async throws -> ValidatedFirmwareInstall {
        try await ValidatedFirmwareInstall.validate(selection: selection, helper: helper, cacheDirectory: cache, logFile: log,
                                                    catalogSHA1: nil, runner: runner, signingTransport: transport)
    }

    func validatedUpdate() async throws -> ValidatedFirmwareInstall {
        try await validate(selection: selection(mode: .update), runner: FirmwareSafetyDetectionRunner.connected,
                           transport: FirmwareSafetySigningTransport.signed)
    }
}

private struct FirmwareSafetyDetectionRunner: CommandRunning {
    let output: String
    let exitCode: Int32
    let requests = LockedValue<[CommandRequest]>([])
    let streamCalls = LockedValue(0)

    static var connected: Self {
        Self(output: "Found device in Normal mode\nECID: 42\nIdentified device as v53ap, iPhone18,1\n", exitCode: 0)
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        requests.withLock { $0.append(request) }
        #expect(request.arguments.contains("--no-action"))
        return CommandResult(request: request, termination: .exited(exitCode), standardOutput: Data(output.utf8), standardError: Data(),
                             startedAt: Date(), finishedAt: Date())
    }

    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandStreamEvent, Error> {
        streamCalls.withLock { $0 += 1 }
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: ToolkitError(.internalInconsistency, message: "Validation attempted an installation stream."))
        }
    }
}

private struct FirmwareSafetySigningTransport: PersonalizationTransport {
    let reply: String
    let requests = LockedValue<[PlistValue]>([])

    static var signed: Self { Self(reply: "STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=<plist/>") }

    func send(_ body: Data) async throws -> Data {
        let request = try PlistValue.decode(body)
        requests.withLock { $0.append(request) }
        return Data(reply.utf8)
    }
}

private struct FirmwareSafetySelectionFields: Sendable {
    let productType: String
    let deviceClass: String
    let chipID: Int
    let boardID: Int
}

private enum FirmwareSafetyTerminationEvent: Sendable, Equatable {
    case disabled
    case enabled
}

private struct FirmwareSafetyTerminationControl: FirmwareTerminationControlling {
    let events: LockedValue<[FirmwareSafetyTerminationEvent]>

    func disableSuddenTermination() { events.withLock { $0.append(.disabled) } }
    func enableSuddenTermination() { events.withLock { $0.append(.enabled) } }
}

private struct FirmwareSafetyControlledRunner: OwnedCommandRunning {
    let events: AsyncThrowingStream<CommandStreamEvent, Error>
    let continuation: AsyncThrowingStream<CommandStreamEvent, Error>.Continuation
    let token: LockedValue<CommandCancellation?>
    let cancellationRequested: @Sendable () -> Void

    func run(_ request: CommandRequest) async throws -> CommandResult {
        throw ToolkitError(.internalInconsistency, message: "The controlled installer was invoked as a preflight.")
    }

    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandStreamEvent, Error> {
        Issue.record("Firmware installation used an unowned command stream.")
        return events
    }

    func stream(_ request: CommandRequest, cancellation: CommandCancellation) -> AsyncThrowingStream<CommandStreamEvent, Error> {
        token.withLock { $0 = cancellation }
        continuation.onTermination = { _ in cancellation.clear() }
        cancellation.register(cancellationRequested)
        return events
    }
}

@Suite("Validated firmware installation")
struct FirmwareInstallSafetyTests {
    private static func fixture(manifest: Data) throws -> FirmwareSafetyFixture {
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "firmware-install-safety")
        let ipsw = directory.appendingPathComponent("firmware.ipsw")
        var writer = ZipWriter()
        try writer.add(name: FirmwareManifest.fileName, data: manifest)
        try writer.add(name: "Firmware/all_flash/iBoot.im4p", data: Data(repeating: 1, count: 4096))
        try SecureFileIO.writeNewFile(writer.finalized(), to: ipsw)
        let helper = directory.appendingPathComponent("idevicerestore")
        try SecureFileIO.writeNewFile(Data("#!/bin/sh\nexit 0\n".utf8), to: helper, mode: 0o755)
        return FirmwareSafetyFixture(directory: directory, ipsw: ipsw, helper: helper,
                                     cache: directory.appendingPathComponent("cache"), log: directory.appendingPathComponent("restore.log"))
    }

    private static func removeFixture(_ fixture: FirmwareSafetyFixture) {
        do { try FileManager.default.removeItem(at: fixture.directory) }
        catch { Issue.record("Could not remove the firmware test fixture: \(error.localizedDescription)") }
    }

    private static func identities() throws -> [PlistValue] {
        try #require(try PlistValue.decode(FirmwareTests.manifestData())["BuildIdentities"]?.arrayValue)
    }

    private static func manifest(identities: [PlistValue]) throws -> Data {
        var fields = try #require(try PlistValue.decode(FirmwareTests.manifestData()).dictionaryValue)
        fields["BuildIdentities"] = .array(identities)
        return try PlistValue.dictionary(fields).encoded(format: .xml)
    }

    @Test func matchingUpdateProducesAnExactDeviceAndVariantCommand() async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let runner = FirmwareSafetyDetectionRunner.connected
        let transport = FirmwareSafetySigningTransport.signed
        let plan = try await fixture.validate(selection: fixture.selection(mode: .update), runner: runner, transport: transport)
        let request = try FirmwareInstall.request(plan: plan, cacheDirectory: fixture.cache, logFile: fixture.log, now: plan.validatedAt)
        #expect(plan.device.ecid == 42 && plan.device.deviceClass == "v53ap" && plan.device.productType == "iPhone18,1")
        #expect(plan.productVersion == "27.0.1" && plan.productBuild == "24A446")
        #expect(plan.buildIdentity.restoreBehavior == "Update" && plan.buildIdentity.variant == "Customer Upgrade Install (IPSW)")
        #expect(plan.signing == .signed && plan.installerPreflight.succeeded)
        #expect(plan.downloadIntegrity == .appleCatalogDigestUnavailable)
        #expect(plan.fileIdentity.sha256 == SHA256.hash(data: try Data(contentsOf: fixture.ipsw)).map { String(format: "%02x", $0) }.joined())
        #expect(request.arguments == ["--plain-progress", "--no-input", "--cache-path", fixture.cache.path, "--logfile", fixture.log.path,
                                      "--ecid", "0x2a", "--variant", "Customer Upgrade Install (IPSW)", fixture.ipsw.path])
        #expect(request.timeout == nil && !request.arguments.contains("--erase") && !request.arguments.contains("--no-action"))
        #expect(runner.requests.current.count == 1 && runner.streamCalls.current == 0)
        let signing = try #require(transport.requests.current.first)
        #expect(transport.requests.current.count == 1)
        #expect(signing["ApChipID"]?.intValue == plan.buildIdentity.chipID && signing["ApBoardID"]?.intValue == plan.buildIdentity.boardID)
        #expect(signing["UniqueBuildID"]?.dataValue == plan.buildIdentity.uniqueBuildID)
    }

    @Test func noUpdateIdentityCannotProduceAnInstallPlan() async throws {
        let fixture = try Self.fixture(manifest: Self.manifest(identities: []))
        defer { Self.removeFixture(fixture) }
        let transport = FirmwareSafetySigningTransport.signed
        await #expect(throws: ToolkitError.self) {
            _ = try await fixture.validate(selection: fixture.selection(mode: .update), runner: FirmwareSafetyDetectionRunner.connected, transport: transport)
        }
        #expect(transport.requests.current.isEmpty)
    }

    @Test func eraseOnlyFirmwareNeverSatisfiesUpdate() async throws {
        let identities = try Self.identities().filter { $0["Info"]?["RestoreBehavior"]?.stringValue == "Erase" }
        let fixture = try Self.fixture(manifest: Self.manifest(identities: identities))
        defer { Self.removeFixture(fixture) }
        let transport = FirmwareSafetySigningTransport.signed
        await #expect(throws: ToolkitError.self) {
            _ = try await fixture.validate(selection: fixture.selection(mode: .update), runner: FirmwareSafetyDetectionRunner.connected, transport: transport)
        }
        #expect(transport.requests.current.isEmpty)
    }

    @Test func anUpgradeVariantMarkedEraseIsRefused() async throws {
        let upgrade = try #require(try Self.identities().first { $0["Info"]?["RestoreBehavior"]?.stringValue == "Update" })
        var identity = try #require(upgrade.dictionaryValue)
        var info = try #require(identity["Info"]?.dictionaryValue)
        info["RestoreBehavior"] = "Erase"
        identity["Info"] = .dictionary(info)
        let fixture = try Self.fixture(manifest: Self.manifest(identities: [.dictionary(identity)]))
        defer { Self.removeFixture(fixture) }
        await #expect(throws: ToolkitError.self) {
            _ = try await fixture.validatedUpdate()
        }
    }

    @Test(arguments: [
        FirmwareSafetySelectionFields(productType: "iPhone17,1", deviceClass: "v53ap", chipID: 0x8150, boardID: 0x0C),
        FirmwareSafetySelectionFields(productType: "iPhone18,1", deviceClass: "v54ap", chipID: 0x8150, boardID: 0x0E),
        FirmwareSafetySelectionFields(productType: "iPhone18,1", deviceClass: "v53ap", chipID: 0x8140, boardID: 0x0C),
        FirmwareSafetySelectionFields(productType: "iPhone18,1", deviceClass: "v53ap", chipID: 0x8150, boardID: 0x0E),
    ])
    fileprivate func mismatchedProductClassChipOrBoardIsRefused(fields: FirmwareSafetySelectionFields) async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let selection = FirmwareInstallSelection(ipsw: fixture.ipsw, target: .ecid("42"), productType: fields.productType,
                                                deviceClass: fields.deviceClass, chipID: fields.chipID, boardID: fields.boardID, mode: .update)
        let runner = FirmwareSafetyDetectionRunner(output: "Found device in Normal mode\nECID: 42\nIdentified device as \(fields.deviceClass), \(fields.productType)\n", exitCode: 0)
        let transport = FirmwareSafetySigningTransport.signed
        await #expect(throws: ToolkitError.self) {
            _ = try await fixture.validate(selection: selection, runner: runner, transport: transport)
        }
        #expect(transport.requests.current.isEmpty && runner.streamCalls.current == 0)
    }

    @Test func exactDeviceSigningDoesNotFallBackToAnotherBoard() throws {
        let manifest = try FirmwareManifest.parse(FirmwareTests.manifestData())
        let known = try #require(FirmwareSigning.identityForCheck(manifest: manifest, deviceClass: "V54AP"))
        #expect(known.deviceClass == "v54ap" && known.boardID == 0x0E)
        #expect(FirmwareSigning.identityForCheck(manifest: manifest, deviceClass: "v99ap") == nil)
        #expect(FirmwareSigning.identityForCheck(manifest: manifest, deviceClass: nil) != nil)
    }

    @Test(arguments: ["STATUS=94&MESSAGE=This device isn't eligible for the requested build.", "STATUS=128&MESSAGE=Signing unavailable.", "unrecognized TSS response"])
    func rejectedOrUnknownSigningCannotProduceAnInstallRequest(reply: String) async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let runner = FirmwareSafetyDetectionRunner.connected
        let transport = FirmwareSafetySigningTransport(reply: reply)
        await #expect(throws: ToolkitError.self) {
            _ = try await fixture.validate(selection: fixture.selection(mode: .update), runner: runner, transport: transport)
        }
        #expect(transport.requests.current.count == 1)
        #expect(runner.requests.current.count == 1 && runner.requests.current.allSatisfy { $0.arguments.contains("--no-action") })
        #expect(runner.streamCalls.current == 0)
    }

    @Test func failedInstallerPreflightPreventsSigningAndInstallation() async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let runner = FirmwareSafetyDetectionRunner(output: "ERROR: Unable to discover device mode.\n", exitCode: 1)
        let transport = FirmwareSafetySigningTransport.signed
        await #expect(throws: ToolkitError.self) {
            _ = try await fixture.validate(selection: fixture.selection(mode: .update), runner: runner, transport: transport)
        }
        #expect(transport.requests.current.isEmpty && runner.streamCalls.current == 0)
    }

    @Test(arguments: ["Found device in Normal mode\n", "Found device in Normal mode\nECID: 42\nIdentified device as v53ap, iPhone18,1\nECID: 43\n"])
    func successfulPreflightWithoutOneExactIdentityIsRefused(output: String) async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let transport = FirmwareSafetySigningTransport.signed
        await #expect(throws: ToolkitError.self) {
            _ = try await fixture.validate(selection: fixture.selection(mode: .update), runner: FirmwareSafetyDetectionRunner(output: output, exitCode: 0), transport: transport)
        }
        #expect(transport.requests.current.isEmpty)
    }

    @Test func installerFindingADifferentECIDIsRefused() async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let selection = FirmwareInstallSelection(ipsw: fixture.ipsw, target: .ecid("43"), productType: "iPhone18,1",
                                                deviceClass: "v53ap", chipID: 0x8150, boardID: 0x0C, mode: .update)
        await #expect(throws: ToolkitError.self) {
            _ = try await fixture.validate(selection: selection, runner: FirmwareSafetyDetectionRunner.connected, transport: FirmwareSafetySigningTransport.signed)
        }
    }

    @Test func aPlanCannotBeReusedForAnotherIPSWDeviceOrMode() async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let plan = try await fixture.validatedUpdate()
        let otherIPSW = fixture.directory.appendingPathComponent("other.ipsw")
        try FileManager.default.copyItem(at: fixture.ipsw, to: otherIPSW)
        let differentFile = FirmwareInstallSelection(ipsw: otherIPSW, target: plan.selection.target, productType: "iPhone18,1",
                                                    deviceClass: "v53ap", chipID: 0x8150, boardID: 0x0C, mode: .update)
        let differentDevice = FirmwareInstallSelection(ipsw: fixture.ipsw, target: .ecid("43"), productType: "iPhone18,1",
                                                      deviceClass: "v53ap", chipID: 0x8150, boardID: 0x0C, mode: .update)
        #expect(throws: ToolkitError.self) { try plan.requireMatches(differentFile) }
        #expect(throws: ToolkitError.self) { try plan.requireMatches(differentDevice) }
        #expect(throws: ToolkitError.self) { try plan.requireMatches(fixture.selection(mode: .restore)) }
        try plan.requireMatches(fixture.selection(mode: .update))
    }

    @Test func replacingTheIPSWWithIdenticalBytesInvalidatesTheInstallRequest() async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let plan = try await fixture.validatedUpdate()
        let bytes = try Data(contentsOf: fixture.ipsw)
        try FileManager.default.moveItem(at: fixture.ipsw, to: fixture.directory.appendingPathComponent("original.ipsw"))
        try SecureFileIO.writeNewFile(bytes, to: fixture.ipsw)
        #expect(try Data(contentsOf: fixture.ipsw) == bytes)
        #expect(throws: ToolkitError.self) {
            _ = try FirmwareInstall.request(plan: plan, cacheDirectory: fixture.cache, logFile: fixture.log, now: plan.validatedAt)
        }
    }

    @Test func editingTheIPSWInPlaceWithRestoredModificationTimeInvalidatesTheInstallRequest() async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let plan = try await fixture.validatedUpdate()
        var before = stat()
        try #require(lstat(fixture.ipsw.path, &before) == 0)
        try #require(before.st_size > 0)
        let handle = try FileHandle(forUpdating: fixture.ipsw)
        let editOffset = UInt64(before.st_size / 2)
        try handle.seek(toOffset: editOffset)
        let original = try #require(try handle.read(upToCount: 1))
        try #require(original.count == 1)
        try handle.seek(toOffset: editOffset)
        try handle.write(contentsOf: Data([original[original.startIndex] ^ 1]))
        let times = [before.st_atimespec, before.st_mtimespec]
        let restored = times.withUnsafeBufferPointer { futimens(handle.fileDescriptor, $0.baseAddress) }
        try #require(restored == 0)
        try handle.close()
        var after = stat()
        try #require(lstat(fixture.ipsw.path, &after) == 0)
        #expect(before.st_ino == after.st_ino && before.st_size == after.st_size)
        #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
        #expect(throws: ToolkitError.self) {
            _ = try FirmwareInstall.request(plan: plan, cacheDirectory: fixture.cache, logFile: fixture.log, now: plan.validatedAt)
        }
    }

    @Test func changingTheRestoreHelperInvalidatesTheInstallRequest() async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let plan = try await fixture.validatedUpdate()
        try FileManager.default.moveItem(at: fixture.helper, to: fixture.directory.appendingPathComponent("original-helper"))
        try SecureFileIO.writeNewFile(Data("#!/bin/sh\nexit 1\n".utf8), to: fixture.helper, mode: 0o755)
        #expect(throws: ToolkitError.self) {
            _ = try FirmwareInstall.request(plan: plan, cacheDirectory: fixture.cache, logFile: fixture.log, now: plan.validatedAt)
        }
    }

    @Test func anExpiredPlanCannotBuildAnInstallRequest() async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let plan = try await fixture.validatedUpdate()
        let expired = plan.validatedAt.addingTimeInterval(ValidatedFirmwareInstall.maximumAge + 1)
        #expect(throws: ToolkitError.self) {
            _ = try FirmwareInstall.request(plan: plan, cacheDirectory: fixture.cache, logFile: fixture.log, now: expired)
        }
    }

    @Test func duplicateModelAndVariantIdentitiesAreRefused() async throws {
        let identities = try Self.identities()
        let upgrade = try #require(identities.first { $0["Info"]?["RestoreBehavior"]?.stringValue == "Update" })
        let fixture = try Self.fixture(manifest: Self.manifest(identities: identities + [upgrade]))
        defer { Self.removeFixture(fixture) }
        await #expect(throws: ToolkitError.self) { _ = try await fixture.validatedUpdate() }
    }

    @Test func observedDFUBlocksUpdateDespiteANormalDeviceSelection() async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let runner = FirmwareSafetyDetectionRunner(output: "Found device in DFU mode\nECID: 42\nIdentified device as v53ap, iPhone18,1\n", exitCode: 0)
        let transport = FirmwareSafetySigningTransport.signed
        await #expect(throws: ToolkitError.self) {
            _ = try await fixture.validate(selection: fixture.selection(mode: .update), runner: runner, transport: transport)
        }
        #expect(transport.requests.current.isEmpty)
        let restore = try await fixture.validate(selection: fixture.selection(mode: .restore), runner: runner, transport: transport)
        let request = try FirmwareInstall.request(plan: restore, cacheDirectory: fixture.cache, logFile: fixture.log, now: restore.validatedAt)
        #expect(request.arguments.contains("--erase") && request.arguments.contains("Customer Erase Install (IPSW)"))
        #expect(restore.buildIdentity.restoreBehavior == "Erase")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingDuringWritingWaitsForTheOwnedHelperToFinish() async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let plan = try await fixture.validatedUpdate()
        let request = try FirmwareInstall.request(plan: plan, cacheDirectory: fixture.cache, logFile: fixture.log, now: plan.validatedAt)
        let changes = LockedValue<[FirmwareSafetyTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: FirmwareSafetyTerminationControl(events: changes))
        let (events, continuation) = AsyncThrowingStream<CommandStreamEvent, Error>.makeStream()
        defer { continuation.finish() }
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        defer { enteredContinuation.finish() }
        let token = LockedValue<CommandCancellation?>(nil)
        let runner = FirmwareSafetyControlledRunner(events: events, continuation: continuation, token: token,
                                                   cancellationRequested: { Issue.record("A critical helper received cancellation.") })
        let task = Task {
            try await FirmwareInstall.run(plan: plan, cacheDirectory: fixture.cache, logFile: fixture.log,
                                          runner: runner, protection: protection,
                                          progress: { _, _ in enteredContinuation.yield(()) }, line: { _ in })
        }
        continuation.yield(.standardOutput(Data("progress: 2 0.5\n".utf8)))
        var enteredIterator = entered.makeAsyncIterator()
        try #require(await enteredIterator.next() != nil)
        #expect(protection.isCritical && changes.current == [.disabled])
        task.cancel()
        #expect(protection.isCritical && changes.current == [.disabled])
        #expect(try #require(token.current).isCancelled == false)
        continuation.yield(.finished(CommandResult(request: request, termination: .exited(0), standardOutput: Data(), standardError: Data(),
                                                    startedAt: Date(), finishedAt: Date())))
        continuation.finish()
        let result = try await task.value
        #expect(result.succeeded && !protection.isCritical)
        #expect(changes.current == [.disabled, .enabled])
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationBeforeWritingRetainsOwnershipUntilTheHelperExits() async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let plan = try await fixture.validatedUpdate()
        let changes = LockedValue<[FirmwareSafetyTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: FirmwareSafetyTerminationControl(events: changes))
        let (events, continuation) = AsyncThrowingStream<CommandStreamEvent, Error>.makeStream()
        defer { continuation.finish() }
        let (progress, progressContinuation) = AsyncStream<String>.makeStream()
        defer { progressContinuation.finish() }
        let (cancelled, cancelledContinuation) = AsyncStream<Void>.makeStream()
        defer { cancelledContinuation.finish() }
        let token = LockedValue<CommandCancellation?>(nil)
        let completed = LockedValue(false)
        let runner = FirmwareSafetyControlledRunner(events: events, continuation: continuation, token: token,
                                                   cancellationRequested: { cancelledContinuation.yield(()) })
        let task = Task {
            defer { completed.withLock { $0 = true } }
            return try await FirmwareInstall.run(plan: plan, cacheDirectory: fixture.cache, logFile: fixture.log,
                                                 runner: runner, protection: protection,
                                                 progress: { step, _ in progressContinuation.yield(step) }, line: { _ in })
        }
        continuation.yield(.standardOutput(Data("progress: 1 0.5\n".utf8)))
        var progressIterator = progress.makeAsyncIterator()
        try #require(await progressIterator.next() == "Preparing")
        task.cancel()
        var cancellationIterator = cancelled.makeAsyncIterator()
        try #require(await cancellationIterator.next() != nil)
        #expect(try #require(token.current).isCancelled)
        #expect(!completed.current && !protection.isCritical && changes.current.isEmpty)

        // Output buffered while the child stops must still enter the critical phase.
        continuation.yield(.standardOutput(Data("progress: 2 0.5\n".utf8)))
        try #require(await progressIterator.next() == "Sending the system")
        #expect(!completed.current && protection.isCritical && changes.current == [.disabled])
        continuation.finish(throwing: ToolkitError.cancelled("idevicerestore (update)"))
        await #expect(throws: ToolkitError.self) { _ = try await task.value }
        #expect(completed.current && !protection.isCritical && changes.current == [.disabled, .enabled])
    }

    @Test func aFailedOwnedHelperBalancesWriteProtection() async throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let plan = try await fixture.validatedUpdate()
        let changes = LockedValue<[FirmwareSafetyTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: FirmwareSafetyTerminationControl(events: changes))
        let runner = StreamingRunner(chunks: [.standardOutput(Data("progress: 2 0.5\n".utf8)), .standardError(Data("ERROR: Device disconnected.\n".utf8))], exitCode: 1)
        await #expect(throws: ToolkitError.self) {
            _ = try await FirmwareInstall.run(plan: plan, cacheDirectory: fixture.cache, logFile: fixture.log,
                                              runner: runner, protection: protection, progress: { _, _ in }, line: { _ in })
        }
        #expect(!protection.isCritical && changes.current == [.disabled, .enabled])
    }

    @Test func aDownloadWithAMatchingAppleDigestReportsThatProvenance() throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let bytes = try Data(contentsOf: fixture.ipsw)
        let staged = fixture.directory.appendingPathComponent("download.part")
        try SecureFileIO.writeNewFile(bytes, to: staged)
        let expected = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let destination = fixture.directory.appendingPathComponent("download.ipsw")
        let release = FirmwareRelease(productType: "iPhone18,1", version: "27.0.1", build: "24A446",
                                      url: try #require(URL(string: "https://example.invalid/download.ipsw")), sha1: expected.uppercased())
        let result = try FirmwareDownloader.complete(staged: staged, release: release, destination: destination)
        #expect(result.provenance == .appleCatalogSHA1Matched)
        #expect(result.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(result.url == destination && !FileManager.default.fileExists(atPath: staged.path))
        #expect(try Data(contentsOf: result.url) == bytes)
    }

    @Test func aDownloadWithoutAnAppleDigestReportsOnlyLocalHashing() throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let bytes = try Data(contentsOf: fixture.ipsw)
        let staged = fixture.directory.appendingPathComponent("download.part")
        try SecureFileIO.writeNewFile(bytes, to: staged)
        let destination = fixture.directory.appendingPathComponent("download.ipsw")
        let release = FirmwareRelease(productType: "iPhone18,1", version: "27.0.1", build: "24A446",
                                      url: try #require(URL(string: "https://example.invalid/download.ipsw")), sha1: nil)
        let result = try FirmwareDownloader.complete(staged: staged, release: release, destination: destination)
        #expect(result.provenance == .appleCatalogDigestUnavailable && result.provenance != .appleCatalogSHA1Matched)
        #expect(result.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(try Data(contentsOf: result.url) == bytes)
    }

    @Test func aMismatchedAppleDigestRejectsAndDeletesTheStagedDownload() throws {
        let fixture = try Self.fixture(manifest: FirmwareTests.manifestData())
        defer { Self.removeFixture(fixture) }
        let bytes = try Data(contentsOf: fixture.ipsw)
        let staged = fixture.directory.appendingPathComponent("download.part")
        try SecureFileIO.writeNewFile(bytes, to: staged)
        let destination = fixture.directory.appendingPathComponent("download.ipsw")
        let mismatched = String(repeating: "0", count: 40)
        let localSHA1 = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try FirmwareDownloadProvenance.assess(sha1: localSHA1, catalogSHA1: mismatched) == .digestMismatch)
        let release = FirmwareRelease(productType: "iPhone18,1", version: "27.0.1", build: "24A446",
                                      url: try #require(URL(string: "https://example.invalid/download.ipsw")), sha1: mismatched)
        #expect(throws: ToolkitError.self) {
            _ = try FirmwareDownloader.complete(staged: staged, release: release, destination: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: staged.path) && !FileManager.default.fileExists(atPath: destination.path))
    }
}
