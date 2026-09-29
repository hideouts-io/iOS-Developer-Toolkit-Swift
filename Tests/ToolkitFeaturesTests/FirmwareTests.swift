import Foundation
import Testing
@testable import DeviceKit
@testable import ToolkitFeatures
import ToolkitCore

@Suite("Firmware: catalog, manifests, signing, library, helpers")
struct FirmwareTests {
    // MARK: Fixtures

    /// Abridged from Apple's catalog (https://itunes.apple.com/check/version).
    static let catalog = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>MobileDeviceSoftwareVersionsByVersion</key><dict>
        <key>17</key><dict><key>MobileDeviceSoftwareVersions</key><dict>
          <key>iPhone18,1</key><dict>
            <key>23A330</key><dict><key>Restore</key><dict>
              <key>BuildVersion</key><string>24A446</string><key>ProductVersion</key><string>27.0.1</string>
              <key>FirmwareURL</key><string>http://updates.cdn-apple.com/2026FallFCS/fullrestores/093-1/iPhone18,1_27.0.1_24A446_Restore.ipsw</string>
              <key>FirmwareSHA1</key><string>D14FB2344A6831E36C410BA59ECD977F78F22235</string></dict></dict>
            <key>24A446</key><dict><key>Restore</key><dict>
              <key>BuildVersion</key><string>24A446</string><key>ProductVersion</key><string>27.0.1</string>
              <key>FirmwareURL</key><string>http://updates.cdn-apple.com/2026FallFCS/fullrestores/093-1/iPhone18,1_27.0.1_24A446_Restore.ipsw</string>
              <key>FirmwareSHA1</key><string>d14fb2344a6831e36c410ba59ecd977f78f22235</string></dict></dict>
          </dict>
          <key>iPhone17,1</key><dict><key>22A1</key><dict><key>Restore</key><dict>
              <key>BuildVersion</key><string>23D8133</string><key>ProductVersion</key><string>26.3.1</string>
              <key>FirmwareURL</key><string>https://updates.cdn-apple.com/x/iPhone17,1_26.3.1_23D8133_Restore.ipsw</string></dict></dict></dict>
        </dict></dict>
        <key>16</key><dict><key>MobileDeviceSoftwareVersions</key><dict>
          <key>iPhone18,1</key><dict><key>23A1</key><dict><key>Restore</key><dict>
              <key>BuildVersion</key><string>23D8133</string><key>ProductVersion</key><string>26.3.1</string>
              <key>FirmwareURL</key><string>https://updates.cdn-apple.com/y/iPhone18,1_26.3.1_23D8133_Restore.ipsw</string></dict></dict></dict>
        </dict></dict>
      </dict>
    </dict></plist>
    """

    static func manifestData() throws -> Data {
        func identity(_ behavior: String, board: String) -> PlistValue {
            .dictionary([
                "ApChipID": "0x8150", "ApBoardID": .string(board), "ApSecurityDomain": "0x01",
                "UniqueBuildID": .data(Data([1, 2, 3, 4])), "Ap,ProductType": "iPhone18,1", "Ap,OSLongVersion": "27.0.1.24A446",
                "Info": .dictionary(["DeviceClass": "v53ap", "Variant": .string("Customer \(behavior) Install (IPSW)"), "RestoreBehavior": .string(behavior)]),
                "Manifest": .dictionary([
                    "KernelCache": .dictionary(["Digest": .data(Data(repeating: 7, count: 48)), "Trusted": true, "Info": .dictionary(["Path": "kernelcache"])]),
                    "Untrusted": .dictionary(["Digest": .data(Data([9])), "Info": .dictionary(["Path": "x"])]),
                    "BasebandFirmware": .dictionary(["Digest": .data(Data([8])), "Trusted": true, "Info": .dictionary(["Path": "bb"])]),
                    "Ap,Rules": .dictionary(["Digest": .data(Data([6])), "Info": .dictionary(["Path": "r", "RestoreRequestRules": .array([
                        .dictionary(["Conditions": .dictionary(["ApRawProductionMode": true]), "Actions": .dictionary(["EPRO": true])]),
                    ])])]),
                ]),
            ])
        }
        return try PlistValue.dictionary([
            "ProductVersion": "27.0.1", "ProductBuildVersion": "24A446",
            "SupportedProductTypes": .array(["iPhone18,1"]),
            "BuildIdentities": .array([identity("Update", board: "0x0C"), identity("Erase", board: "0x0C"), identity("Erase", board: "0x0E")]),
        ]).encoded(format: .xml)
    }

    static func fakeIPSW(in directory: URL, name: String = "iPhone18,1_27.0.1_24A446_Restore.ipsw") throws -> URL {
        var writer = ZipWriter()
        try writer.add(name: "Restore.plist", data: Data("x".utf8))
        try writer.add(name: FirmwareManifest.fileName, data: try manifestData())
        try writer.add(name: "Firmware/all_flash/iBoot.im4p", data: Data(repeating: 1, count: 4096))
        let url = directory.appendingPathComponent(name)
        try SecureFileIO.writeNewFile(writer.finalized(), to: url)
        return url
    }

    // MARK: Catalog

    @Test func readsApplesFirmwareCatalog() throws {
        let releases = try FirmwareCatalog.releases(fromCatalog: Data(Self.catalog.utf8), productType: "iPhone18,1")
        #expect(releases.map(\.build) == ["24A446", "23D8133"], "deduplicated and newest first")
        #expect(releases[0].version == "27.0.1" && releases[0].url.scheme == "https", "HTTP links are upgraded to HTTPS")
        #expect(releases[0].sha1 == "d14fb2344a6831e36c410ba59ecd977f78f22235")
        #expect(releases[0].fileName == "iPhone18,1_27.0.1_24A446_Restore.ipsw")
        #expect(try FirmwareCatalog.releases(fromCatalog: Data(Self.catalog.utf8), productType: "iPad99,9").isEmpty)
        #expect(throws: ToolkitError.self) { try FirmwareCatalog.releases(fromCatalog: Data("not a plist".utf8), productType: "x") }
    }

    @Test func catalogIsCachedForADay() async throws {
        struct Fetcher: DataFetching {
            let calls = LockedValue(0)
            func data(from url: URL, limit: Int) async throws -> Data { calls.withLock { $0 += 1 }; return Data(FirmwareTests.catalog.utf8) }
        }
        let folder = try SecureFileIO.makeTemporaryDirectory(prefix: "catalog")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("version.plist")
        let fetcher = Fetcher()
        _ = try await FirmwareCatalog.load(cache: cache, fetcher: fetcher)
        _ = try await FirmwareCatalog.load(cache: cache, fetcher: fetcher)
        #expect(fetcher.calls.current == 1)
        _ = try await FirmwareCatalog.load(cache: cache, fetcher: fetcher, now: Date().addingTimeInterval(2 * 86_400))
        #expect(fetcher.calls.current == 2)
    }

    // MARK: Manifest and signing

    @Test func readsTheBuildManifestAndPicksTheIdentity() throws {
        let manifest = try FirmwareManifest.parse(try Self.manifestData())
        #expect(manifest.productVersion == "27.0.1" && manifest.productBuild == "24A446")
        #expect(manifest.supportedProductTypes == ["iPhone18,1"])
        #expect(manifest.identities.count == 3)
        #expect(manifest.identity(chipID: 0x8150, boardID: 0x0E)?.boardID == 0x0E)
        #expect(manifest.identity()?.restoreBehavior == "Erase", "an erase identity is preferred")
        #expect(manifest.identity(behavior: "Update")?.restoreBehavior == "Update")
        #expect(manifest.identity(chipID: 0x8140) == nil)
        #expect(throws: ToolkitError.self) { try FirmwareManifest.parse(try PlistValue.dictionary(["x": 1]).encoded(format: .xml)) }
    }

    @Test func asksAppleWhetherTheFirmwareIsSigned() async throws {
        let identity = try #require(try FirmwareManifest.parse(try Self.manifestData()).identity())
        let request = FirmwareSigning.request(identity: identity, ecid: 42, nonce: Data(repeating: 5, count: 32))
        #expect(request["ApChipID"]?.intValue == 0x8150 && request["ApBoardID"]?.intValue == 0x0C)
        #expect(request["ApECID"]?.intValue == 42 && request["ApNonce"]?.dataValue == Data(repeating: 5, count: 32))
        #expect(request["UniqueBuildID"]?.dataValue == Data([1, 2, 3, 4]))
        #expect(request["KernelCache"]?["Digest"]?.dataValue == Data(repeating: 7, count: 48))
        #expect(request["KernelCache"]?["Info"] == nil && request["KernelCache"]?["EPRO"]?.boolValue == true)
        #expect(request["Untrusted"] == nil, "only trusted components, or ones with request rules, are signed")
        #expect(request["Ap,Rules"]?["EPRO"]?.boolValue == true, "request rules are applied")
        #expect(request["BasebandFirmware"] == nil && request["@BBTicket"] == nil, "the baseband is signed in its own request")
        #expect(request["Ap,ProductType"]?.stringValue == "iPhone18,1" && request["Ap,OSLongVersion"]?.stringValue == "27.0.1.24A446")
        #expect(request["ApSecurityDomain"]?.intValue == 1 && request["SepNonce"]?.dataValue?.count == 20)
        // A random ECID is used by default, never a device's.
        #expect(FirmwareSigning.request(identity: identity)["ApECID"]?.intValue != FirmwareSigning.request(identity: identity)["ApECID"]?.intValue)

        #expect(FirmwareSigning.status(fromResponse: Data("STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=<plist/>".utf8)) == .signed)
        #expect(FirmwareSigning.status(fromResponse: Data("STATUS=94&MESSAGE=This device isn't eligible for the requested build.".utf8)) == .notSigned)
        guard case .unknown = FirmwareSigning.status(fromResponse: Data("STATUS=128&MESSAGE=nope".utf8)) else { Issue.record("expected unknown"); return }

        struct Transport: PersonalizationTransport {
            let reply: String
            func send(_ body: Data) async throws -> Data {
                #expect(try PlistValue.decode(body)["@ApImg4Ticket"]?.boolValue == true)
                return Data(reply.utf8)
            }
        }
        #expect(await FirmwareSigning.check(identity: identity, transport: Transport(reply: "STATUS=94&MESSAGE=not eligible")) == .notSigned)
        #expect(await FirmwareSigning.check(identity: identity, transport: Transport(reply: "STATUS=0&MESSAGE=SUCCESS")) == .signed)
    }

    // MARK: Remote and local IPSWs

    @Test func readsTheManifestFromAnIPSWOnAServer() async throws {
        struct Server: RangeFetching {
            let file: Data
            let requested = LockedValue<Int>(0)
            func size(of url: URL) async throws -> UInt64 { UInt64(file.count) }
            func data(_ url: URL, range: ClosedRange<UInt64>) async throws -> Data {
                requested.withLock { $0 += Int(range.upperBound - range.lowerBound + 1) }
                return file.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1))
            }
        }
        let folder = try SecureFileIO.makeTemporaryDirectory(prefix: "remote-ipsw")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = Server(file: try Data(contentsOf: try Self.fakeIPSW(in: folder)))
        let data = try await RemoteArchive.file(named: FirmwareManifest.fileName, in: URL(string: "https://example.invalid/x.ipsw")!, fetcher: server)
        #expect(try FirmwareManifest.parse(data).productBuild == "24A446")
        await #expect(throws: ToolkitError.self) { _ = try await RemoteArchive.file(named: "Missing.plist", in: URL(string: "https://example.invalid/x.ipsw")!, fetcher: server) }
    }

    @Test func keepsALocalLibraryOfIPSWs() throws {
        let folder = try SecureFileIO.makeTemporaryDirectory(prefix: "ipsw-library")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try Self.fakeIPSW(in: folder)
        try SecureFileIO.writeNewFile(Data("not a zip".utf8), to: folder.appendingPathComponent("broken.ipsw"))
        let files = IPSWLibrary.scan(folder)
        #expect(files.count == 1, "unreadable files are skipped")
        #expect(files[0].title == "iOS 27.0.1 (24A446)" && files[0].supports(productType: "iPhone18,1") && !files[0].supports(productType: "iPad1,1"))
        let sums = try IPSWLibrary.checksums(of: url)
        #expect(sums.sha1.count == 40 && sums.sha256.count == 64)
        #expect(IPSWLibrary.defaultDirectory(home: URL(fileURLWithPath: "/Users/x")).path == "/Users/x/Library/Application Support/iOS Developer Toolkit (Swift)/Firmware")
        #expect(throws: ToolkitError.self) { try IPSWLibrary.inspect(folder.appendingPathComponent("broken.ipsw")) }
    }

    // MARK: Helpers

    @Test func readsRecoveryAndDFUDevices() throws {
        let recovery = RecoveryProbe.parse("""
        CPID: 0x8150
        CPRV: 0x11
        BDID: 0x0c
        ECID: 0x001A2B3C4D5E6F
        SRTG: iBoot-12345
        MODE: Recovery
        PRODUCT: iPhone18,1
        MODEL: v53ap
        """)
        #expect(recovery == RecoveryDevice(mode: .recovery, ecid: "0x001A2B3C4D5E6F", chipID: "0x8150", boardID: "0x0c", productType: "iPhone18,1", model: "v53ap"))
        #expect(RecoveryProbe.parse("MODE: DFU\nECID: 0x1\n")?.mode == .dfu)
        #expect(RecoveryProbe.parse("ERROR: Unable to connect to device") == nil)
        let exit = try RecoveryProbe.exitRecoveryRequest(helper: URL(fileURLWithPath: "/x/irecovery"), ecid: "0x001A2B3C4D5E6F")
        #expect(exit.arguments == ["-i", "0x001A2B3C4D5E6F", "-n"])
        #expect(throws: ToolkitError.self) { try RecoveryProbe.exitRecoveryRequest(helper: URL(fileURLWithPath: "/x/irecovery"), ecid: "1; rm -rf /") }
    }

    @Test func buildsTheInstallCommand() throws {
        let folder = try SecureFileIO.makeTemporaryDirectory(prefix: "install")
        defer { try? FileManager.default.removeItem(at: folder) }
        let ipsw = try Self.fakeIPSW(in: folder)
        let helper = URL(fileURLWithPath: "/App/Contents/Helpers/idevicerestore")
        let cache = folder.appendingPathComponent("cache"), log = folder.appendingPathComponent("restore.log")
        let update = try FirmwareInstall.request(helper: helper, ipsw: ipsw, mode: .update, target: .udid("00008150-000B33334444002E"), cacheDirectory: cache, logFile: log, preflightOnly: false)
        #expect(update.arguments == ["--plain-progress", "--no-input", "--cache-path", cache.path, "--logfile", log.path, "--udid", "00008150-000B33334444002E", ipsw.path])
        #expect(update.timeout == nil)
        let restore = try FirmwareInstall.request(helper: helper, ipsw: ipsw, mode: .restore, target: .ecid("0x1A2B"), cacheDirectory: cache, logFile: log, preflightOnly: true)
        #expect(restore.arguments.contains("--erase") && restore.arguments.contains("--no-action") && restore.arguments.contains("--ecid"))
        #expect(!update.arguments.contains("--erase"), "an update never erases")
        #expect(throws: ToolkitError.self) { try FirmwareInstall.request(helper: helper, ipsw: folder.appendingPathComponent("x.zip"), mode: .update, target: .udid("00008150-000B33334444002E"), cacheDirectory: cache, logFile: log, preflightOnly: false) }
        #expect(throws: ToolkitError.self) { try FirmwareInstall.request(helper: helper, ipsw: ipsw, mode: .update, target: .udid("--erase"), cacheDirectory: cache, logFile: log, preflightOnly: false) }
    }

    @Test func followsProgressAndExplainsFailures() {
        let progress = FirmwareInstall.progress("progress: 2 0.500000")
        #expect(progress?.step == "Sending the system" && progress?.fraction == 0.5)
        #expect(FirmwareInstall.progress("progress: 99 1.5")?.fraction == 1)
        #expect(FirmwareInstall.progress("Waiting for device...") == nil)
        #expect(!FirmwareInstall.isPastPointOfNoReturn(step: "Preparing"))
        #expect(FirmwareInstall.isPastPointOfNoReturn(step: "Sending the system"))
        #expect(FirmwareInstall.failureReason(output: "ERROR: This device isn't eligible for the requested build.").contains("does not sign"))
        #expect(FirmwareInstall.failureReason(output: "ERROR: Unable to discover device mode.").contains("could not be found"))
        #expect(FirmwareInstall.failureReason(output: "something\nERROR: Out of disk space") == "Out of disk space")
    }

    @Test func locatesTheBundledHelpers() throws {
        #expect(throws: ToolkitError.self) { try RestoreHelper.idevicerestore.locate(bundle: Bundle(for: BundleMarker.self), environment: [:]) }
        let folder = try SecureFileIO.makeTemporaryDirectory(prefix: "helpers")
        defer { try? FileManager.default.removeItem(at: folder) }
        try SecureFileIO.writeNewFile(Data("#!/bin/sh\n".utf8), to: folder.appendingPathComponent("irecovery"), mode: 0o755)
        #expect(try RestoreHelper.irecovery.locate(environment: ["IDT_RESTORE_HELPERS": folder.path]) == folder.appendingPathComponent("irecovery"))
    }

    @Test func runsTheInstallerAndReportsProgress() async throws {
        let helper = URL(fileURLWithPath: "/x/idevicerestore")
        let request = CommandRequest(executable: helper, arguments: ["--plain-progress"], timeout: nil)
        // Output arrives in chunks that split lines.
        let runner = StreamingRunner(chunks: [.standardOutput(Data("progress: 0 0.5\nprog".utf8)), .standardOutput(Data("ress: 2 0.25\nFound device in Recovery mode\n".utf8))], exitCode: 0)
        let steps = LockedValue<[String]>([]), lines = LockedValue<[String]>([])
        _ = try await FirmwareInstall.run(request, runner: runner, progress: { step, fraction in steps.withLock { $0.append("\(step) \(fraction)") } }, line: { line in lines.withLock { $0.append(line) } })
        #expect(steps.current == ["Finding the device 0.5", "Sending the system 0.25"])
        #expect(lines.current == ["Found device in Recovery mode"])

        let failing = StreamingRunner(chunks: [.standardError(Data("ERROR: Unable to discover device mode.\n".utf8))], exitCode: 255)
        do {
            _ = try await FirmwareInstall.run(request, runner: failing, progress: { _, _ in }, line: { _ in })
            Issue.record("expected a failure")
        } catch let error as ToolkitError {
            #expect(error.message.contains("could not be found"))
        }

        let recovery = StreamingRunner(chunks: [.standardOutput(Data("MODE: DFU\nECID: 0x1A\nPRODUCT: iPhone18,1\n".utf8))], exitCode: 0)
        #expect(await RecoveryProbe.query(runner: recovery, helper: URL(fileURLWithPath: "/x/irecovery"))?.mode == .dfu)
        #expect(await RecoveryProbe.query(runner: StreamingRunner(chunks: [], exitCode: 255), helper: URL(fileURLWithPath: "/x/irecovery")) == nil)
    }

    @Test func checksTheFirmwareBeforeInstalling() throws {
        let folder = try SecureFileIO.makeTemporaryDirectory(prefix: "preflight")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try IPSWLibrary.inspect(try Self.fakeIPSW(in: folder))
        let good = FirmwarePreflight.localChecks(ipsw: file, productType: "iPhone18,1", deviceClass: "V53AP", mode: .update)
        #expect(good.allSatisfy { $0.passed == true })
        let otherModel = FirmwarePreflight.localChecks(ipsw: file, productType: "iPhone17,1", deviceClass: "v53ap", mode: .restore)
        #expect(otherModel.first?.passed == false && otherModel.first?.detail.contains("not iPhone17,1") == true)
        #expect(FirmwarePreflight.localChecks(ipsw: file, productType: nil, deviceClass: "d47ap", mode: .restore).map(\.passed) == [false])
        #expect(FirmwarePreflight.signingCheck(.signed).passed == true)
        #expect(FirmwarePreflight.signingCheck(.notSigned).passed == false)
        #expect(FirmwarePreflight.signingCheck(.unknown("offline")).passed == nil)
        #expect(try #require(FirmwareManifest.parse(try Self.manifestData()).identity(deviceClass: "V53AP")).deviceClass == "v53ap")
    }
}

private final class BundleMarker {}

/// Streams scripted output, then finishes with `exitCode`.
struct StreamingRunner: CommandRunning {
    let chunks: [CommandStreamEvent]
    let exitCode: Int32

    func run(_ request: CommandRequest) async throws -> CommandResult {
        var output = Data(), errors = Data()
        for chunk in chunks {
            if case .standardOutput(let data) = chunk { output += data }
            if case .standardError(let data) = chunk { errors += data }
        }
        return CommandResult(request: request, termination: .exited(exitCode), standardOutput: output, standardError: errors, startedAt: Date(), finishedAt: Date())
    }

    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandStreamEvent, Error> {
        let chunks = chunks, exitCode = exitCode
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.yield(.finished(CommandResult(request: request, termination: .exited(exitCode), standardOutput: Data(), standardError: Data(), startedAt: Date(), finishedAt: Date())))
            continuation.finish()
        }
    }
}
