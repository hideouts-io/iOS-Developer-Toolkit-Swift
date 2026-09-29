import Foundation
import Testing
@testable import ToolkitFeatures
import ToolkitCore

/// Read-only checks against Apple's live services and the built helpers. Opt in with
/// IDT_NETWORK_TESTS=1 (and IDT_RESTORE_HELPERS=<folder with idevicerestore and irecovery>).
/// Nothing is downloaded beyond the catalog and a few hundred kilobytes of one IPSW, and no
/// device is changed.
@Suite("Real firmware services (opt-in)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["IDT_NETWORK_TESTS"] == "1"))
struct RealFirmwareTests {
    func report(_ text: String) { print("[firmware] \(text)") }

    @Test(.timeLimit(.minutes(5)))
    func appleCatalogManifestAndSigning() async throws {
        let catalog = try await URLSessionDataFetcher().data(from: FirmwareCatalog.url, limit: 64 << 20)
        let releases = try FirmwareCatalog.releases(fromCatalog: catalog, productType: "iPhone18,1")
        let latest = try #require(releases.first)
        report("catalog: \(catalog.count) bytes; iPhone18,1 → \(releases.map { "\($0.version) (\($0.build))" }.joined(separator: ", ")); sha1 \(latest.sha1 ?? "none")")
        #expect(latest.url.scheme == "https")

        let started = Date()
        let manifest = try FirmwareManifest.parse(try await RemoteArchive.file(named: FirmwareManifest.fileName, in: latest.url))
        report("remote BuildManifest in \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(manifest.productVersion) (\(manifest.productBuild)), \(manifest.identities.count) identities, models \(manifest.supportedProductTypes.joined(separator: ","))")
        #expect(manifest.productBuild == latest.build)
        #expect(manifest.supportedProductTypes.contains("iPhone18,1"))

        let identity = try #require(manifest.identity())
        let status = await FirmwareSigning.check(identity: identity)
        report("Apple signing status for \(manifest.productVersion) (\(manifest.productBuild)): \(status.label) — \(status.explanation)")
        #expect(status == .signed, "Apple lists this firmware as current, so it should be signed")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IDT_RESTORE_HELPERS"] != nil))
    func bundledHelpersRun() async throws {
        let runner = ProcessCommandRunner()
        let restore = try RestoreHelper.idevicerestore.locate()
        let version = try await runner.run(CommandRequest(executable: restore, arguments: ["--version"], timeout: 30, displayName: "idevicerestore --version"))
        report("idevicerestore --version: \(version.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(version.succeeded && version.standardOutputText.contains("idevicerestore"))
        let query = try await runner.run(RecoveryProbe.queryRequest(helper: try RestoreHelper.irecovery.locate()))
        let found = RecoveryProbe.parse(query.standardOutputText + query.standardErrorText)
        report("irecovery -q: exit \(query.exitCode.map(String.init) ?? "?"), device in recovery/DFU: \(found.map { $0.mode.label } ?? "none")")
        #expect(found == nil || query.succeeded)
    }
}
