import Foundation
import ToolkitCore

/// Provisions only this hosted run's simulator and immutable package inputs. Native UI tests
/// choose those files themselves; this host verifies their hashes, inventory and post-Quit cleanup.
@main
struct PackageInspectionFixtures {
    struct SourceDigest: Codable {
        let path: String
        let sha256: String
    }

    struct Manifest: Codable {
        let owner: String
        let simulator: String?
        let sources: [SourceDigest]?
        let inventory: [String]?
        let existingPreparations: [String]

        enum CodingKeys: String, CodingKey { case owner, simulator, sources, inventory, existingPreparations }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(owner, forKey: .owner)
            try values.encode(simulator, forKey: .simulator)
            try values.encode(sources, forKey: .sources)
            try values.encode(inventory, forKey: .inventory)
            try values.encode(existingPreparations, forKey: .existingPreparations)
        }
    }

    struct Simulator {
        let identifier: String
        let name: String
        let state: String
        let type: String
        let runtime: String
        let available: Bool
    }

    struct CleanupReceipt: Decodable {
        let preparedDirectories: [String]
    }

    static let validName = "ValidSimulator.app"
    static let invalidName = "Malformed.ipa"
    static let fixtureBundle = "io.hideouts.idt.package.fixture"

    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, arguments.count <= 4 else {
            throw failure("Use package-fixtures prepare DIRECTORY, verify-cleanup DIRECTORY RECEIPT_JSON, or cleanup DIRECTORY.", cause: nil)
        }
        let directory = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        guard let temporary = ProcessInfo.processInfo.environment["RUNNER_TEMP"],
              directory.resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: temporary).resolvingSymlinksInPath().path + "/") else {
            throw failure("The fixture directory must be a dedicated child of RUNNER_TEMP.", cause: nil)
        }
        let runner = ProcessCommandRunner()
        switch arguments[1] {
        case "prepare" where arguments.count == 3:
            try await prepare(directory: directory, runner: runner)
        case "verify-cleanup" where arguments.count == 4:
            try await verifyCleanup(directory: directory, receipt: URL(fileURLWithPath: arguments[3]), runner: runner)
        case "cleanup" where arguments.count == 3:
            try await cleanup(directory: directory, runner: runner)
        default:
            throw failure("The fixture command or its argument count is invalid.", cause: nil)
        }
    }

    static func prepare(directory: URL, runner: ProcessCommandRunner) async throws {
        try SecureFileIO.createNewPrivateDirectory(at: directory)
        let owner = UUID().uuidString
        let existingPreparations = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
            .filter { $0.hasPrefix("idt-prepared-app.") }.sorted()
        var manifest = Manifest(owner: owner, simulator: nil, sources: nil, inventory: nil, existingPreparations: existingPreparations)
        try save(manifest, directory: directory)
        let template = try await simulatorTemplate(runner: runner)
        let result = try await command(["simctl", "create", "IDT Package \(owner)", template.type, template.runtime], timeout: 120, runner: runner)
        guard let identifier = UUID(uuidString: result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString else {
            throw failure("simctl create did not return a valid fixture UUID; cleanup must reconcile its exact owner name before retrying.", cause: nil)
        }
        manifest = Manifest(owner: owner, simulator: identifier, sources: nil, inventory: nil, existingPreparations: existingPreparations)
        try await register(manifest, directory: directory, runner: runner)
        _ = try await command(["simctl", "bootstatus", identifier, "-b"], timeout: 600, runner: runner)
        try await requireOwnedSimulator(manifest, runner: runner)
        let app = try await fixture(directory: directory, runner: runner)
        let malformed = directory.appendingPathComponent(invalidName)
        try SecureFileIO.writeNewFile(Data("This is deliberately not a ZIP archive.\n".utf8), to: malformed, mode: 0o600)
        let sources = try [validName, invalidName].map { name in
            SourceDigest(path: name, sha256: try digest(directory.appendingPathComponent(name)))
        }
        let inventory = try await inventory(identifier: identifier, runner: runner)
        guard !inventory.contains(fixtureBundle) else {
            throw failure("The new simulator already contains the acceptance package; installation cancellation cannot be measured.", cause: nil)
        }
        manifest = Manifest(owner: owner, simulator: identifier, sources: sources, inventory: inventory, existingPreparations: existingPreparations)
        try save(manifest, directory: directory)
        let environment = [
            "IDT_PACKAGE_FIXTURE_DIRECTORY": directory.path,
            "IDT_PACKAGE_FIXTURE_SIMULATOR": identifier,
            "IDT_PACKAGE_FIXTURE_OWNER": owner,
            "IDT_PACKAGE_FIXTURE_VALID": app.path,
            "IDT_PACKAGE_FIXTURE_INVALID": malformed.path,
        ]
        guard environment.values.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else {
            throw failure("Fixture paths cannot contain newline characters in the hosted environment file.", cause: nil)
        }
        let lines = environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)\n" }.joined()
        try SecureFileIO.writeNewFile(Data(lines.utf8), to: directory.appendingPathComponent("environment.env"), mode: 0o600)
        print("[package fixtures] One owner-matched booted simulator, a genuine signed simulator app, malformed IPA and source/inventory baselines are ready.")
    }

    static func verifyCleanup(directory: URL, receipt: URL, runner: ProcessCommandRunner) async throws {
        let manifest = try load(directory: directory)
        guard let sources = manifest.sources, sources.count == 2,
              Set(sources.map(\.path)) == Set([validName, invalidName]),
              let expectedInventory = manifest.inventory, let identifier = manifest.simulator else {
            throw failure("Package acceptance verification requires a completely prepared ownership registry.", cause: nil)
        }
        try await requireOwnedSimulator(manifest, runner: runner)
        for source in sources {
            guard source.sha256 == (try digest(directory.appendingPathComponent(source.path))) else {
                throw failure("An original acceptance package changed during inspection, cancellation or normal Quit.", cause: nil)
            }
        }
        guard try await inventory(identifier: identifier, runner: runner) == expectedInventory else {
            throw failure("The owned simulator's bundle-identifier inventory changed despite cancelling installation.", cause: nil)
        }
        let receiptData = try readOwnedFile(receipt, maximumBytes: 16384)
        guard let object = try JSONValue.parse(receiptData).object, Set(object.keys) == Set(["preparedDirectories"]) else {
            throw failure("The native cleanup receipt has an invalid schema.", cause: nil)
        }
        let recorded = try JSONDecoder().decode(CleanupReceipt.self, from: receiptData).preparedDirectories
        guard recorded.count == 2, Set(recorded).count == 2 else {
            throw failure("The native receipt must contain distinct actual preparation paths from the first valid choice and recovered valid choice.", cause: nil)
        }
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath()
        for path in recorded {
            let prepared = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let name = prepared.lastPathComponent
            let suffix = String(name.dropFirst("idt-prepared-app.".count))
            guard path.hasPrefix("/"), prepared.deletingLastPathComponent().resolvingSymlinksInPath() == temporary,
                  name.hasPrefix("idt-prepared-app."), suffix.count == 8,
                  suffix.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
                  !manifest.existingPreparations.contains(name) else {
                throw failure("The native receipt contains a path outside this run's possible new private preparations.", cause: nil)
            }
            var metadata = stat()
            guard lstat(prepared.path, &metadata) != 0 else {
                throw failure("A recorded private preparation remains after malformed re-selection or normal Quit.", cause: nil)
            }
            guard errno == ENOENT else {
                throw failure("A recorded private preparation could not be checked for absence.", cause: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
        }
        print("[package fixtures] Independent verification passed: both recorded private preparations are absent, source hashes are unchanged and the owned simulator inventory is unchanged.")
    }

    static func cleanup(directory: URL, runner: ProcessCommandRunner) async throws {
        let manifest = try load(directory: directory)
        let name = "IDT Package \(manifest.owner)"
        let records = try await simulators(runner: runner)
        let named = records.filter { $0.name == name }
        guard named.count <= 1 else { throw failure("Multiple simulators have the exact fixture owner name; cleanup was refused.", cause: nil) }
        let record: Simulator?
        if let identifier = manifest.simulator {
            record = records.first(where: { $0.identifier == identifier })
            guard record == nil ? named.isEmpty : record?.name == name else {
                throw failure("The registered simulator UUID and its exact owner name no longer identify the same target; cleanup was refused.", cause: nil)
            }
        } else {
            // A create response or registry write can fail after allocation. Reconcile one exact
            // owner name; creation is never blindly retried and other simulators are untouched.
            record = named.first
        }
        if let record {
            if record.state == "Booted" {
                _ = try await command(["simctl", "shutdown", record.identifier], timeout: 120, runner: runner)
            }
            _ = try await command(["simctl", "delete", record.identifier], timeout: 120, runner: runner)
        }
        guard try await !simulators(runner: runner).contains(where: { $0.identifier == manifest.simulator || $0.name == name }) else {
            throw failure("Fresh discovery still contains the fixture UUID or exact owner name; the registry was retained.", cause: nil)
        }
        try FileManager.default.removeItem(at: directory)
        print("[package fixtures] Fresh discovery verified the owned simulator UUID and exact owner name absent; the owned fixture directory was removed.")
    }

    static func fixture(directory: URL, runner: ProcessCommandRunner) async throws -> URL {
        let app = directory.appendingPathComponent(validName, isDirectory: true)
        try SecureFileIO.createNewPrivateDirectory(at: app)
        let source = directory.appendingPathComponent("Fixture.c")
        try SecureFileIO.writeNewFile(Data("int main(void) { return 0; }\n".utf8), to: source, mode: 0o600)
        #if arch(arm64)
        let triple = "arm64-apple-ios17.0-simulator"
        #else
        let triple = "x86_64-apple-ios17.0-simulator"
        #endif
        _ = try await command(["--sdk", "iphonesimulator", "clang", "-target", triple, "-o", app.appendingPathComponent("Fixture").path, source.path], timeout: 300, runner: runner)
        let info: PlistValue = ["CFBundleIdentifier": .string(fixtureBundle), "CFBundleExecutable": "Fixture", "CFBundleName": "Package Fixture",
                                "CFBundleDisplayName": "Package Fixture", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
                                "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "17.0", "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "UIDeviceFamily": [1, 2]]
        try SecureFileIO.writeNewFile(info.encoded(format: .xml), to: app.appendingPathComponent("Info.plist"), mode: 0o600)
        let request = CommandRequest(executable: try AppleTool.codesign.locate(), arguments: ["--sign", "-", app.path], timeout: 60, displayName: "sign package fixture")
        let signed = try await runner.run(request)
        guard signed.succeeded else { throw failure("Signing the genuine simulator package failed.", cause: nil).appendingDetail(String(signed.technicalSummary.prefix(1536))) }
        return app
    }

    /// Includes each relative entry name, kind, mode and file digest; original package metadata
    /// and nested bytes must survive inspection and cancellation, rather than only its root file.
    static func digest(_ source: URL) throws -> String {
        var paths = [source]
        var metadata = stat()
        var lines: [String] = []
        var index = 0
        while index < paths.count {
            let path = paths[index]
            index += 1
            guard lstat(path.path, &metadata) == 0, metadata.st_uid == getuid() else {
                throw failure("An original package entry cannot be verified for hashing.", cause: nil)
            }
            let kind = metadata.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else { throw failure("Generated package inputs must contain only owned regular files and directories.", cause: nil) }
            if kind == S_IFDIR {
                paths.append(contentsOf: try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }))
                guard paths.count <= 4096 else { throw failure("The generated package exceeds the acceptance fixture entry bound.", cause: nil) }
            }
            let relative = String(path.path.dropFirst(source.path.count))
            let content = kind == S_IFREG ? try SecureFileIO.sha256(of: path) : "directory"
            lines.append("\(relative)\u{0}\(kind)\u{0}\(metadata.st_mode & 0o777)\u{0}\(content)\n")
        }
        return SecureFileIO.sha256(of: Data(lines.sorted().joined().utf8))
    }

    static func inventory(identifier: String, runner: ProcessCommandRunner) async throws -> [String] {
        let result = try await command(["simctl", "listapps", identifier], timeout: 60, runner: runner)
        guard let applications = try PlistValue.decode(result.standardOutput).dictionaryValue,
              applications.count <= 4096, applications.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else {
            throw failure("The owned simulator returned an invalid application inventory.", cause: nil)
        }
        return applications.keys.sorted()
    }

    static func simulatorTemplate(runner: ProcessCommandRunner) async throws -> Simulator {
        let runtimeJSON = try JSONValue.parse(try await command(["simctl", "list", "runtimes", "--json"], timeout: 60, runner: runner).standardOutput)
        let typeJSON = try JSONValue.parse(try await command(["simctl", "list", "devicetypes", "--json"], timeout: 60, runner: runner).standardOutput)
        guard let runtimes = runtimeJSON["runtimes"]?.array, let types = typeJSON["devicetypes"]?.array else {
            throw failure("simctl did not return runtime and device-type arrays.", cause: nil)
        }
        let availableRuntimes = try runtimes.filter { try boolean($0, field: "isAvailable") }.map { try string($0, field: "identifier") }
        let iphoneTypes = try types.filter { try string($0, field: "name").hasPrefix("iPhone") }.map { try string($0, field: "identifier") }
        guard let template = try await simulators(runner: runner).first(where: {
            $0.available && availableRuntimes.contains($0.runtime) && iphoneTypes.contains($0.type)
                && $0.runtime.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-")
                && $0.type.hasPrefix("com.apple.CoreSimulator.SimDeviceType.iPhone-")
        }) else {
            throw failure("The hosted runner needs an available iPhone simulator runtime and device type.", cause: nil)
        }
        return template
    }

    static func simulators(runner: ProcessCommandRunner) async throws -> [Simulator] {
        let json = try JSONValue.parse(try await command(["simctl", "list", "devices", "--json"], timeout: 60, runner: runner).standardOutput)
        guard let groups = json["devices"]?.object else { throw failure("simctl returned no device groups.", cause: nil) }
        return try groups.keys.sorted().flatMap { runtime -> [Simulator] in
            guard let devices = groups[runtime]?.array else { throw failure("simctl returned a non-array device group.", cause: nil) }
            return try devices.map { value in
                guard let identifier = UUID(uuidString: try string(value, field: "udid"))?.uuidString else { throw failure("simctl returned an invalid UUID.", cause: nil) }
                return Simulator(identifier: identifier, name: try string(value, field: "name"), state: try string(value, field: "state"),
                                 type: try string(value, field: "deviceTypeIdentifier"), runtime: runtime, available: try boolean(value, field: "isAvailable"))
            }
        }
    }

    static func requireOwnedSimulator(_ manifest: Manifest, runner: ProcessCommandRunner) async throws {
        guard let identifier = manifest.simulator,
              try await simulators(runner: runner).contains(where: {
                  $0.identifier == identifier && $0.name == "IDT Package \(manifest.owner)" && $0.available && $0.state == "Booted"
              }) else { throw failure("Acceptance requires this run's booted simulator with both registered UUID and exact owner name.", cause: nil) }
    }

    static func save(_ manifest: Manifest, directory: URL) throws {
        try SecureFileIO.writeAtomically(JSONEncoder().encode(manifest), to: directory.appendingPathComponent("manifest.json"), mode: 0o600)
    }

    static func register(_ manifest: Manifest, directory: URL, runner: ProcessCommandRunner) async throws {
        do { try save(manifest, directory: directory) }
        catch {
            let registrationError = error
            do {
                guard let identifier = manifest.simulator else { throw failure("No newly allocated simulator was recorded for registration cleanup.", cause: nil) }
                if let record = try await simulators(runner: runner).first(where: { $0.identifier == identifier }) {
                    guard record.name == "IDT Package \(manifest.owner)" else { throw failure("The newly allocated simulator changed owner name; immediate cleanup was refused.", cause: nil) }
                    _ = try await command(["simctl", "delete", identifier], timeout: 120, runner: runner)
                }
                guard try await !simulators(runner: runner).contains(where: { $0.identifier == identifier || $0.name == "IDT Package \(manifest.owner)" }) else {
                    throw failure("The unregistered simulator remains after deletion.", cause: nil)
                }
            } catch {
                throw failure("Fixture registration and immediate owned cleanup both failed; the earlier registry was retained.", cause: registrationError).appendingDetail(bounded(error))
            }
            throw failure("Fixture registration failed; its newly allocated simulator was removed and the earlier registry retained.", cause: registrationError)
        }
    }

    static func load(directory: URL) throws -> Manifest {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700 else {
            throw failure("Cleanup requires the original owner-only fixture directory without symbolic links.", cause: nil)
        }
        let data = try readOwnedFile(directory.appendingPathComponent("manifest.json"), maximumBytes: 65536)
        guard let object = try JSONValue.parse(data).object,
              Set(object.keys) == Set(["owner", "simulator", "sources", "inventory", "existingPreparations"]) else {
            throw failure("The ownership registry has an invalid schema.", cause: nil)
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let validSimulator = manifest.simulator.map { UUID(uuidString: $0)?.uuidString == $0 } ?? true
        guard UUID(uuidString: manifest.owner)?.uuidString == manifest.owner, validSimulator,
              manifest.existingPreparations.count <= 4096,
              manifest.existingPreparations.allSatisfy({ $0.hasPrefix("idt-prepared-app.") && !$0.contains("/") }) else {
            throw failure("The ownership registry contains invalid target or preparation records.", cause: nil)
        }
        return manifest
    }

    static func readOwnedFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("An acceptance registry or receipt is missing or unreadable.", cause: nil) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        do {
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == getuid(), metadata.st_size > 0, metadata.st_size <= maximumBytes else {
                throw failure("Acceptance registries and receipts must be bounded owner-owned regular files.", cause: nil)
            }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            try handle.close()
            guard data.count <= maximumBytes else { throw failure("An acceptance registry or receipt grew beyond its size bound.", cause: nil) }
            return data
        } catch {
            do { try handle.close() }
            catch let closeError { throw failure("Reading and closing an acceptance record failed.", cause: error).appendingDetail(bounded(closeError)) }
            throw error
        }
    }

    static func command(_ arguments: [String], timeout: TimeInterval, runner: ProcessCommandRunner) async throws -> CommandResult {
        let request = CommandRequest(executable: try AppleTool.xcrun.locate(), arguments: arguments, timeout: timeout, displayName: "package fixture tool")
        let result = try await runner.run(request)
        guard result.succeeded else { throw failure("A package fixture tool failed.", cause: nil).appendingDetail(String(result.technicalSummary.prefix(1536))) }
        return result
    }

    static func string(_ value: JSONValue, field: String) throws -> String {
        guard case .string(let text) = value[field], !text.isEmpty, text.utf8.count <= 512 else { throw failure("simctl returned an invalid \(field) string.", cause: nil) }
        return text
    }

    static func boolean(_ value: JSONValue, field: String) throws -> Bool {
        guard case .bool(let result) = value[field] else { throw failure("simctl returned an invalid \(field) boolean.", cause: nil) }
        return result
    }

    static func bounded(_ error: Error) -> String { String(String(describing: error).prefix(1536)) }

    static func failure(_ message: String, cause: Error?) -> ToolkitError {
        ToolkitError(.commandFailed, message: message, recovery: "Inspect the hosted fixture step and retained ownership registry before retrying.", technicalDetail: cause.map(bounded))
    }
}
