import Foundation

/// The process-level sudden-termination counter used by one owned firmware operation.
public protocol FirmwareTerminationControlling: Sendable {
    func disableSuddenTermination()
    func enableSuddenTermination()
}

public struct FirmwareProcessTerminationControl: FirmwareTerminationControlling {
    public init() {}

    public func disableSuddenTermination() {
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    public func enableSuddenTermination() {
        ProcessInfo.processInfo.enableSuddenTermination()
    }
}

/// Protects one installer until its owned helper has exited. All state and counter transitions
/// share a lock because progress callbacks and cancellation can arrive on different threads.
/// This cannot prevent Force Quit, signals, power loss, or device disconnection.
public final class FirmwareWriteProtection: @unchecked Sendable {
    private enum State {
        case preparing
        case writing
        case completed
    }

    private let lock = NSLock()
    private let controller: any FirmwareTerminationControlling
    private var state = State.preparing

    public init(controller: any FirmwareTerminationControlling) {
        self.controller = controller
    }

    public var isCritical: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .writing
    }

    /// The pinned helper flushes Preparing 0.9 before starting the restore protocol. Preparing
    /// 1.0 follows restored_start_restore, so protection starts at the earlier boundary. An
    /// unfamiliar stage is conservatively protected rather than assumed safe to interrupt.
    public func receiveProgress(step: String, fraction: Double) {
        let critical = FirmwareInstall.isPastPointOfNoReturn(step: step)
            || !FirmwareInstall.steps.contains(step)
            || (step == "Preparing" && fraction >= 0.9)
        guard critical else { return }
        enterCriticalPhase()
    }

    /// Supplements numeric progress with the pinned helper's pre-restore announcement. This
    /// text can be buffered; Preparing 0.9 remains the earlier, flushed boundary.
    public func receiveOutput(_ line: String) {
        guard line.trimmingCharacters(in: .whitespacesAndNewlines) == "About to restore device..." else { return }
        enterCriticalPhase()
    }

    /// Runs cancellation only before writing starts. The closure executes inside the state
    /// lock and must not synchronously reenter this protection, including through a task's
    /// cancellation handler. Returns false after writing starts or the helper has exited.
    public func cancelBeforeWriting(_ cancel: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .preparing else { return false }
        cancel()
        return true
    }

    /// Call only after the owned helper has truly exited, including error exits. Completion
    /// balances a counter acquired by this operation once and ignores all later callbacks.
    public func complete() {
        lock.lock()
        defer { lock.unlock() }
        let wasWriting = state == .writing
        state = .completed
        if wasWriting { controller.enableSuddenTermination() }
    }

    private func enterCriticalPhase() {
        lock.lock()
        defer { lock.unlock() }
        guard state == .preparing else { return }
        state = .writing
        controller.disableSuddenTermination()
    }
}

/// The firmware-specific restriction applied before the app's existing quit confirmation.
public enum FirmwareTerminationPolicy {
    public enum Decision: Sendable, Equatable {
        case allow
        case confirm
        case deny
    }

    public static func decision(critical: Bool, busy: Bool) -> Decision {
        if critical { return .deny }
        return busy ? .confirm : .allow
    }

    public static func terminateAfterLastWindowClosed(critical: Bool) -> Bool {
        !critical
    }
}
