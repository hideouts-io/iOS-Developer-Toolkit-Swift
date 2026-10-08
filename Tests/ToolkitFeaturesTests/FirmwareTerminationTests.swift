import Foundation
import Testing
import ToolkitCore
@testable import ToolkitFeatures

private enum FirmwareTerminationEvent: Equatable, Sendable {
    case cancelled
    case disabled
    case enabled
}

private struct RecordingFirmwareTerminationControl: FirmwareTerminationControlling {
    let events: LockedValue<[FirmwareTerminationEvent]>

    func disableSuddenTermination() {
        events.withLock { $0.append(.disabled) }
    }

    func enableSuddenTermination() {
        events.withLock { $0.append(.enabled) }
    }
}

@Suite("Firmware termination and write protection")
struct FirmwareTerminationTests {
    @Test func quitBeforeWritingUsesTheExistingConfirmationPath() {
        #expect(FirmwareTerminationPolicy.decision(critical: false, busy: false) == .allow)
        #expect(FirmwareTerminationPolicy.decision(critical: false, busy: true) == .confirm)
    }

    @Test(arguments: [false, true])
    func quitDuringWritingIsDenied(busy: Bool) {
        #expect(FirmwareTerminationPolicy.decision(critical: true, busy: busy) == .deny)
    }

    @Test func lastWindowCloseDoesNotTerminateDuringWriting() {
        #expect(FirmwareTerminationPolicy.terminateAfterLastWindowClosed(critical: false))
        #expect(!FirmwareTerminationPolicy.terminateAfterLastWindowClosed(critical: true))
    }

    @Test func preparationRemainsCancellableUntilTheFlushedRestoreBoundary() {
        let events = LockedValue<[FirmwareTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: RecordingFirmwareTerminationControl(events: events))
        protection.receiveProgress(step: "Finding the device", fraction: 1)
        protection.receiveProgress(step: "Preparing", fraction: 0.899999)
        protection.receiveOutput("Found device in Recovery mode")
        #expect(!protection.isCritical)
        #expect(protection.cancelBeforeWriting { events.withLock { $0.append(.cancelled) } })
        protection.complete()
        #expect(events.current == [.cancelled])
    }

    @Test(arguments: [0.9, 1.0])
    func preparingAtTheRestoreBoundaryDisablesSuddenTermination(fraction: Double) {
        let events = LockedValue<[FirmwareTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: RecordingFirmwareTerminationControl(events: events))
        protection.receiveProgress(step: "Preparing", fraction: fraction)
        #expect(protection.isCritical)
        #expect(events.current == [.disabled])
        protection.complete()
        #expect(events.current == [.disabled, .enabled])
    }

    @Test(arguments: Array(FirmwareInstall.steps.dropFirst(2)))
    func aDirectJumpToAnyWritingStageIsProtected(step: String) {
        let events = LockedValue<[FirmwareTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: RecordingFirmwareTerminationControl(events: events))
        protection.receiveProgress(step: step, fraction: 0)
        #expect(protection.isCritical)
        #expect(events.current == [.disabled])
        protection.complete()
    }

    @Test(arguments: ["Step 99", "Unexpected restore phase", ""])
    func unfamiliarProgressCannotPermitTermination(step: String) {
        let events = LockedValue<[FirmwareTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: RecordingFirmwareTerminationControl(events: events))
        protection.receiveProgress(step: step, fraction: 0)
        #expect(protection.isCritical)
        #expect(FirmwareTerminationPolicy.decision(critical: protection.isCritical, busy: true) == .deny)
        protection.complete()
    }

    @Test func numericProgressFlowsIntoTheSameProtection() throws {
        let events = LockedValue<[FirmwareTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: RecordingFirmwareTerminationControl(events: events))
        let update = try #require(FirmwareInstall.progress("progress: 99 0.000000"))
        protection.receiveProgress(step: update.step, fraction: update.fraction)
        #expect(protection.isCritical)
        protection.complete()
    }

    @Test func theExactPreRestoreAnnouncementIsProtected() {
        let events = LockedValue<[FirmwareTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: RecordingFirmwareTerminationControl(events: events))
        protection.receiveOutput("About to restore device... later")
        #expect(!protection.isCritical)
        protection.receiveOutput("  About to restore device... \n")
        #expect(protection.isCritical)
        #expect(events.current == [.disabled])
        protection.complete()
    }

    @Test func protectionNeverRegressesAndRepeatedCompletionBalancesOnce() {
        let events = LockedValue<[FirmwareTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: RecordingFirmwareTerminationControl(events: events))
        protection.receiveProgress(step: "Sending the system", fraction: 0.1)
        protection.receiveProgress(step: "Finding the device", fraction: 0)
        protection.receiveProgress(step: "Preparing", fraction: 0)
        protection.receiveProgress(step: "Sending the system", fraction: 1)
        protection.receiveOutput("About to restore device...")
        #expect(protection.isCritical)
        #expect(!protection.cancelBeforeWriting { events.withLock { $0.append(.cancelled) } })
        #expect(events.current == [.disabled])
        protection.complete()
        protection.complete()
        #expect(!protection.isCritical)
        #expect(events.current == [.disabled, .enabled])
    }

    @Test func lateCallbacksCannotReacquireProtectionAfterCompletion() {
        let events = LockedValue<[FirmwareTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: RecordingFirmwareTerminationControl(events: events))
        protection.receiveProgress(step: "Preparing", fraction: 0.9)
        protection.complete()
        protection.receiveProgress(step: "Sending the system", fraction: 1)
        protection.receiveProgress(step: "New phase", fraction: 0)
        protection.receiveOutput("About to restore device...")
        protection.complete()
        #expect(!protection.isCritical)
        #expect(!protection.cancelBeforeWriting { events.withLock { $0.append(.cancelled) } })
        #expect(events.current == [.disabled, .enabled])
    }

    @Test func anOperationThatNeverWritesDoesNotEnableAnUnownedCounter() {
        let events = LockedValue<[FirmwareTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: RecordingFirmwareTerminationControl(events: events))
        protection.complete()
        protection.complete()
        protection.receiveProgress(step: "Sending the system", fraction: 1)
        #expect(!protection.isCritical)
        #expect(events.current.isEmpty)
    }

    @Test func aThrowingOperationBalancesProtectionWhenItsOwnerCompletes() {
        let events = LockedValue<[FirmwareTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: RecordingFirmwareTerminationControl(events: events))
        #expect(throws: ToolkitError.self) {
            defer { protection.complete() }
            protection.receiveProgress(step: "Sending the system", fraction: 0.5)
            throw ToolkitError(.commandFailed, message: "The test helper exited with failure.")
        }
        #expect(!protection.isCritical)
        #expect(events.current == [.disabled, .enabled])
    }

    @Test func cancellationAndCriticalEntryAreSerialized() throws {
        let events = LockedValue<[FirmwareTerminationEvent]>([])
        let protection = FirmwareWriteProtection(controller: RecordingFirmwareTerminationControl(events: events))
        let cancellationStarted = DispatchSemaphore(value: 0)
        let releaseCancellation = DispatchSemaphore(value: 0)
        let cancellationFinished = DispatchSemaphore(value: 0)
        let progressAttempted = DispatchSemaphore(value: 0)
        let progressFinished = DispatchSemaphore(value: 0)
        let cancellationAccepted = LockedValue(false)
        defer { releaseCancellation.signal() }

        DispatchQueue.global().async {
            let accepted = protection.cancelBeforeWriting {
                cancellationStarted.signal()
                guard releaseCancellation.wait(timeout: .now() + 5) == .success else {
                    Issue.record("The test did not release the cancellation callback.")
                    return
                }
                events.withLock { $0.append(.cancelled) }
            }
            cancellationAccepted.withLock { $0 = accepted }
            cancellationFinished.signal()
        }
        try #require(cancellationStarted.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async {
            progressAttempted.signal()
            protection.receiveProgress(step: "Sending the system", fraction: 0)
            progressFinished.signal()
        }
        try #require(progressAttempted.wait(timeout: .now() + 5) == .success)
        #expect(progressFinished.wait(timeout: .now()) == .timedOut)
        releaseCancellation.signal()
        try #require(cancellationFinished.wait(timeout: .now() + 5) == .success)
        try #require(progressFinished.wait(timeout: .now() + 5) == .success)
        #expect(cancellationAccepted.current)
        #expect(events.current == [.cancelled, .disabled])
        #expect(!protection.cancelBeforeWriting { events.withLock { $0.append(.cancelled) } })
        protection.complete()
        #expect(events.current == [.cancelled, .disabled, .enabled])
    }
}
