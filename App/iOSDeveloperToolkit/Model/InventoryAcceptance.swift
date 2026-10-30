#if DEBUG
import Foundation
import Observation
import ToolkitCore

/// The two test-owned simulators exposed by the native inventory acceptance launch.
struct InventoryAcceptanceTargets: Sendable {
    let first: String
    let second: String

    static func parse(arguments: [String], uiTesting: Bool, demoMode: Bool) throws(ToolkitError) -> InventoryAcceptanceTargets? {
        let firstFlags = arguments.indices.filter { arguments[$0] == "-inventory-acceptance-a" }
        let secondFlags = arguments.indices.filter { arguments[$0] == "-inventory-acceptance-b" }
        guard !firstFlags.isEmpty || !secondFlags.isEmpty else { return nil }
        guard uiTesting, !demoMode, firstFlags.count == 1, secondFlags.count == 1,
              let firstIndex = firstFlags.first, arguments.indices.contains(firstIndex + 1),
              let secondIndex = secondFlags.first, arguments.indices.contains(secondIndex + 1),
              let first = UUID(uuidString: arguments[firstIndex + 1]),
              let second = UUID(uuidString: arguments[secondIndex + 1]), first != second else {
            throw ToolkitError(.invalidInput, message: "The inventory acceptance launch requires two distinct simulator UUIDs.", recovery: "Use a Debug build with -ui-testing YES, -demo-mode NO and one value for each inventory acceptance target.", technicalDetail: nil)
        }
        return InventoryAcceptanceTargets(first: first.uuidString, second: second.uuidString)
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
    private var held: (result: CommandResult, continuation: CheckedContinuation<CommandResult, Error>)?
    private var deadline: Task<Void, Never>?

    init(targets: InventoryAcceptanceTargets) {
        self.targets = targets
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
