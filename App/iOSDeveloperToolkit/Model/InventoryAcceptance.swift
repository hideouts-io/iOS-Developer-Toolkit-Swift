#if DEBUG
import DeviceKit
import Foundation
import Observation
import ToolkitCore

/// The two test-owned simulators exposed by the native inventory acceptance launch.
struct InventoryAcceptanceTargets: Sendable {
    let first: String
    let second: String
    let owner: String

    static func parse(arguments: [String], uiTesting: Bool, demoMode: Bool) throws(ToolkitError) -> InventoryAcceptanceTargets? {
        let firstFlags = arguments.indices.filter { arguments[$0] == "-inventory-acceptance-a" }
        let secondFlags = arguments.indices.filter { arguments[$0] == "-inventory-acceptance-b" }
        let ownerFlags = arguments.indices.filter { arguments[$0] == "-inventory-acceptance-owner" }
        guard !firstFlags.isEmpty || !secondFlags.isEmpty || !ownerFlags.isEmpty else { return nil }
        guard uiTesting, !demoMode, firstFlags.count == 1, secondFlags.count == 1, ownerFlags.count == 1,
              let firstIndex = firstFlags.first, arguments.indices.contains(firstIndex + 1),
              let secondIndex = secondFlags.first, arguments.indices.contains(secondIndex + 1),
              let ownerIndex = ownerFlags.first, arguments.indices.contains(ownerIndex + 1),
              let first = UUID(uuidString: arguments[firstIndex + 1]),
              let second = UUID(uuidString: arguments[secondIndex + 1]), first != second,
              let owner = UUID(uuidString: arguments[ownerIndex + 1]) else {
            throw ToolkitError(.invalidInput, message: "The inventory acceptance launch requires two distinct simulator UUIDs and an owner UUID.", recovery: "Use a Debug build with -ui-testing YES, -demo-mode NO and one value for each inventory acceptance target and owner.", technicalDetail: nil)
        }
        return InventoryAcceptanceTargets(first: first.uuidString, second: second.uuidString, owner: owner.uuidString)
    }

    func contains(_ identifier: String) -> Bool {
        let normalized = identifier.uppercased()
        return normalized == first || normalized == second
    }
}

/// Holds one successful real A inventory reply until the native UI test explicitly releases it.
/// Cancellation deliberately does not discard that reply: the production inventory generation
/// check must reject its late delivery after B has loaded. Delivery is acknowledged only after
/// that real inventory refresh returns to its UI caller. The wait has an independent deadline.
@Observable
@MainActor
final class InventoryAcceptance {
    enum State: String {
        case idle, armed, held, released, delivered, expired
    }

    let targets: InventoryAcceptanceTargets
    private(set) var state: State = .idle
    private(set) var isDeletingFirst = false
    private let base: ProcessCommandRunner
    private var held: (result: CommandResult, continuation: CheckedContinuation<CommandResult, Error>)?
    private var deadline: Task<Void, Never>?

    init(targets: InventoryAcceptanceTargets, base: ProcessCommandRunner) {
        self.targets = targets
        self.base = base
    }

    func arm() throws(ToolkitError) {
        guard state == .idle else {
            throw ToolkitError(.invalidInput, message: "The inventory acceptance gate has already been armed.", recovery: "Relaunch the acceptance test to capture another inventory reply.", technicalDetail: nil)
        }
        state = .armed
    }

    func release() throws(ToolkitError) {
        guard let held, state == .held else {
            throw ToolkitError(.invalidInput, message: "There is no captured inventory reply to release.", recovery: "Wait for the acceptance gate to report held before releasing it.", technicalDetail: nil)
        }
        self.held = nil
        deadline?.cancel()
        deadline = nil
        state = .released
        held.continuation.resume(returning: held.result)
    }

    func inventoryRefreshReturned(target: String) {
        if state == .released && target.uppercased() == targets.first {
            state = .delivered
        }
    }

    /// Deletes only the A simulator whose fresh UUID and exact owner-bound name match this run.
    /// The UI test invokes this inside the observed confirmation sheet to cause real target loss.
    func deleteFirstSimulator(target: DeviceTarget) async throws {
        guard state == .delivered else {
            throw ToolkitError(.invalidInput, message: "The late inventory reply has not completed acceptance yet.", recovery: "Wait for the inventory gate to report delivered before deleting the owned test simulator.", technicalDetail: nil)
        }
        guard target.kind == .simulator, target.udid.uppercased() == targets.first, !isDeletingFirst else {
            throw ToolkitError(.invalidInput, message: "Only this acceptance run’s first owned simulator can be deleted.", recovery: "Use the confirmation for simulator A created by this acceptance run.", technicalDetail: nil)
        }
        isDeletingFirst = true
        defer { isDeletingFirst = false }
        let client = SimulatorClient(runner: base)
        let records = try await client.list()
        guard let record = records.first(where: { $0.udid.uppercased() == targets.first }),
              record.name == "IDT Inventory A \(targets.owner)" else {
            throw ToolkitError(.invalidInput, message: "The simulator does not match this acceptance run’s ownership marker.", recovery: "Stop the test and inspect its fixture setup; no simulator was deleted.", technicalDetail: nil)
        }
        try await client.shutdown(record.device.target)
        let deletion = try await base.run(try XcodeTool.simctl.request(["delete", targets.first], timeout: 120, displayName: "simctl delete owned acceptance simulator"))
        guard deletion.succeeded else {
            throw ToolkitError(.commandFailed, message: "Deleting the owned acceptance simulator failed.", recovery: "Inspect the simulator fixture failure and rerun the acceptance test.", technicalDetail: deletion.technicalSummary)
        }
        guard try await !client.list().contains(where: { $0.udid.uppercased() == targets.first }) else {
            throw ToolkitError(.protocolViolation, message: "The owned acceptance simulator still exists after deletion.", recovery: "Inspect the simulator service before rerunning the acceptance test.", technicalDetail: nil)
        }
    }

    func holdIfArmed(_ result: CommandResult) async throws -> CommandResult {
        guard state == .armed, result.succeeded,
              result.request.arguments == ["simctl", "listapps", targets.first] else { return result }
        return try await withCheckedThrowingContinuation { continuation in
            held = (result, continuation)
            state = .held
            deadline = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(180))
                } catch is CancellationError {
                    return
                } catch {
                    self?.expire(cause: error.localizedDescription)
                    return
                }
                self?.expire(cause: nil)
            }
        }
    }

    private func expire(cause: String?) {
        guard let held, state == .held else { return }
        self.held = nil
        deadline = nil
        state = .expired
        held.continuation.resume(throwing: ToolkitError(.timedOut, message: "The inventory acceptance gate was not released within 180 seconds.", recovery: "Inspect the native acceptance failure and rerun the test.", technicalDetail: cause))
    }
}

/// All commands and streams use the production runner; only one completed listapps reply waits.
struct InventoryAcceptanceRunner: OwnedCommandRunning {
    let base: ProcessCommandRunner
    let acceptance: InventoryAcceptance

    func run(_ request: CommandRequest) async throws -> CommandResult {
        let result = try await base.run(request)
        return try await acceptance.holdIfArmed(result)
    }

    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandStreamEvent, Error> {
        base.stream(request)
    }

    func stream(_ request: CommandRequest, cancellation: CommandCancellation) -> AsyncThrowingStream<CommandStreamEvent, Error> {
        base.stream(request, cancellation: cancellation)
    }
}
#endif
