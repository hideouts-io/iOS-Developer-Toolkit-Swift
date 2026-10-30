import Foundation
import ToolkitCore

/// Hosted fixture ownership stays outside the sandboxed UI-test runner. Every created
/// simulator is registered before further work, and cleanup verifies its UUID and exact name.
@main
struct SimulatorInventoryFixtures {
    struct Manifest: Codable {
        let first: String?
        let second: String?
        let owner: String

        enum CodingKeys: String, CodingKey { case first, second, owner }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(first, forKey: .first)
            try values.encode(second, forKey: .second)
            try values.encode(owner, forKey: .owner)
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

    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            throw failure("Use inventory-fixtures prepare DIRECTORY or cleanup DIRECTORY.", cause: nil)
        }
        let directory = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        guard let temporary = ProcessInfo.processInfo.environment["RUNNER_TEMP"],
              directory.resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: temporary).resolvingSymlinksInPath().path + "/") else {
            throw failure("The fixture directory must be a dedicated child of RUNNER_TEMP.", cause: nil)
        }
        let runner = ProcessCommandRunner()
        switch arguments[1] {
        case "prepare": try await prepare(directory: directory, runner: runner)
        case "cleanup": try await cleanup(directory: directory, runner: runner)
        default: throw failure("The fixture command must be prepare or cleanup.", cause: nil)
        }
    }

    static func prepare(directory: URL, runner: ProcessCommandRunner) async throws {
        try SecureFileIO.createNewPrivateDirectory(at: directory)
        let owner = UUID().uuidString
        var manifest = Manifest(first: nil, second: nil, owner: owner)
        try save(manifest, directory: directory)
        let runtimeJSON = try JSONValue.parse(try await command(["simctl", "list", "runtimes", "--json"], timeout: 60, runner: runner).standardOutput)
        let typeJSON = try JSONValue.parse(try await command(["simctl", "list", "devicetypes", "--json"], timeout: 60, runner: runner).standardOutput)
        guard let runtimes = runtimeJSON["runtimes"]?.array, let types = typeJSON["devicetypes"]?.array else {
            throw failure("simctl did not return runtime and device-type arrays.", cause: nil)
        }
        let availableRuntimes = try runtimes.filter { try boolean($0, field: "isAvailable") }.map { try string($0, field: "identifier") }
        let iphoneTypes = try types.filter { try string($0, field: "name").hasPrefix("iPhone") }.map { try string($0, field: "identifier") }
        let records = try await simulators(runner: runner)
        guard let template = records.first(where: {
            $0.available && availableRuntimes.contains($0.runtime) && iphoneTypes.contains($0.type)
                && $0.runtime.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-")
                && $0.type.hasPrefix("com.apple.CoreSimulator.SimDeviceType.iPhone-")
        }) else {
            throw failure("The hosted runner needs an available iPhone simulator runtime and device type.", cause: nil)
        }
        let first = try await create(name: "IDT Inventory A \(owner)", template: template, runner: runner)
        manifest = Manifest(first: first, second: nil, owner: owner)
        try await register(manifest, identifier: first, name: "IDT Inventory A \(owner)", directory: directory, runner: runner)
        let second = try await create(name: "IDT Inventory B \(owner)", template: template, runner: runner)
        manifest = Manifest(first: first, second: second, owner: owner)
        try await register(manifest, identifier: second, name: "IDT Inventory B \(owner)", directory: directory, runner: runner)
        for identifier in [first, second] {
            _ = try await command(["simctl", "bootstatus", identifier, "-b"], timeout: 600, runner: runner)
        }
        let firstApp = try await fixture(bundle: "io.hideouts.idt.inventory.a", name: "000 Inventory A", directory: directory, runner: runner)
        let secondApp = try await fixture(bundle: "io.hideouts.idt.inventory.b", name: "000 Inventory B", directory: directory, runner: runner)
        let sharedApp = try await fixture(bundle: "io.hideouts.idt.inventory.shared", name: "001 Inventory Shared", directory: directory, runner: runner)
        for (identifier, app) in [(first, firstApp), (first, sharedApp), (second, secondApp), (second, sharedApp)] {
            _ = try await command(["simctl", "install", identifier, app.path], timeout: 600, runner: runner)
        }
        print("[inventory fixtures] Two owned simulators and their isolated app inventories are ready.")
    }

    static func cleanup(directory: URL, runner: ProcessCommandRunner) async throws {
        let manifest = try load(directory: directory)
        let owned = [(manifest.first, "IDT Inventory A \(manifest.owner)"), (manifest.second, "IDT Inventory B \(manifest.owner)")]
        let ownedNames = Set(owned.map { $0.1 })
        var identifiers = Set([manifest.first, manifest.second].compactMap { $0 })
        var failures: [String] = []
        for (identifier, expectedName) in owned {
            let record: Simulator
            do {
                let records = try await simulators(runner: runner)
                let named = records.filter { $0.name == expectedName }
                guard named.count <= 1 else {
                    failures.append("Refused ambiguous cleanup because multiple simulators have the exact owned role name.")
                    continue
                }
                if let identifier {
                    guard let found = records.first(where: { $0.identifier == identifier }) else {
                        if !named.isEmpty { failures.append("The registered fixture UUID is absent but its owned name belongs to another UUID; cleanup was refused.") }
                        continue
                    }
                    guard found.name == expectedName else {
                        failures.append("Refused cleanup because a registered simulator no longer has its exact owned name.")
                        continue
                    }
                    record = found
                } else {
                    // Creation may have succeeded before its response or registry write failed.
                    // Reconcile only one exact role-and-owner name; never retry creation.
                    guard let found = named.first else { continue }
                    record = found
                }
                identifiers.insert(record.identifier)
            } catch {
                failures.append("Could not verify a registered simulator before cleanup: \(bounded(error))")
                continue
            }
            if record.state == "Booted" {
                do { _ = try await command(["simctl", "shutdown", record.identifier], timeout: 120, runner: runner) }
                catch { failures.append("Owned simulator shutdown failed: \(bounded(error))") }
            }
            do { _ = try await command(["simctl", "delete", record.identifier], timeout: 120, runner: runner) }
            catch { failures.append("Owned simulator deletion failed: \(bounded(error))") }
        }
        do {
            let remaining = try await simulators(runner: runner)
            if remaining.contains(where: { identifiers.contains($0.identifier) || ownedNames.contains($0.name) }) {
                failures.append("A fresh simulator listing still contains a known fixture UUID or exact owned role name.")
            }
        } catch { failures.append("Independent cleanup verification failed: \(bounded(error))") }
        guard failures.isEmpty else {
            throw failure("Fixture cleanup failed; the ownership registry and directory were retained.", cause: nil).appendingDetail(failures.joined(separator: "\n"))
        }
        do { try FileManager.default.removeItem(at: directory) }
        catch { throw failure("Simulators were removed, but the owned fixture directory could not be removed.", cause: error) }
        print("[inventory fixtures] Fresh discovery verified all known fixture UUIDs and both exact owned role names absent; the owned fixture directory was removed.")
    }

    static func create(name: String, template: Simulator, runner: ProcessCommandRunner) async throws -> String {
        let result = try await command(["simctl", "create", name, template.type, template.runtime], timeout: 120, runner: runner)
        guard let identifier = UUID(uuidString: result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw failure("simctl create did not return a valid fixture UUID; inspect its owned name before retrying.", cause: nil)
        }
        return identifier.uuidString
    }

    static func simulators(runner: ProcessCommandRunner) async throws -> [Simulator] {
        let json = try JSONValue.parse(try await command(["simctl", "list", "devices", "--json"], timeout: 60, runner: runner).standardOutput)
        guard let groups = json["devices"]?.object else { throw failure("simctl returned no device groups.", cause: nil) }
        return try groups.keys.sorted().flatMap { runtime -> [Simulator] in
            guard let devices = groups[runtime]?.array else { throw failure("simctl returned a non-array device group.", cause: nil) }
            return try devices.map { value in
                guard let identifier = UUID(uuidString: try string(value, field: "udid")) else {
                    throw failure("simctl returned an invalid simulator UUID.", cause: nil)
                }
                return Simulator(identifier: identifier.uuidString, name: try string(value, field: "name"), state: try string(value, field: "state"),
                                 type: try string(value, field: "deviceTypeIdentifier"), runtime: runtime, available: try boolean(value, field: "isAvailable"))
            }
        }
    }

    static func fixture(bundle: String, name: String, directory: URL, runner: ProcessCommandRunner) async throws -> URL {
        let app = directory.appendingPathComponent("\(bundle).app", isDirectory: true)
        try SecureFileIO.createNewPrivateDirectory(at: app)
        let source = directory.appendingPathComponent("\(bundle).swift")
        try SecureFileIO.writeNewFile(Data("import Foundation\nwhile true { sleep(1) }\n".utf8), to: source, mode: 0o600)
        #if arch(arm64)
        let triple = "arm64-apple-ios17.0-simulator"
        #else
        let triple = "x86_64-apple-ios17.0-simulator"
        #endif
        _ = try await command(["--sdk", "iphonesimulator", "swiftc", "-target", triple, "-o", app.appendingPathComponent("Fixture").path, source.path], timeout: 300, runner: runner)
        let info: PlistValue = ["CFBundleIdentifier": .string(bundle), "CFBundleExecutable": "Fixture", "CFBundleName": .string(name),
                                "CFBundleDisplayName": .string(name), "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
                                "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "17.0", "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "UIDeviceFamily": [1, 2]]
        try SecureFileIO.writeNewFile(info.encoded(format: .xml), to: app.appendingPathComponent("Info.plist"), mode: 0o600)
        let request = CommandRequest(executable: try AppleTool.codesign.locate(), arguments: ["--sign", "-", app.path], timeout: 60, displayName: "sign inventory fixture")
        let result = try await runner.run(request)
        guard result.succeeded else { throw failure("Signing the inventory fixture failed.", cause: nil).appendingDetail(String(result.technicalSummary.prefix(1536))) }
        return app
    }

    static func save(_ manifest: Manifest, directory: URL) throws {
        try SecureFileIO.writeAtomically(JSONEncoder().encode(manifest), to: directory.appendingPathComponent("manifest.json"), mode: 0o600)
    }

    /// If persistence fails after allocation, remove that exact new simulator immediately;
    /// the earlier registry continues to own any successfully registered resources.
    static func register(_ manifest: Manifest, identifier: String, name: String, directory: URL, runner: ProcessCommandRunner) async throws {
        do { try save(manifest, directory: directory) }
        catch {
            let registrationError = error
            do {
                if let record = try await simulators(runner: runner).first(where: { $0.identifier == identifier }) {
                    guard record.name == name else { throw failure("The newly allocated simulator's name changed; removal was refused.", cause: nil) }
                    _ = try await command(["simctl", "delete", identifier], timeout: 120, runner: runner)
                }
                guard try await !simulators(runner: runner).contains(where: { $0.identifier == identifier }) else {
                    throw failure("The unregistered simulator remains after deletion.", cause: nil)
                }
            } catch {
                throw failure("Fixture registration and immediate cleanup both failed; retain the earlier registry and inspect \(name) (\(identifier)).", cause: registrationError)
                    .appendingDetail(bounded(error))
            }
            throw failure("Fixture registration failed; its newly allocated simulator was removed and the earlier registry retained.", cause: registrationError)
        }
    }

    static func load(directory: URL) throws -> Manifest {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700 else {
            throw failure("Cleanup requires the original owner-only fixture directory, without symbolic links.", cause: nil)
        }
        let path = directory.appendingPathComponent("manifest.json").path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("The fixture ownership registry is missing or unreadable; no simulator was changed.", cause: nil) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data: Data
        do {
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o600, metadata.st_size > 0, metadata.st_size <= 4096 else {
                throw failure("The fixture ownership registry must be a bounded owner-only regular file.", cause: nil)
            }
            data = try handle.read(upToCount: 4097) ?? Data()
            try handle.close()
        } catch {
            do { try handle.close() }
            catch let closeError { throw failure("Reading and closing the fixture registry failed.", cause: error).appendingDetail(bounded(closeError)) }
            throw failure("The fixture ownership registry could not be validated; no simulator was changed.", cause: error)
        }
        guard data.count <= 4096, let object = try JSONValue.parse(data).object,
              Set(object.keys) == Set(["first", "second", "owner"]) else {
            throw failure("The fixture ownership registry has an invalid schema.", cause: nil)
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard UUID(uuidString: manifest.owner)?.uuidString == manifest.owner,
              [manifest.first, manifest.second].compactMap({ $0 }).allSatisfy({ UUID(uuidString: $0)?.uuidString == $0 }),
              manifest.first == nil || manifest.first != manifest.second,
              manifest.second == nil || manifest.first != nil else {
            throw failure("The fixture ownership registry contains invalid, duplicate, or out-of-order UUIDs.", cause: nil)
        }
        return manifest
    }

    static func command(_ arguments: [String], timeout: TimeInterval, runner: ProcessCommandRunner) async throws -> CommandResult {
        let request = CommandRequest(executable: try AppleTool.xcrun.locate(), arguments: arguments, timeout: timeout, displayName: "inventory fixture tool")
        let result = try await runner.run(request)
        guard result.succeeded else { throw failure("An inventory fixture tool failed.", cause: nil).appendingDetail(String(result.technicalSummary.prefix(1536))) }
        return result
    }

    static func string(_ value: JSONValue, field: String) throws -> String {
        guard case .string(let text) = value[field], !text.isEmpty, text.utf8.count <= 512 else {
            throw failure("simctl returned an invalid \(field) string.", cause: nil)
        }
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
