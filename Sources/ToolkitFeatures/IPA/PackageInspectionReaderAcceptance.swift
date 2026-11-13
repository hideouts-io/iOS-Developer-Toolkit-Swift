#if DEBUG
import Dispatch
import Foundation
import ToolkitCore

/// Connects explicit native acceptance controls to a genuine inspection worker. Only its
/// Dispatch thread waits; the real native code handle and incomplete copy stay owned until
/// release or finite expiry. This observes a handle before validation, not an active C call.
public struct PackageInspectionReaderAcceptance: Sendable {
    public enum Phase: String, Sendable {
        case armed
        case nativeHandleHeldBeforeValidation = "native-handle-held-before-validation"
        case released
        case validationReturned = "validation-returned"
        case expired
        case aborted
    }

    public struct Snapshot: Sendable {
        public let revision: UInt64
        public let phase: Phase
        public let originalURL: URL?
        public let packageURL: URL?
        public let directory: URL?
        public let cancellationRequested: Bool
        public let signatureStatus: CodeSignatureSummary.Status?
    }

    private struct State {
        var revision: UInt64 = 0
        var phase: Phase = .armed
        var originalURL: URL?
        var packageURL: URL?
        var cancellationRequested = false
        var signatureStatus: CodeSignatureSummary.Status?

        var snapshot: Snapshot {
            Snapshot(revision: revision, phase: phase, originalURL: originalURL,
                     packageURL: packageURL, directory: packageURL?.deletingLastPathComponent(),
                     cancellationRequested: cancellationRequested, signatureStatus: signatureStatus)
        }
    }

    private let state: LockedValue<State>
    private let barrier: DispatchSemaphore
    private let observer: @Sendable (Snapshot) -> Void

    public init(observer: @escaping @Sendable (Snapshot) -> Void) {
        state = LockedValue(State())
        barrier = DispatchSemaphore(value: 0)
        self.observer = observer
    }

    public var snapshot: Snapshot { state.current.snapshot }

    public func release() throws {
        let update = try state.withLock { value -> Snapshot in
            guard value.phase == .nativeHandleHeldBeforeValidation else {
                throw ToolkitError(.invalidInput, message: "No native package reader is waiting for release.", recovery: "Wait for the explicit owned-simulator acceptance reader to open its real code handle.", technicalDetail: nil)
            }
            value.phase = .released
            value.revision += 1
            return value.snapshot
        }
        observer(update)
        barrier.signal()
    }

    func begin(source: URL) throws {
        let update = try state.withLock { value -> Snapshot in
            if value.phase == .aborted { throw CancellationError() }
            guard value.phase == .armed, value.originalURL == nil else {
                throw ToolkitError(.invalidInput, message: "The native package reader acceptance gate has already been used.", recovery: "Launch a fresh owned-simulator acceptance session.", technicalDetail: nil)
            }
            value.originalURL = source.standardizedFileURL
            value.revision += 1
            return value.snapshot
        }
        observer(update)
    }

    /// Failure teardown must close the armed-to-held race before a structured task group
    /// drains its worker. A later real native handle cannot park after this atomic close.
    func finishAfterFailure() {
        let update = state.withLock { value -> (snapshot: Snapshot, signal: Bool) in
            switch value.phase {
            case .armed:
                value.phase = .aborted
                value.revision += 1
                return (value.snapshot, false)
            case .nativeHandleHeldBeforeValidation:
                value.phase = .released
                value.revision += 1
                return (value.snapshot, true)
            case .released, .validationReturned, .expired, .aborted:
                return (value.snapshot, false)
            }
        }
        observer(update.snapshot)
        if update.signal { barrier.signal() }
    }

    /// Called only after the executor has set its actual cancellation token.
    func cancellationRequested() {
        let update = state.withLock { value -> Snapshot in
            value.cancellationRequested = true
            value.revision += 1
            return value.snapshot
        }
        observer(update)
    }

    func holdNativeHandle(bundle: URL) throws {
        let update = try state.withLock { value -> Snapshot in
            if value.phase == .aborted { throw CancellationError() }
            guard value.phase == .armed, value.originalURL != nil else {
                throw ToolkitError(.internalInconsistency, message: "The native package reader acceptance gate is not armed.", recovery: "Inspect the acceptance launch and choose the genuine fixture again.", technicalDetail: nil)
            }
            value.packageURL = bundle
            value.phase = .nativeHandleHeldBeforeValidation
            value.revision += 1
            return value.snapshot
        }
        observer(update)

        let outcome = barrier.wait(timeout: .now() + 180)
        let final = try state.withLock { value -> Snapshot in
            // Release and expiry race under the same lock. A release that won remains valid
            // even if its signal reached this thread at the wait's exact deadline.
            if outcome == .timedOut, value.phase == .nativeHandleHeldBeforeValidation {
                value.phase = .expired
                value.revision += 1
            }
            guard value.phase == .released || value.phase == .expired else {
                throw ToolkitError(.internalInconsistency, message: "The native package reader ended in an invalid acceptance phase.", recovery: "Inspect the native acceptance failure before retrying.", technicalDetail: nil)
            }
            return value.snapshot
        }
        if final.phase == .expired {
            observer(final)
            throw ToolkitError(.timedOut, message: "The native package reader was not released within 180 seconds.", recovery: "Inspect the native acceptance failure; the worker will release its native handle and remove the incomplete private copy.", technicalDetail: nil)
        }
    }

    func validationReturned(status: CodeSignatureSummary.Status) {
        let update = state.withLock { value -> Snapshot in
            value.signatureStatus = status
            value.phase = .validationReturned
            value.revision += 1
            return value.snapshot
        }
        observer(update)
    }
}
#endif
