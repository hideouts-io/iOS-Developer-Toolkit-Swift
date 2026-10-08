import Foundation

/// Signals cancellation of one owned child without cancelling its output consumer. The owner
/// must keep consuming until the runner reports the child's actual exit, including failures.
public final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var action: (@Sendable () -> Void)?

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    public func cancel() {
        lock.lock()
        let firstRequest = !requested
        requested = true
        let cancel = firstRequest ? action : nil
        lock.unlock()
        cancel?()
    }

    /// Connects this operation's child. A request that arrived before registration is delivered
    /// immediately. The action must signal cancellation without reentering the owner's state.
    public func register(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        self.action = action
        let alreadyRequested = requested
        lock.unlock()
        if alreadyRequested { action() }
    }

    /// Releases the child after its output stream has ended.
    public func clear() {
        lock.lock()
        action = nil
        lock.unlock()
    }
}
