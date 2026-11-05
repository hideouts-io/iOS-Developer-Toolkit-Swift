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
        let invalid: String

        static func load(environment: [String: String]) throws -> Fixtures {
            let simulator = try XCTUnwrap(environment["IDT_PACKAGE_FIXTURE_SIMULATOR"])
            let owner = try XCTUnwrap(environment["IDT_PACKAGE_FIXTURE_OWNER"])
            let directory = try XCTUnwrap(environment["IDT_PACKAGE_FIXTURE_DIRECTORY"])
            let valid = try XCTUnwrap(environment["IDT_PACKAGE_FIXTURE_VALID"])
            let invalid = try XCTUnwrap(environment["IDT_PACKAGE_FIXTURE_INVALID"])
            XCTAssertEqual(UUID(uuidString: simulator)?.uuidString, simulator)
            XCTAssertEqual(UUID(uuidString: owner)?.uuidString, owner)
            let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
            XCTAssertTrue(directory.hasPrefix("/"))
            XCTAssertTrue([directory, valid, invalid].allSatisfy { $0.utf8.count <= 4096 && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r") })
            XCTAssertEqual(valid, root.appendingPathComponent("ValidSimulator.app").path)
            XCTAssertEqual(invalid, root.appendingPathComponent("Malformed.ipa").path)
            return Fixtures(simulator: simulator, owner: owner, valid: valid, invalid: invalid)
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
        XCTAssertFalse(element("install-package").exists)

        try choosePackage(fixtures.valid)
        let first = try requirePreparation(original: fixtures.valid)
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
        let recovered = try requirePreparation(original: fixtures.valid)
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

        // Normal Quit exercises AppDelegate's termination reply and production cleanup.
        // terminate() in tearDown is failure cleanup and cannot establish this assertion.
        app.typeKey("q", modifierFlags: [.command])
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Normal Command-Q must exit after removing its idle prepared package")
        try requireAbsent(first.directory)
        try requireAbsent(recovered.directory)
        let data = try JSONEncoder().encode(CleanupReceipt(preparedDirectories: [first.directory, recovered.directory]))
        attach(String(decoding: data, as: UTF8.self), name: "package-cleanup-receipt")
    }

    /// Uses the identifiers recorded from the real AppKit panel on the hosted Mac.
    private func choosePackage(_ path: String) throws {
        let choose = element("choose-package")
        reveal(choose)
        choose.click()
        let panel = element("open-panel")
        wait(panel, predicate: "exists == true", timeout: 10)
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let goTo = panel.descendants(matching: .any)["GoToWindow"]
        wait(goTo, predicate: "exists == true", timeout: 5)
        let field = goTo.textFields["PathTextField"]
        wait(field, predicate: "exists == true AND hittable == true", timeout: 5)
        field.click()
        field.typeKey("a", modifierFlags: [.command])
        field.typeText(path)
        XCTAssertEqual(try XCTUnwrap(field.value as? String), path)
        field.typeKey(.return, modifierFlags: [])
        wait(application!.textFields["PathTextField"], predicate: "exists == false", timeout: 5)
        let open = panel.buttons["OKButton"]
        wait(open, predicate: "exists == true AND enabled == true AND hittable == true", timeout: 10)
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

    private func requirePreparation(original: String) throws -> Preparation {
        wait(element("package-prepared-id"), predicate: "exists == true AND value != 'none'", timeout: 120)
        wait(element("package-active-operations"), predicate: "value == '0'", timeout: 10)
        wait(element("install-package"), predicate: "exists == true AND enabled == true", timeout: 10)
        XCTAssertFalse(element("package-inspection-running").exists)
        XCTAssertFalse(element("error-message").exists)
        XCTAssertEqual(try value("package-original-url"), original)
        let directory = try value("package-prepared-directory")
        let identifier = try value("package-prepared-id")
        XCTAssertEqual(UUID(uuidString: identifier)?.uuidString, identifier)
        try requirePrivateDirectory(directory)
        let copy = URL(fileURLWithPath: directory).appendingPathComponent("ValidSimulator.app")
        var metadata = stat()
        XCTAssertEqual(lstat(copy.path, &metadata), 0, "The actual private package copy must exist while the app is alive")
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFDIR)
        XCTAssertNotEqual(copy.path, original)
        return Preparation(directory: directory, identifier: identifier)
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
