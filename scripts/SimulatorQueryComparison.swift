import Foundation
import ToolkitCore

/// Hosted-only controls: one registered simulator, no UI workload and no process sampler.
/// Native control files remain private; only the separately validated summary reaches CI logs.
extension PackageInspectionFixtures {
    enum QueryStage: String {
        case before, after

        var expectedState: String { self == .before ? "Shutdown" : "Booted" }
    }

    enum PostBootOrder: String, Encodable {
        case swiftFirst = "swift-first"
        case nativeFirst = "native-first"

        var transports: [String] { self == .swiftFirst ? ["swift", "native"] : ["native", "swift"] }
    }

    struct QueryContext: Codable {
        let environment: [String: String]
        let workingDirectory: String
    }

    struct QueryReceipt: Codable {
        let outcome: String
        let elapsedMilliseconds: Double?
        let stdoutBytes: Int
        let stderrBytes: Int
        let exitCode: Int32?
        let signal: Int32?
        let shellExitStatus: Int?
        let toolkitKind: ToolkitError.Kind?
        let schemaAndOwnerValid: Bool
    }

    struct ComparisonFailure: Error, CustomStringConvertible {
        let primary: any Error
        let reporting: (any Error)?

        var description: String {
            reporting == nil ? "The Swift comparison failed; inspect its bounded receipt. The original failure is retained privately."
                : "The Swift comparison and receipt writing both failed; the original failure is retained privately."
        }
    }

    struct NativeFooter: Decodable {
        let elapsedMilliseconds: Double
        let shellExitStatus: Int
    }

    struct ControlSummary: Encodable {
        let control: String
        let stepOutcome: String
        let prerequisite: String
        let shellWaitStatus: Int?
        let receipt: QueryReceipt?
        let rawOutputState: String
    }

    struct ComparisonSummary: Encodable {
        let allocation: String
        let bootOwnershipGateAndBoot: String
        let declaredPostBootOrder: PostBootOrder
        let controls: [ControlSummary]
        let limits: String
    }

    static func allocateComparison(directory: URL, runner: ProcessCommandRunner) async throws {
        try SecureFileIO.createNewPrivateDirectory(at: directory)
        let owner = UUID().uuidString
        let initial = Manifest(owner: owner, simulator: nil, sources: nil, inventory: nil, existingPreparations: [])
        try save(initial, directory: directory)
        let context = QueryContext(environment: CommandEnvironment.minimal(), workingDirectory: FileManager.default.currentDirectoryPath)
        try SecureFileIO.writeNewFile(JSONEncoder().encode(context), to: directory.appendingPathComponent("context.json"), mode: 0o600)
        let template = try await simulatorTemplate(runner: runner)
        let result = try await command(["simctl", "create", "IDT Package \(owner)", template.type, template.runtime], timeout: 120, runner: runner)
        guard let identifier = UUID(uuidString: result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString else {
            throw failure("Comparison allocation returned no valid UUID; exact-owner cleanup must reconcile allocation.", cause: nil)
        }
        try await register(Manifest(owner: owner, simulator: identifier, sources: nil, inventory: nil, existingPreparations: []), directory: directory, runner: runner)
        print("[query comparison] A separate owned simulator is registered but has not been booted.")
    }

    /// This extra discovery is a required mutation ownership gate, not one of the four controls.
    static func bootComparison(directory: URL, runner: ProcessCommandRunner) async throws {
        let manifest = try load(directory: directory)
        try validateQueryOwner(try await simulators(runner: runner), manifest: manifest, expectedState: "Shutdown")
        guard let identifier = manifest.simulator else { throw failure("Comparison boot requires a registered UUID.", cause: nil) }
        _ = try await command(["simctl", "bootstatus", identifier, "-b"], timeout: 600, runner: runner)
        print("[query comparison] The separate exact-owner gate and boot completed; after-boot controls are eligible.")
    }

    static func validateQueryOwner(_ records: [Simulator], manifest: Manifest, expectedState: String) throws {
        let named = records.filter { $0.name == "IDT Package \(manifest.owner)" }
        guard let record = named.first, named.count == 1, record.identifier == manifest.simulator,
              records.filter({ $0.identifier == manifest.simulator }).count == 1,
              record.available, record.state == expectedState else {
            throw failure("The query did not validate one available registered simulator with its exact owner name and expected state.", cause: nil)
        }
    }

    /// Keep the consumer alive until actual exit even after output-bound cancellation. Timeout
    /// errors do not expose a structured termination; absent exit/signal values remain unknown.
    static func compareQuery(directory: URL, stage: QueryStage, runner: ProcessCommandRunner) async throws {
        let manifest = try load(directory: directory)
        let context = try JSONDecoder().decode(QueryContext.self, from: readOwnedFile(directory.appendingPathComponent("context.json"), maximumBytes: 65536))
        guard context.environment == CommandEnvironment.minimal(), context.workingDirectory == FileManager.default.currentDirectoryPath else {
            throw failure("Comparison environment or working directory changed between controls.", cause: nil)
        }
        let bound = 8 * 1024 * 1024
        let request = CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["simctl", "list", "devices", "--json"],
                                     environment: context.environment, workingDirectory: URL(fileURLWithPath: context.workingDirectory),
                                     standardInput: nil, timeout: 60, outputLimit: bound, displayName: "isolated simulator query", terminationGracePeriod: 3)
        let cancellation = CommandCancellation()
        let started = ContinuousClock.now
        var stdout = Data(), stderr = Data()
        var stdoutBytes = 0, stderrBytes = 0
        var result: CommandResult?
        var primary: (any Error)?
        var toolkitKind: ToolkitError.Kind?
        var outcome = "missingResult"
        do {
            for try await event in runner.stream(request, cancellation: cancellation) {
                switch event {
                case .standardOutput(let data):
                    stdoutBytes += data.count
                    stdout.append(data.prefix(max(0, bound - stdout.count)))
                case .standardError(let data):
                    stderrBytes += data.count
                    stderr.append(data.prefix(max(0, bound - stderr.count)))
                case .finished(let value): result = value
                }
                if stdoutBytes > bound || stderrBytes > bound { cancellation.cancel() }
            }
            if let result { outcome = result.succeeded ? "succeeded" : "failed" }
        } catch let error as ToolkitError {
            primary = error
            toolkitKind = error.kind
            outcome = error.kind == .timedOut ? "timedOut" : error.kind == .cancelled ? "cancelled" : "runnerError"
        } catch {
            primary = error
            outcome = "runnerError"
        }
        if stdoutBytes > bound || stderrBytes > bound { outcome = "outputLimitExceeded" }
        let elapsed = started.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        var schemaAndOwnerValid = false
        if outcome == "succeeded" {
            do {
                try validateQueryOwner(simulatorRecords(stdout), manifest: manifest, expectedState: stage.expectedState)
                schemaAndOwnerValid = true
            } catch {
                primary = error
                toolkitKind = (error as? ToolkitError)?.kind
                outcome = "schemaOrOwnerInvalid"
            }
        }
        let signal: Int32?
        if case .signaled(let value) = result?.termination { signal = value } else { signal = nil }
        let receipt = QueryReceipt(outcome: outcome, elapsedMilliseconds: milliseconds, stdoutBytes: stdoutBytes, stderrBytes: stderrBytes,
                                   exitCode: result?.exitCode, signal: signal, shellExitStatus: nil, toolkitKind: toolkitKind, schemaAndOwnerValid: schemaAndOwnerValid)
        do {
            try SecureFileIO.writeNewFile(stdout, to: directory.appendingPathComponent("swift-\(stage.rawValue).stdout"), mode: 0o600)
            try SecureFileIO.writeNewFile(stderr, to: directory.appendingPathComponent("swift-\(stage.rawValue).stderr"), mode: 0o600)
            try SecureFileIO.writeNewFile(JSONEncoder().encode(receipt), to: directory.appendingPathComponent("swift-\(stage.rawValue).json"), mode: 0o600)
        } catch {
            if let primary { throw ComparisonFailure(primary: primary, reporting: error) }
            throw error
        }
        guard outcome == "succeeded", schemaAndOwnerValid else {
            throw ComparisonFailure(primary: primary ?? failure("The Swift comparison query failed without a successful result.", cause: nil), reporting: nil)
        }
    }

    /// Reuse the exact Swift schema/owner parser for both transports. Missing terminal native
    /// receipts remain unknown, including when the Actions step failed at its one-minute limit.
    static func reportComparison(directory: URL) throws {
        _ = try load(directory: directory)
        let result = Result { try comparisonSummary(directory: directory) }
        // Remove only fixed task-owned raw files, including after a validation/read failure.
        // The manifest and bounded receipts remain available for independent target cleanup.
        do {
            for name in ["swift-before", "native-before", "swift-after", "native-after"] {
                for suffix in ["stdout", "stderr"] {
                    do { try FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).\(suffix)")) }
                    catch CocoaError.fileNoSuchFile { /* Ineligible/interrupted controls may create no file. */ }
                }
            }
        } catch {
            if case .failure(let primary) = result {
                throw failure("Comparison reporting and private output removal both failed.", cause: primary).appendingDetail(bounded(error))
            }
            throw error
        }
        let summary = try result.get()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(summary)
        guard data.count <= 16384 else { throw failure("The comparison summary exceeded its public size bound.", cause: nil) }
        // A failing async @main may abort before stdio buffers flush. Write the bounded
        // receipt directly so failed controls retain the same evidence as successful ones.
        try FileHandle.standardOutput.write(contentsOf: Data("[query comparison] ".utf8) + data + Data([0x0a]))
        guard summary.controls.filter({ $0.prerequisite == "eligible" }).allSatisfy({ $0.stepOutcome == "success" && $0.receipt?.outcome == "succeeded" && $0.receipt?.schemaAndOwnerValid == true }) else {
            throw failure("An eligible comparison control failed or lacks validated terminal evidence; original step failures are retained.", cause: nil)
        }
    }

    static func comparisonSummary(directory: URL) throws -> ComparisonSummary {
        let manifest = try load(directory: directory)
        let environment = ProcessInfo.processInfo.environment
        let allocation = try comparisonStep("IDT_COMPARE_ALLOCATE", environment: environment)
        let boot = try comparisonStep("IDT_COMPARE_BOOT", environment: environment)
        guard let orderValue = environment["IDT_COMPARE_POST_BOOT_ORDER"], let order = PostBootOrder(rawValue: orderValue) else {
            throw failure("The comparison requires an explicit supported post-boot workflow order.", cause: nil)
        }
        var controls: [ControlSummary] = []
        for stage in [QueryStage.before, .after] {
            let transports = stage == .before ? ["swift", "native"] : order.transports
            for transport in transports {
                let name = "\(transport)-\(stage.rawValue)"
                let step = try comparisonStep("IDT_COMPARE_\(transport.uppercased())_\(stage.rawValue.uppercased())", environment: environment)
                let prerequisite = allocation != "success" ? "allocationFailed" : stage == .after && boot != "success" ? "bootOwnershipGateOrBootFailed" : "eligible"
                let stdout = try comparisonFile(directory.appendingPathComponent("\(name).stdout"), maximumBytes: 8 * 1024 * 1024)
                let stderr = try comparisonFile(directory.appendingPathComponent("\(name).stderr"), maximumBytes: 8 * 1024 * 1024)
                let terminal = try comparisonFile(directory.appendingPathComponent("\(name).json"), maximumBytes: 65536)
                let shellWaitStatus: Int?
                let footer: NativeFooter?
                if transport == "native" {
                    let returned = try comparisonFile(directory.appendingPathComponent("\(name).return.json"), maximumBytes: 64)
                    shellWaitStatus = try returned.map { try JSONDecoder().decode(Int.self, from: $0) }
                    footer = try terminal.map { try JSONDecoder().decode(NativeFooter.self, from: $0) }
                    guard shellWaitStatus.map({ (0...255).contains($0) }) ?? true,
                          footer.map({ $0.elapsedMilliseconds.isFinite && $0.elapsedMilliseconds >= 0 && (0...255).contains($0.shellExitStatus) }) ?? true else {
                        throw failure("A native comparison return or terminal receipt is invalid.", cause: nil)
                    }
                    if let shellWaitStatus, let footer, shellWaitStatus != footer.shellExitStatus {
                        throw failure("The native comparison shell return and terminal receipt disagree.", cause: nil)
                    }
                } else { shellWaitStatus = nil; footer = nil }
                let receipt: QueryReceipt?
                if transport == "swift" {
                    receipt = try terminal.map { try JSONDecoder().decode(QueryReceipt.self, from: $0) }
                } else if let stdout, let stderr {
                    var valid = false
                    do {
                        try validateQueryOwner(simulatorRecords(stdout), manifest: manifest, expectedState: stage.expectedState)
                        valid = true
                    } catch { valid = false }
                    let outcome = footer.map { terminal in
                        shellWaitStatus == nil ? "shellWaitReceiptUnavailable"
                            : terminal.shellExitStatus == 0 ? (valid ? "succeeded" : "schemaOrOwnerInvalid") : "failed"
                    } ?? "terminalReceiptUnavailable"
                    receipt = QueryReceipt(outcome: outcome, elapsedMilliseconds: footer?.elapsedMilliseconds,
                                           stdoutBytes: stdout.count, stderrBytes: stderr.count, exitCode: nil, signal: nil,
                                           shellExitStatus: footer?.shellExitStatus, toolkitKind: nil, schemaAndOwnerValid: valid)
                } else { receipt = nil }
                controls.append(ControlSummary(control: name, stepOutcome: step, prerequisite: prerequisite, shellWaitStatus: shellWaitStatus, receipt: receipt,
                                               rawOutputState: stdout == nil || stderr == nil ? "unavailable" : "readPrivately"))
            }
        }
        return ComparisonSummary(allocation: allocation, bootOwnershipGateAndBoot: boot, declaredPostBootOrder: order, controls: controls,
            limits: "Before-boot controls run Swift then native; declared post-boot order is workflow metadata, not observed child-start timing. Verify actual step order and boot-to-step gaps independently from workflow logs and timestamps. Pipes versus private files; Swift request timeout 60s/grace 3s; native step 1min includes startup and different termination. shellWaitStatus observes the launch invocation return before Python finish; it does not prove exec reached xcrun or identify an exit versus signal. Missing return receipt means unobserved status; missing footer means elapsed unavailable. A failed workflow step remains failed even with status zero and valid JSON. Before controls follow allocation discovery; boot has a separate fresh owner gate. Nonreproduction is not a fix; one-path failure alone is not causal proof.")
    }

    static func comparisonStep(_ key: String, environment: [String: String]) throws -> String {
        guard let value = environment[key], ["success", "failure", "skipped", "cancelled"].contains(value) else {
            throw failure("A comparison workflow step outcome is missing or invalid.", cause: nil)
        }
        return value
    }

    /// Empty output is evidence, not an unreadable record. Reject links, shared files and
    /// oversized results before decoding; read only fixed files in the original 0700 registry.
    static func comparisonFile(_ url: URL, maximumBytes: Int) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw failure("A private comparison file could not be opened safely.", cause: nil)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(),
              metadata.st_mode & 0o777 == 0o600, metadata.st_nlink == 1, metadata.st_size <= maximumBytes else {
            try handle.close()
            throw failure("Comparison results require bounded single-link owner-only regular files.", cause: nil)
        }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        try handle.close()
        guard data.count <= maximumBytes else { throw failure("A comparison file grew beyond its bound.", cause: nil) }
        return data
    }
}
