import XCTest

/// Explicit hosted acceptance keeps native file panels and termination out of ordinary runs.
@MainActor
final class PackageInspectionUITests: XCTestCase {
    private var application: XCUIApplication?

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IDT_PACKAGE_UI_TESTS"] == "1",
                          "Requires the explicit hosted package inspection acceptance opt-in.")
    }

    override func tearDown() async throws {
        application?.terminate()
    }

    func testPackageInspectionRecoveryAndNormalQuitCleanup() throws {
        let app = XCUIApplication()
        application = app
        app.launchArguments = ["-ui-testing", "YES", "-demo-mode", "NO", "-workspace", "installApp",
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["IDT_RESTORE_HELPERS"] = ""
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let choose = app.buttons["choose-package"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        XCTAssertTrue(choose.isHittable)
        choose.click()
        attach(app.debugDescription, name: "package-before-native-panel-lookup")
        let panel = app.descendants(matching: .any)["open-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        attach(app.debugDescription, name: "package-native-open-panel")
        let fields = app.textFields.count
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let fieldAppeared = app.textFields.element(boundBy: fields).waitForExistence(timeout: 5)
        attach(app.debugDescription, name: "package-native-go-to-panel")
        XCTAssertTrue(fieldAppeared)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        app.typeKey("q", modifierFlags: [.command])
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Normal Command-Q must exit the test app")
    }

    private func attach(_ text: String, name: String) {
        let attachment = XCTAttachment(string: String(text.prefix(120_000)))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
