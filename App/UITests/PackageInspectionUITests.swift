import Darwin
import Foundation
import XCTest

/// Explicit hosted acceptance keeps native file panels and termination out of ordinary runs.
@MainActor
final class PackageInspectionUITests: XCTestCase {
    private var application: XCUIApplication?

    struct Fixtures {
        let simulator: String
        let owner: String
        let valid: String
        let validB: String
        let invalid: String

        static func load(environment: [String: String]) throws -> Fixtures {
            let simulator = try XCTUnwrap(environment["IDT_PACKAGE_FIXTURE_SIMULATOR"])
            let owner = try XCTUnwrap(environment["IDT_PACKAGE_FIXTURE_OWNER"])
            let directory = try XCTUnwrap(environment["IDT_PACKAGE_FIXTURE_DIRECTORY"])
            let valid = try XCTUnwrap(environment["IDT_PACKAGE_FIXTURE_VALID"])
            let validB = try XCTUnwrap(environment["IDT_PACKAGE_FIXTURE_VALID_B"])
            let invalid = try XCTUnwrap(environment["IDT_PACKAGE_FIXTURE_INVALID"])
            XCTAssertEqual(UUID(uuidString: simulator)?.uuidString, simulator)
            XCTAssertEqual(UUID(uuidString: owner)?.uuidString, owner)
            let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
            XCTAssertTrue(directory.hasPrefix("/"))
            XCTAssertTrue([directory, valid, validB, invalid].allSatisfy { $0.utf8.count <= 4096 && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r") })
            XCTAssertEqual(valid, root.appendingPathComponent("ValidSimulator.app").path)
            XCTAssertEqual(validB, root.appendingPathComponent("ValidSimulatorB.app").path)
            XCTAssertEqual(invalid, root.appendingPathComponent("Malformed.ipa").path)
            return Fixtures(simulator: simulator, owner: owner, valid: valid, validB: validB, invalid: invalid)
        }
    }

    struct Preparation {
        let directory: String
        let identifier: String
    }

    struct CleanupReceipt: Encodable {
        let preparedDirectories: [String]
    }

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IDT_PACKAGE_UI_TESTS"] == "1",
                          "Requires the explicit hosted package inspection acceptance opt-in.")
    }

    override func tearDown() async throws {
        application?.terminate()
    }

    func testPackageInspectionRecoveryAndNormalQuitCleanup() throws {
        let fixtures = try Fixtures.load(environment: ProcessInfo.processInfo.environment)
        let app = XCUIApplication()
        application = app
        launchOwnedApplication(app, fixtures: fixtures)

        // Cancel normal Quit while a genuine unfinished reader owns its native handle and copy.
        let firstReaderArm = element("package-reader-arm")
        reveal(firstReaderArm)
        XCTAssertTrue(firstReaderArm.isEnabled)
        firstReaderArm.click()
        wait(element("package-reader-phase"), predicate: "value == 'armed'", timeout: 5)
        try choosePackage(fixtures.valid)
        wait(element("package-reader-phase"), predicate: "value == 'native-handle-held-before-validation'", timeout: 120)
        let firstReaderDirectory = try value("package-reader-directory")
        XCTAssertEqual(try value("package-reader-original-url"), fixtures.valid)
        XCTAssertEqual(try value("package-reader-package-url"), URL(fileURLWithPath: firstReaderDirectory).appendingPathComponent("ValidSimulator.app").path)
        try requirePrivateDirectory(firstReaderDirectory)
        try requirePackageCopy(directory: firstReaderDirectory, original: fixtures.valid)
        XCTAssertEqual(try value("package-reader-cancelled"), "false")
        XCTAssertEqual(try value("package-reader-signature-status"), "pending")
        XCTAssertEqual(try value("package-reader-choice-returned"), "false")
        XCTAssertEqual(try value("package-is-terminating"), "false")
        XCTAssertEqual(try value("package-prepared-id"), "none")
        wait(element("package-active-operations"), predicate: "value == '1'", timeout: 10)
        wait(element("install-package"), predicate: "exists == true AND enabled == false", timeout: 10)
        attachState("package-quit-cancel-reader-held")

        app.typeKey("q", modifierFlags: [.command])
        let quitCancel = element("quit-operations-cancel")
        wait(quitCancel, predicate: "exists == true AND hittable == true", timeout: 10)
        attach(app.debugDescription, name: "package-quit-cancel-alert")
        quitCancel.click()
        wait(quitCancel, predicate: "exists == false", timeout: 10)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(try value("package-is-terminating"), "false")
        XCTAssertEqual(try value("package-reader-phase"), "native-handle-held-before-validation")
        XCTAssertEqual(try value("package-reader-cancelled"), "false")
        XCTAssertEqual(try value("package-reader-signature-status"), "pending")
        XCTAssertEqual(try value("package-reader-choice-returned"), "false")
        XCTAssertEqual(try value("package-active-operations"), "1")
        XCTAssertEqual(try value("package-reader-directory"), firstReaderDirectory)
        XCTAssertEqual(try value("package-prepared-id"), "none")
        XCTAssertFalse(element("error-message").exists)
        XCTAssertFalse(element("package-inspection-failed").exists)
        wait(element("install-package"), predicate: "exists == true AND enabled == false", timeout: 10)
        try requirePrivateDirectory(firstReaderDirectory)
        try requirePackageCopy(directory: firstReaderDirectory, original: fixtures.valid)
        attachState("package-quit-cancel-reader-owned")

        let firstReaderRelease = element("package-reader-release")
        reveal(firstReaderRelease)
        XCTAssertTrue(firstReaderRelease.isEnabled)
        firstReaderRelease.click()
        wait(element("package-reader-phase"), predicate: "value == 'validation-returned'", timeout: 120)
        wait(element("package-reader-choice-returned"), predicate: "value == 'true'", timeout: 10)
        wait(element("package-active-operations"), predicate: "value == '0'", timeout: 10)
        XCTAssertEqual(try value("package-is-terminating"), "false")
        XCTAssertEqual(try value("package-reader-cancelled"), "false")
        XCTAssertEqual(try value("package-reader-signature-status"), "valid")
        let first = try requirePreparation(original: fixtures.valid, activeOperations: 0)
        XCTAssertEqual(first.directory, firstReaderDirectory)
        XCTAssertEqual(try value("package-selection"), "ValidSimulator.app")
        XCTAssertFalse(element("package-inspection-failed").exists)
        attachState("package-first-valid")

        // This is a genuine malformed archive. No error or preparation result is injected.
        try choosePackage(fixtures.invalid)
        wait(element("error-message"), predicate: "exists == true", timeout: 120)
        XCTAssertEqual(try value("error-message"), "The file is not a valid ZIP-based package.")
        attachState("package-malformed-error")
        let dismiss = element("error-dismiss")
        wait(dismiss, predicate: "exists == true AND hittable == true", timeout: 10)
        dismiss.click()
        wait(element("error-message"), predicate: "exists == false", timeout: 10)
        wait(element("package-inspection-failed"), predicate: "exists == true", timeout: 10)
        wait(element("package-active-operations"), predicate: "value == '0'", timeout: 10)
        XCTAssertEqual(try value("package-selection"), "Malformed.ipa")
        XCTAssertEqual(try value("package-prepared-id"), "none")
        XCTAssertEqual(try value("package-prepared-directory"), "none")
        XCTAssertEqual(try value("package-original-url"), "none")
        wait(element("install-package"), predicate: "exists == true AND enabled == false", timeout: 10)
        try requireAbsent(first.directory)
        XCTAssertFalse(element("running-operations").exists)
        attachState("package-malformed-denied")

        try choosePackage(fixtures.valid)
        let recovered = try requirePreparation(original: fixtures.valid, activeOperations: 0)
        XCTAssertNotEqual(recovered.directory, first.directory)
        XCTAssertNotEqual(recovered.identifier, first.identifier)
        XCTAssertFalse(element("package-inspection-failed").exists)
        let install = element("install-package")
        reveal(install)
        install.click()
        wait(element("confirmation-detail"), predicate: "exists == true", timeout: 10)
        XCTAssertEqual(try value("confirmation-title"), "Install Package Fixture?")
        XCTAssertEqual(try value("confirmation-detail"), "ValidSimulator.app will be installed on IDT Package \(fixtures.owner). iOS still checks the signature, provisioning, and entitlements.")
        XCTAssertEqual(app.sheets.count, 1)
        wait(element("confirm-button"), predicate: "exists == true AND enabled == false", timeout: 10)
        XCTAssertTrue(element("confirmation-field").exists)
        attachState("package-confirmation")
        let cancel = element("confirmation-cancel")
        wait(cancel, predicate: "exists == true AND hittable == true", timeout: 10)
        cancel.click()
        wait(element("confirm-button"), predicate: "exists == false", timeout: 10)
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertEqual(try value("package-prepared-directory"), recovered.directory)
        XCTAssertEqual(try value("package-prepared-id"), recovered.identifier)
        XCTAssertTrue(install.isEnabled)
        XCTAssertFalse(element("running-operations").exists)
        try requirePrivateDirectory(recovered.directory)
        attachState("package-cancel-preserved")

        // Only completion order is controlled. A and B both perform genuine native inspection.
        let arm = element("package-completion-arm")
        reveal(arm)
        XCTAssertTrue(arm.isEnabled)
        arm.click()
        wait(element("package-completion-state"), predicate: "value == 'armed'", timeout: 5)
        try choosePackage(fixtures.valid)
        wait(element("package-completion-state"), predicate: "value == 'held'", timeout: 120)
        let late = try heldPreparation(original: fixtures.valid)
        XCTAssertNotEqual(late.directory, recovered.directory)
        XCTAssertNotEqual(late.identifier, recovered.identifier)
        try requireAbsent(recovered.directory)
        XCTAssertEqual(try value("package-prepared-id"), "none")
        XCTAssertEqual(try value("package-selection"), "ValidSimulator.app")
        wait(install, predicate: "exists == true AND enabled == false", timeout: 10)
        wait(element("package-active-operations"), predicate: "value == '1'", timeout: 10)
        XCTAssertTrue(element("package-inspection-running").exists)
        attachState("package-completed-a-held")

        try choosePackage(fixtures.validB)
        let current = try requirePreparation(original: fixtures.validB, activeOperations: 1)
        XCTAssertEqual(try value("package-selection"), "ValidSimulatorB.app")
        XCTAssertNotEqual(current.directory, late.directory)
        XCTAssertNotEqual(current.identifier, late.identifier)
        XCTAssertEqual(try value("package-completion-state"), "held")
        XCTAssertEqual(try value("package-held-cancelled"), "pending")
        try requirePrivateDirectory(late.directory)
        attachState("package-b-ready-a-held")

        let release = element("package-completion-release")
        reveal(release)
        XCTAssertTrue(release.isEnabled)
        release.click()
        wait(element("package-completion-state"), predicate: "value == 'delivered'", timeout: 10)
        XCTAssertEqual(try value("package-held-cancelled"), "true", "A's actual inspection work task must observe the cancellation caused by selecting B")
        wait(element("package-active-operations"), predicate: "value == '0'", timeout: 10)
        try requireAbsent(late.directory)
        XCTAssertEqual(try value("package-prepared-directory"), current.directory)
        XCTAssertEqual(try value("package-prepared-id"), current.identifier)
        XCTAssertEqual(try value("package-original-url"), fixtures.validB)
        XCTAssertEqual(try value("package-selection"), "ValidSimulatorB.app")
        XCTAssertFalse(element("package-inspection-running").exists)
        XCTAssertFalse(element("package-inspection-failed").exists)
        XCTAssertFalse(element("error-message").exists)
        XCTAssertTrue(install.isEnabled)
        XCTAssertFalse(element("running-operations").exists)
        try requirePrivateDirectory(current.directory)
        attachState("package-late-a-disposed-b-preserved")

        reveal(install)
        install.click()
        wait(element("confirmation-detail"), predicate: "exists == true", timeout: 10)
        XCTAssertEqual(try value("confirmation-title"), "Install Package Fixture B?")
        XCTAssertEqual(try value("confirmation-detail"), "ValidSimulatorB.app will be installed on IDT Package \(fixtures.owner). iOS still checks the signature, provisioning, and entitlements.")
        XCTAssertEqual(app.sheets.count, 1)
        wait(element("confirm-button"), predicate: "exists == true AND enabled == false", timeout: 10)
        XCTAssertTrue(element("confirmation-field").exists)
        attachState("package-b-confirmation-after-late-a")
        wait(cancel, predicate: "exists == true AND hittable == true", timeout: 10)
        cancel.click()
        wait(element("confirm-button"), predicate: "exists == false", timeout: 10)
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertEqual(try value("package-prepared-directory"), current.directory)
        XCTAssertEqual(try value("package-prepared-id"), current.identifier)
        XCTAssertTrue(install.isEnabled)
        XCTAssertFalse(element("running-operations").exists)
        try requirePrivateDirectory(current.directory)
        attachState("package-b-cancel-preserved")

        // Normal Quit exercises AppDelegate's termination reply and production cleanup.
        // terminate() in tearDown is failure cleanup and cannot establish this assertion.
        app.typeKey("q", modifierFlags: [.command])
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Normal Command-Q must exit after removing its idle prepared package")
        try requireAbsent(first.directory)
        try requireAbsent(recovered.directory)
        try requireAbsent(late.directory)
        try requireAbsent(current.directory)

        // A new launch owns a real unfinished worker and native code handle, before validation.
        // Holding a completed result above does not establish this reader-lifetime behavior.
        launchOwnedApplication(app, fixtures: fixtures)
        let armReader = element("package-reader-arm")
        reveal(armReader)
        XCTAssertTrue(armReader.isEnabled)
        armReader.click()
        wait(element("package-reader-phase"), predicate: "value == 'armed'", timeout: 5)
        try choosePackage(fixtures.valid)
        wait(element("package-reader-phase"), predicate: "value == 'native-handle-held-before-validation'", timeout: 120)
        let readerDirectory = try value("package-reader-directory")
        XCTAssertEqual(try value("package-reader-original-url"), fixtures.valid)
        XCTAssertEqual(try value("package-reader-package-url"), URL(fileURLWithPath: readerDirectory).appendingPathComponent("ValidSimulator.app").path)
        try requirePrivateDirectory(readerDirectory)
        try requirePackageCopy(directory: readerDirectory, original: fixtures.valid)
        XCTAssertEqual(try value("package-reader-cancelled"), "false")
        XCTAssertEqual(try value("package-reader-signature-status"), "pending")
        XCTAssertEqual(try value("package-reader-choice-returned"), "false")
        XCTAssertEqual(try value("package-is-terminating"), "false")
        XCTAssertEqual(try value("package-prepared-id"), "none")
        wait(element("package-active-operations"), predicate: "value == '1'", timeout: 10)
        wait(element("install-package"), predicate: "exists == true AND enabled == false", timeout: 10)
        attachState("package-native-handle-held-before-validation")

        app.typeKey("q", modifierFlags: [.command])
        let quitAnyway = element("quit-operations-confirm")
        wait(quitAnyway, predicate: "exists == true AND hittable == true", timeout: 10)
        attach(app.debugDescription, name: "package-quit-operations-alert")
        quitAnyway.click()
        // The production deadline remains eight seconds. It must refuse this incomplete Quit.
        wait(element("error-message"), predicate: "exists == true", timeout: 20)
        XCTAssertEqual(try value("error-message"), "Quit cleanup is still running after eight seconds. The app will remain open.")
        XCTAssertEqual(try value("error-recovery"), "Wait for the active operation to finish, then try quitting again.")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(try value("package-is-terminating"), "true")
        XCTAssertEqual(try value("package-reader-phase"), "native-handle-held-before-validation")
        XCTAssertEqual(try value("package-reader-cancelled"), "true")
        XCTAssertEqual(try value("package-reader-choice-returned"), "false")
        XCTAssertEqual(try value("package-active-operations"), "1")
        try requirePrivateDirectory(readerDirectory)
        try requirePackageCopy(directory: readerDirectory, original: fixtures.valid)
        attachState("package-quit-timeout-reader-owned")
        wait(dismiss, predicate: "exists == true AND hittable == true", timeout: 10)
        dismiss.click()
        wait(element("error-message"), predicate: "exists == false", timeout: 10)

        // The real chooser must refuse a new package while the old Quit still owns cleanup.
        try choosePackage(fixtures.valid)
        wait(element("error-message"), predicate: "exists == true", timeout: 10)
        XCTAssertEqual(try value("error-message"), "The app is quitting. Cancel quitting before choosing another package.")
        XCTAssertEqual(try value("package-is-terminating"), "true")
        XCTAssertEqual(try value("package-reader-choice-returned"), "false")
        XCTAssertEqual(try value("package-active-operations"), "1")
        XCTAssertEqual(try value("package-reader-directory"), readerDirectory)
        try requirePrivateDirectory(readerDirectory)
        attachState("package-choice-denied-during-reader-cleanup")
        wait(dismiss, predicate: "exists == true AND hittable == true", timeout: 10)
        dismiss.click()
        wait(element("error-message"), predicate: "exists == false", timeout: 10)

        let releaseReader = element("package-reader-release")
        reveal(releaseReader)
        XCTAssertTrue(releaseReader.isEnabled)
        releaseReader.click()
        wait(element("package-reader-phase"), predicate: "value == 'validation-returned'", timeout: 120)
        wait(element("package-reader-choice-returned"), predicate: "value == 'true'", timeout: 10)
        wait(element("package-active-operations"), predicate: "value == '0'", timeout: 10)
        wait(element("package-is-terminating"), predicate: "value == 'false'", timeout: 10)
        XCTAssertEqual(try value("package-reader-cancelled"), "true")
        XCTAssertEqual(try value("package-reader-signature-status"), "valid")
        XCTAssertEqual(try value("package-prepared-id"), "none")
        XCTAssertEqual(try value("package-prepared-directory"), "none")
        XCTAssertEqual(try value("package-original-url"), "none")
        XCTAssertFalse(element("error-message").exists)
        XCTAssertFalse(element("install-package").exists)
        try requireAbsent(readerDirectory)
        attachState("package-reader-returned-and-cleaned")

        try choosePackage(fixtures.valid)
        let readerRecovery = try requirePreparation(original: fixtures.valid, activeOperations: 0)
        XCTAssertNotEqual(readerRecovery.directory, readerDirectory)
        XCTAssertEqual(try value("package-is-terminating"), "false")
        attachState("package-recovered-after-quit-timeout")
        app.typeKey("q", modifierFlags: [.command])
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Normal Quit must recover after the incomplete reader finishes")
        try requireAbsent(readerDirectory)
        try requireAbsent(readerRecovery.directory)
        let data = try JSONEncoder().encode(CleanupReceipt(preparedDirectories: [first.directory, recovered.directory, late.directory, current.directory, readerDirectory, readerRecovery.directory]))
        attach(String(decoding: data, as: UTF8.self), name: "package-cleanup-receipt")
    }

    private func launchOwnedApplication(_ app: XCUIApplication, fixtures: Fixtures) {
        app.launchArguments = ["-ui-testing", "YES", "-demo-mode", "NO", "-workspace", "installApp",
                               "-package-acceptance-simulator", fixtures.simulator,
                               "-package-acceptance-owner", fixtures.owner,
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["IDT_RESTORE_HELPERS"] = ""
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertFalse(element("demo-banner").exists)
        let readiness = element("package-target-readiness")
        attachReadiness("package-discovery-before-wait")
        wait(readiness, predicate: "exists == true AND value == 'ready'", timeout: 75)
        attachReadiness("package-owned-target-ready")
        let picker = element("target-picker")
        wait(picker, predicate: "exists == true AND hittable == true", timeout: 10)
        picker.click()
        let simulator = element("target-simulator-\(fixtures.simulator)")
        wait(simulator, predicate: "exists == true AND hittable == true", timeout: 10)
        simulator.click()
        wait(simulator, predicate: "exists == false", timeout: 10)
        wait(picker, predicate: "exists == true AND hittable == true", timeout: 10)
        XCTAssertFalse(element("install-package").exists)
    }

    /// Uses the identifiers recorded from the real AppKit panel on the hosted Mac.
    private func choosePackage(_ path: String) throws {
        let choose = element("choose-package")
        reveal(choose)
        choose.click()
        let panel = element("open-panel")
        wait(panel, predicate: "exists == true", timeout: 10)
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let goToSheets = application!.sheets.matching(identifier: "GoToWindow")
        let goTo = goToSheets.element
        wait(goTo, predicate: "exists == true", timeout: 5)
        XCTAssertEqual(goToSheets.count, 1, "The native Go to Folder sheet must resolve uniquely from the application")
        let fields = application!.textFields.matching(identifier: "PathTextField")
        let field = fields.element
        wait(field, predicate: "exists == true AND hittable == true", timeout: 5)
        XCTAssertEqual(fields.count, 1, "The native Go to Folder field must resolve uniquely from the application")
        field.click()
        field.typeKey("a", modifierFlags: [.command])
        field.typeText(path)
        XCTAssertEqual(try XCTUnwrap(field.value as? String), path)
        field.typeKey(.return, modifierFlags: [])
        wait(application!.textFields["PathTextField"], predicate: "exists == false", timeout: 5)
        let openButtons = application!.buttons.matching(identifier: "OKButton")
        let open = openButtons.element
        wait(open, predicate: "exists == true AND enabled == true AND hittable == true", timeout: 10)
        XCTAssertEqual(openButtons.count, 1, "The native Open button must resolve uniquely from the application")
        XCTAssertEqual(try value("package-target-readiness"), "ready", "Choosing a local package must preserve the owned simulator target")
        attach(application!.debugDescription, name: "package-native-selected-input")
        open.click()
        wait(panel, predicate: "exists == false", timeout: 10)
    }

    private func element(_ identifier: String) -> XCUIElement {
        application!.descendants(matching: .any)[identifier]
    }

    private func value(_ identifier: String) throws -> String {
        try XCTUnwrap(element(identifier).value as? String, "The identified native control must expose a String value: \(identifier)")
    }

    private func wait(_ control: XCUIElement, predicate: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: control)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed, let application, application.state != .notRunning {
            attachReadiness("package-wait-readiness")
            attach(application.debugDescription, name: "package-wait-native-hierarchy")
        }
        XCTAssertEqual(result, .completed,
                       "The native control did not satisfy \(predicate): \(control)")
    }

    private func attachReadiness(_ name: String) {
        let summary = element("connection-summary")
        let label = summary.exists ? String(summary.label.prefix(4096)) : "<absent>"
        let summaryValue = diagnosticValue("connection-summary")
        let readiness = diagnosticValue("package-target-readiness")
        let status = diagnosticValue("package-discovery-status")
        attach("label: \(label)\nvalue: \(summaryValue)\nowned-target: \(readiness)\nsource-status: \(status)", name: name)
    }

    private func diagnosticValue(_ identifier: String) -> String {
        let control = element(identifier)
        guard control.exists else { return "<absent>" }
        guard let value = control.value as? String else { return "<no String value>" }
        return String(value.prefix(4096))
    }

    private func requirePreparation(original: String, activeOperations: Int) throws -> Preparation {
        wait(element("package-prepared-id"), predicate: "exists == true AND value != 'none'", timeout: 120)
        wait(element("package-active-operations"), predicate: "value == '\(activeOperations)'", timeout: 10)
        wait(element("install-package"), predicate: "exists == true AND enabled == true", timeout: 10)
        XCTAssertFalse(element("package-inspection-running").exists)
        XCTAssertFalse(element("error-message").exists)
        XCTAssertEqual(try value("package-original-url"), original)
        let directory = try value("package-prepared-directory")
        let identifier = try value("package-prepared-id")
        XCTAssertEqual(UUID(uuidString: identifier)?.uuidString, identifier)
        try requirePrivateDirectory(directory)
        try requirePackageCopy(directory: directory, original: original)
        return Preparation(directory: directory, identifier: identifier)
    }

    private func heldPreparation(original: String) throws -> Preparation {
        XCTAssertEqual(try value("package-held-original-url"), original)
        let directory = try value("package-held-directory")
        let identifier = try value("package-held-id")
        XCTAssertEqual(UUID(uuidString: identifier)?.uuidString, identifier)
        try requirePrivateDirectory(directory)
        try requirePackageCopy(directory: directory, original: original)
        return Preparation(directory: directory, identifier: identifier)
    }

    private func requirePackageCopy(directory: String, original: String) throws {
        let copy = URL(fileURLWithPath: directory).appendingPathComponent(URL(fileURLWithPath: original).lastPathComponent)
        var metadata = stat()
        XCTAssertEqual(lstat(copy.path, &metadata), 0, "The actual private package copy must exist while the app is alive")
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFDIR)
        XCTAssertNotEqual(copy.path, original)
    }

    private func requirePrivateDirectory(_ path: String) throws {
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        XCTAssertTrue(path.hasPrefix("/"))
        XCTAssertTrue(directory.lastPathComponent.hasPrefix("idt-prepared-app."))
        var metadata = stat()
        XCTAssertEqual(lstat(directory.path, &metadata), 0, "The recorded private preparation must actually exist before Quit")
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(metadata.st_uid, getuid())
        XCTAssertEqual(metadata.st_mode & 0o777, 0o700)
    }

    private func requireAbsent(_ path: String) throws {
        var metadata = stat()
        let result = lstat(path, &metadata)
        let code = errno
        XCTAssertEqual(result, -1, "The exact recorded preparation must have been removed")
        XCTAssertEqual(code, ENOENT, "Absence must be verified without masking an access failure")
    }

    private func reveal(_ control: XCUIElement) {
        let app = application!
        let pages = app.scrollViews.containing(.button, identifier: "choose-package")
        XCTAssertEqual(pages.count, 1, "Package controls must belong to one identified page scroll view")
        let page = pages.element
        for _ in 0..<8 {
            if control.isHittable { break }
            let viewport = page.frame
            let frame = control.frame
            XCTAssertGreaterThan(viewport.height, 0)
            XCTAssertGreaterThan(frame.height, 0)
            let deltaY = frame.maxY > viewport.maxY ? -viewport.height / 2 : viewport.height / 2
            page.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        wait(control, predicate: "exists == true AND hittable == true", timeout: 5)
    }

    private func attachState(_ name: String) {
        let app = application!
        attach(app.debugDescription, name: name)
        let screenshot = XCTAttachment(screenshot: app.windows["main-AppWindow-1"].screenshot())
        screenshot.name = name + "-window"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func attach(_ text: String, name: String) {
        let attachment = XCTAttachment(string: String(text.prefix(120_000)))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
