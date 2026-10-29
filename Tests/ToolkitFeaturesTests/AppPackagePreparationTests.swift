import Darwin
import DeviceKit
import Foundation
import Testing
import ToolkitCore
@testable import ToolkitFeatures

@Suite("App package preparation")
struct AppPackagePreparationTests {
    @Test func unsignedSimulatorBundleHasAnImmutablePrivateCopyAndDistinctRouteValidation() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "prepared-simulator")
        defer { removeTestItem(root) }
        let app = try makeApp(root, name: "SimulatorDemo", platform: "iPhoneSimulator")
        let originalInfo = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        let prepared = try PreparedAppPackage.prepare(app)
        defer { removeTestPackage(prepared) }

        #expect(prepared.originalURL == app)
        #expect(prepared.packageURL != app)
        #expect(prepared.packageURL.lastPathComponent == app.lastPathComponent)
        #expect(prepared.inspection == nil)
        #expect(prepared.appName == "SimulatorDemo")
        #expect(prepared.supportedPlatforms == ["iPhoneSimulator"])
        #expect((try FileManager.default.attributesOfItem(atPath: prepared.directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        try prepared.revalidate()
        try prepared.validate(for: target(.simulator), supportsCoreDevice: false, simulatorBooted: true)
        #expect(throws: ToolkitError.self) { try prepared.validate(for: target(.simulator), supportsCoreDevice: true, simulatorBooted: false) }
        #expect(throws: ToolkitError.self) { try prepared.validate(for: target(.physical), supportsCoreDevice: true, simulatorBooted: true) }
        #expect(throws: ToolkitError.self) { try prepared.validate(for: target(.demo), supportsCoreDevice: true, simulatorBooted: true) }
        #expect(try Data(contentsOf: app.appendingPathComponent("Info.plist")) == originalInfo)
    }

    @Test func cancelledAsyncPreparationDoesNotReturnAnOwnedPackage() async throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "prepared-cancelled")
        defer { removeTestItem(root) }
        let app = try makeApp(root, name: "Demo", platform: "iPhoneSimulator")
        let observedCancellation = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.cancelAll()
            group.addTask {
                do {
                    let package = try await PreparedAppPackage.prepareAsync(app)
                    try package.remove()
                    return false
                } catch is CancellationError {
                    return true
                }
            }
            var cancelled = false
            for try await result in group { cancelled = result }
            return cancelled
        }
        #expect(observedCancellation)
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Demo").path))
    }

    private enum ChangedLocation: String, CaseIterable {
        case original, prepared
    }

    @Test(arguments: ChangedLocation.allCases)
    private func bundleReplacementAtEitherLocationRequiresNewInspection(_ location: ChangedLocation) throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "prepared-app-change")
        defer { removeTestItem(root) }
        let app = try makeApp(root, name: "Demo", platform: "iPhoneSimulator")
        let prepared = try PreparedAppPackage.prepare(app)
        defer { removeTestPackage(prepared) }
        let changed = location == .original ? app : prepared.packageURL
        try Data("different resource".utf8).write(to: changed.appendingPathComponent("resource.txt"))
        #expect(throws: ToolkitError.self) { try prepared.revalidate() }
        let unchanged = location == .original ? prepared.packageURL : app
        #expect(try Data(contentsOf: unchanged.appendingPathComponent("resource.txt")) == Data("resource".utf8))
    }

    @Test func bundleAddedFilesAndExecutablePermissionChangesAreDetected() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "prepared-app-mode")
        defer { removeTestItem(root) }
        let app = try makeApp(root, name: "Demo", platform: "iPhoneSimulator")
        let prepared = try PreparedAppPackage.prepare(app)
        defer { removeTestPackage(prepared) }
        try SecureFileIO.writeNewFile(Data("new".utf8), to: prepared.packageURL.appendingPathComponent("new.txt"))
        #expect(throws: ToolkitError.self) { try prepared.revalidate() }
        try FileManager.default.removeItem(at: prepared.packageURL.appendingPathComponent("new.txt"))
        try prepared.revalidate()
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: app.appendingPathComponent("Demo").path)
        #expect(throws: ToolkitError.self) { try prepared.revalidate() }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign")))
    func physicalAppRequiresCoreDeviceAndAnIntactSignature() async throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "prepared-physical")
        defer { removeTestItem(root) }
        let app = try makeApp(root, name: "DeviceDemo", platform: "iPhoneOS")
        let unsigned = try await PreparedAppPackage.prepareAsync(app)
        defer { removeTestPackage(unsigned) }
        #expect(throws: ToolkitError.self) { try unsigned.validate(for: target(.physical), supportsCoreDevice: true, simulatorBooted: true) }
        try await sign(app, in: root)
        let signed = try await PreparedAppPackage.prepareAsync(app)
        defer { removeTestPackage(signed) }
        #expect(signed.signature?.status == .valid)
        try signed.validate(for: target(.physical), supportsCoreDevice: true, simulatorBooted: false)
        #expect(throws: ToolkitError.self) { try signed.validate(for: target(.physical), supportsCoreDevice: false, simulatorBooted: false) }
        #expect(throws: ToolkitError.self) { try signed.validate(for: target(.simulator), supportsCoreDevice: true, simulatorBooted: true) }
        try Data("tampered".utf8).write(to: signed.packageURL.appendingPathComponent("resource.txt"))
        #expect(throws: ToolkitError.self) { try signed.revalidate() }
    }

    @Test func unsignedIPAStaysInspectableButCannotAuthorizeInstallation() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "prepared-unsigned-ipa")
        defer { removeTestItem(root) }
        let app = try makeApp(root, name: "Demo", platform: "iPhoneOS")
        let ipa = try makeIPA(app, in: root, name: "Unsigned.ipa")
        let prepared = try PreparedAppPackage.prepare(ipa)
        defer { removeTestPackage(prepared) }
        let inspection = try #require(prepared.inspection)
        #expect(!inspection.isInstallable)
        #expect(inspection.packagePath == prepared.packageURL.path)
        #expect(inspection.appName == "Demo")
        #expect(throws: ToolkitError.self) { try prepared.validate(for: target(.physical), supportsCoreDevice: false, simulatorBooted: false) }
        #expect(throws: ToolkitError.self) { try prepared.validate(for: target(.simulator), supportsCoreDevice: true, simulatorBooted: true) }
        try prepared.revalidate()
        try Data("replaced IPA".utf8).write(to: ipa)
        #expect(throws: ToolkitError.self) { try prepared.revalidate() }
        #expect(try Data(contentsOf: prepared.packageURL) != Data("replaced IPA".utf8))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign")))
    func signedIPAUsesTheApprovedCopyAndRetainsNativePhysicalInstallation() async throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "prepared-signed-ipa")
        defer { removeTestItem(root) }
        let app = try makeApp(root, name: "Demo", platform: "iPhoneOS")
        try await sign(app, in: root)
        let ipa = try makeIPA(app, in: root, name: "Signed.ipa")
        async let inspection = IPAInspector.inspectAsync(ipa)
        let prepared = try await PreparedAppPackage.prepareAsync(ipa)
        defer { removeTestPackage(prepared) }
        #expect(try await inspection.isInstallable)
        #expect(prepared.inspection?.isInstallable == true)
        try prepared.revalidate()
        try prepared.validate(for: target(.physical), supportsCoreDevice: false, simulatorBooted: false)
        try prepared.validate(for: target(.physical), supportsCoreDevice: true, simulatorBooted: false)
        #expect(throws: ToolkitError.self) { try prepared.validate(for: target(.simulator), supportsCoreDevice: true, simulatorBooted: true) }
        try Data("tampered copy".utf8).write(to: prepared.packageURL)
        #expect(throws: ToolkitError.self) { try prepared.revalidate() }
    }

    @Test func rejectsMalformedPackagesAndTypedBundleMetadata() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "prepared-malformed")
        defer { removeTestItem(root) }
        let malformedIPA = root.appendingPathComponent("Malformed.ipa")
        try SecureFileIO.writeNewFile(Data("not ZIP".utf8), to: malformedIPA)
        #expect(throws: ToolkitError.self) { try PreparedAppPackage.prepare(malformedIPA) }
        let unsupported = root.appendingPathComponent("Unsupported.zip")
        try SecureFileIO.writeNewFile(Data(), to: unsupported)
        #expect(throws: ToolkitError.self) { try PreparedAppPackage.prepare(unsupported) }
        let app = try makeApp(root, name: "Bad", platform: "iPhoneSimulator")
        var info = try #require(infoPlist(name: "Bad", platform: "iPhoneSimulator").dictionaryValue)
        info["CFBundleSupportedPlatforms"] = .array([.string("iPhoneSimulator"), .integer(1)])
        try PlistValue.dictionary(info).encoded(format: .xml).write(to: app.appendingPathComponent("Info.plist"))
        #expect(throws: ToolkitError.self) { try PreparedAppPackage.prepare(app) }
        let malformedPlatformIPA = try makeIPA(app, in: root, name: "MalformedPlatform.ipa")
        #expect(throws: ToolkitError.self) { try PreparedAppPackage.prepare(malformedPlatformIPA) }
        info["CFBundleSupportedPlatforms"] = .array([.string("iPhoneSimulator")])
        info["CFBundleExecutable"] = .string("../outside")
        try PlistValue.dictionary(info).encoded(format: .xml).write(to: app.appendingPathComponent("Info.plist"))
        #expect(throws: ToolkitError.self) { try PreparedAppPackage.prepare(app) }
        try Data(repeating: 0x41, count: Int(IPAInspector.maximumInfoPlistBytes) + 1).write(to: app.appendingPathComponent("Info.plist"))
        #expect(throws: ToolkitError.self) { try PreparedAppPackage.prepare(app) }
    }

    @Test func preservesSafeInternalFrameworkLinksWithoutFollowingThem() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "prepared-framework")
        defer { removeTestItem(root) }
        let app = try makeApp(root, name: "Demo", platform: "iPhoneSimulator")
        let framework = app.appendingPathComponent("Frameworks/Demo.framework")
        try SecureFileIO.createPrivateDirectory(at: framework.appendingPathComponent("Versions/A"))
        try SecureFileIO.writeNewFile(Data("framework resource".utf8), to: framework.appendingPathComponent("Versions/A/value.txt"))
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("value.txt").path, withDestinationPath: "Versions/Current/value.txt")
        let prepared = try PreparedAppPackage.prepare(app)
        defer { removeTestPackage(prepared) }
        let copied = prepared.packageURL.appendingPathComponent("Frameworks/Demo.framework")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("Versions/Current").path) == "A")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("value.txt").path) == "Versions/Current/value.txt")
        #expect(try Data(contentsOf: copied.appendingPathComponent("value.txt")) == Data("framework resource".utf8))
        try prepared.revalidate()
        try prepared.validate(for: target(.simulator), supportsCoreDevice: false, simulatorBooted: true)
    }

    @Test(arguments: ["../secret.txt", "/etc/passwd", "missing.txt", "link"])
    func deniesEscapingAbsoluteBrokenAndCyclicBundleLinks(_ destination: String) throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "prepared-unsafe-link")
        defer { removeTestItem(root) }
        let app = try makeApp(root, name: "Demo", platform: "iPhoneSimulator")
        let secret = root.appendingPathComponent("secret.txt")
        try SecureFileIO.writeNewFile(Data("task-owned confidential test bytes".utf8), to: secret)
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("link").path, withDestinationPath: destination)
        #expect(throws: ToolkitError.self) { try PreparedAppPackage.prepare(app) }
        #expect(try Data(contentsOf: secret) == Data("task-owned confidential test bytes".utf8))
    }

    @Test func rootSymbolicLinksAreDeniedAndCleanupDoesNotDeleteSource() throws {
        let root = try SecureFileIO.makeTemporaryDirectory(prefix: "prepared-root-link")
        defer { removeTestItem(root) }
        let app = try makeApp(root, name: "Demo", platform: "iPhoneSimulator")
        let linked = root.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: app)
        #expect(throws: ToolkitError.self) { try PreparedAppPackage.prepare(linked) }
        let prepared = try PreparedAppPackage.prepare(app)
        try prepared.remove()
        #expect(!FileManager.default.fileExists(atPath: prepared.directory.path))
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Demo").path))
    }

    private func removeTestItem(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Could not remove the task-owned package fixture: \(error.localizedDescription)") }
    }

    private func removeTestPackage(_ package: PreparedAppPackage) {
        do { try package.remove() }
        catch { Issue.record("Could not remove the prepared package fixture: \(error.localizedDescription)") }
    }

    private func infoPlist(name: String, platform: String) -> PlistValue {
        .dictionary([
            "CFBundleIdentifier": .string("com.example.preparation"),
            "CFBundleName": .string(name),
            "CFBundleShortVersionString": .string("1.0"),
            "CFBundleVersion": .string("1"),
            "CFBundleExecutable": .string(name),
            "CFBundleSupportedPlatforms": .array([.string(platform)]),
        ])
    }

    private func makeApp(_ root: URL, name: String, platform: String) throws -> URL {
        let app = root.appendingPathComponent("\(name).app")
        try SecureFileIO.createPrivateDirectory(at: app)
        try SecureFileIO.writeNewFile(try infoPlist(name: name, platform: platform).encoded(format: .xml), to: app.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(atPath: "/bin/echo", toPath: app.appendingPathComponent(name).path)
        try SecureFileIO.writeNewFile(Data("resource".utf8), to: app.appendingPathComponent("resource.txt"))
        return app
    }

    private func makeIPA(_ app: URL, in root: URL, name: String) throws -> URL {
        var writer = ZipWriter(date: Date(timeIntervalSince1970: 0))
        let appRoot = app.resolvingSymlinksInPath()
        let enumerator = try #require(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [], errorHandler: nil))
        for case let enumeratedURL as URL in enumerator {
            let file = enumeratedURL.resolvingSymlinksInPath()
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            guard file.path.hasPrefix(appRoot.path + "/") else { throw ToolkitError.invalidInput("The task-owned IPA fixture path escaped the app root.") }
            let path = "Payload/\(app.lastPathComponent)/" + file.path.dropFirst(appRoot.path.count + 1)
            let permissions = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
            try writer.add(name: path, data: Data(contentsOf: file), method: .stored, mode: permissions.uint32Value)
        }
        let url = root.appendingPathComponent(name)
        try SecureFileIO.writeNewFile(writer.finalized(), to: url)
        return url
    }

    private func sign(_ app: URL, in root: URL) async throws {
        let result = try await ProcessCommandRunner().run(CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", app.path], workingDirectory: root, timeout: 60))
        #expect(result.succeeded, "\(result.standardErrorText)")
        guard result.succeeded else { throw ToolkitError(.commandFailed, message: "Could not sign the task-owned test bundle.", recovery: nil, technicalDetail: result.technicalSummary) }
    }

    private func target(_ kind: DeviceKind) -> DeviceTarget {
        DeviceTarget(kind: kind, udid: "TASK-OWNED-TEST", name: "Synthetic Test Target", osVersion: "27.0", usbmuxDeviceID: nil, coreDeviceIdentifier: nil, transport: kind == .physical ? .usb : .local)
    }
}
