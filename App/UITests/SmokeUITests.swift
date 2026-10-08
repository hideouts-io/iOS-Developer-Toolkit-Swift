import XCTest

/// GUI smoke tests. The app runs with `-ui-testing` (no real device discovery) and
/// `-demo-mode` (a clearly labelled simulated iPhone), so results are deterministic.
@MainActor
final class SmokeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "YES", "-demo-mode", "YES", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "The test app must be in the foreground before native UI interaction")
    }

    override func tearDown() async throws {
        app.terminate()
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openWorkspace(_ identifier: String) {
        let item = app.descendants(matching: .any)["sidebar-\(identifier)"]
        guard item.waitForExistence(timeout: 5) else {
            XCTFail("Missing sidebar item \(identifier)")
            return
        }
        if identifier != "activity" {
            let sidebar = app.descendants(matching: .any)["workspace-sidebar"]
            guard sidebar.waitForExistence(timeout: 5) else {
                XCTFail("Missing workspace sidebar")
                return
            }
            for _ in 0..<8 {
                let viewport = sidebar.frame
                let itemFrame = item.frame
                guard viewport.width > 0, viewport.height > 0 else {
                    XCTFail("Workspace sidebar has no visible viewport: \(viewport)")
                    return
                }
                let hasItemFrame: Bool = itemFrame.width > 0 && itemFrame.height > 0
                if hasItemFrame && viewport.contains(itemFrame) { break }
                // Native Lists give unloaded offscreen rows a zero-sized frame. Scrolling
                // toward their reported vertical position loads their actual row geometry.
                if hasItemFrame && (itemFrame.minX < viewport.minX || itemFrame.maxX > viewport.maxX) {
                    XCTFail("Sidebar item \(identifier) does not fit its viewport: \(itemFrame) in \(viewport)")
                    return
                }
                let deltaY: CGFloat = itemFrame.maxY > viewport.maxY
                    ? -(itemFrame.maxY - viewport.maxY + itemFrame.height)
                    : viewport.minY - itemFrame.minY + itemFrame.height
                sidebar.scroll(byDeltaX: 0, deltaY: deltaY)
            }
            guard item.frame.width > 0, item.frame.height > 0,
                  sidebar.frame.contains(item.frame) else {
                XCTFail("Sidebar item \(identifier) remains outside its viewport after eight scrolls: \(item.frame) in \(sidebar.frame)")
                return
            }
        }
        guard item.isHittable else {
            attachScreenshot("unreachable-sidebar-\(identifier)")
            XCTFail("Sidebar item \(identifier) is not reachable")
            return
        }
        item.click()
        XCTAssertTrue(app.descendants(matching: .any)["workspace-\(identifier)"].waitForExistence(timeout: 5), "Missing content for \(identifier)")
        XCTAssertFalse(app.buttons["running-operations"].exists, "Opening \(identifier) must not start an operation")
    }

    private func openSection(_ sectionIdentifier: String, contentIdentifier: String) {
        let section = app.descendants(matching: .any)[sectionIdentifier]
        XCTAssertTrue(section.waitForExistence(timeout: 5), "Missing section \(sectionIdentifier)")
        section.click()
        XCTAssertTrue(app.descendants(matching: .any)[contentIdentifier].waitForExistence(timeout: 5), "Missing content for \(sectionIdentifier)")
        XCTAssertFalse(app.buttons["running-operations"].exists, "Opening \(sectionIdentifier) must not start an operation")
    }

    func testWindowOpensAtUsableSizeOnALaptopDisplay() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let frame = window.frame
        XCTAssertGreaterThanOrEqual(frame.width, 900, "Window too narrow: \(frame)")
        XCTAssertGreaterThanOrEqual(frame.height, 560, "Window too short: \(frame)")
        // A 13-inch MacBook Air is 1280×800 points (minus menu bar and Dock).
        XCTAssertLessThanOrEqual(frame.width, 1280, "Window wider than a laptop display: \(frame)")
        XCTAssertLessThanOrEqual(frame.height, 760, "Window taller than a laptop display: \(frame)")
        attachScreenshot("overview")
    }

    func testDemoModeIsClearlyLabelled() throws {
        XCTAssertTrue(app.descendants(matching: .any)["demo-banner"].waitForExistence(timeout: 10))
    }

    func testEveryWorkspaceOpens() throws {
        let workspaces = ["overview", "device", "readiness", "location", "liveLogs", "actions", "apps", "backup", "installApp", "evidence", "externalTools", "help", "safety", "firmware", "securityAnalysis"]
        for workspace in workspaces {
            openWorkspace(workspace)
            attachScreenshot(workspace)
        }
        XCTAssertFalse(app.descendants(matching: .any)["sidebar-developerImage"].exists, "Developer Image belongs inside Device & DDI")
        openWorkspace("activity")
        XCTAssertTrue(app.descendants(matching: .any)["session-activity-empty"].waitForExistence(timeout: 5), "Navigation must not execute a journalled operation")
    }

    func testGroupedWorkspacesExposeTheirExistingSections() throws {
        openWorkspace("device")
        XCTAssertTrue(app.descendants(matching: .any)["device-sections"].waitForExistence(timeout: 5))
        openSection("device-section-developerImage", contentIdentifier: "workspace-developerImage")
        XCTAssertFalse(app.buttons["mount-ddi"].isEnabled, "Mounting must remain disabled in Demo Mode")
        openSection("device-section-device", contentIdentifier: "workspace-device")

        openWorkspace("readiness")
        XCTAssertTrue(app.descendants(matching: .any)["capability-sections"].waitForExistence(timeout: 5))
        openSection("capability-section-compatibility", contentIdentifier: "capability-content-compatibility")
        openSection("capability-section-current", contentIdentifier: "capability-content-current")

        openWorkspace("backup")
        XCTAssertTrue(app.descendants(matching: .any)["backup-sections"].waitForExistence(timeout: 5))
        for section in ["ufade", "mvt", "mobileBackup2"] {
            openSection("backup-section-\(section)", contentIdentifier: "backup-content-\(section)")
        }
        openWorkspace("activity")
        XCTAssertTrue(app.descendants(matching: .any)["session-activity-empty"].waitForExistence(timeout: 5))
    }

    func testLegacyDeveloperImageShortcutOpensItsGroupedRoute() throws {
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["workspace-developerImage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["sidebar-device"].isSelected, "Device & DDI stays selected for the legacy Developer Image route")
        XCTAssertTrue(app.descendants(matching: .any)["device-section-developerImage"].exists)
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["workspace-device"].waitForExistence(timeout: 5))
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        XCTAssertTrue(app.descendants(matching: .any)["workspace-readiness"].waitForExistence(timeout: 5))
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        XCTAssertTrue(app.descendants(matching: .any)["workspace-device"].waitForExistence(timeout: 5))
    }

    func testNavigationUtilitiesAreReachable() throws {
        for identifier in ["action-palette", "sidebar-activity", "export-workspace", "import-workspace", "target-picker", "retry-scan", "workspace-controls"] {
            let control = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing navigation control \(identifier)")
            XCTAssertTrue(control.isHittable, "Navigation control \(identifier) is not reachable")
        }
        app.descendants(matching: .any)["workspace-controls"].click()
        for identifier in ["reconnect-guide", "demo-mode-toggle", "keyboard-help", "create-support-bundle"] {
            XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 5), "Missing workspace menu control \(identifier)")
        }
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["action-palette"].click()
        XCTAssertTrue(app.textFields["palette-search"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        openWorkspace("activity")
        XCTAssertTrue(app.descendants(matching: .any)["session-activity-empty"].waitForExistence(timeout: 5))
    }

    func testSecurityAnalysisRequiresEvidenceAndExposesEverySection() throws {
        app.descendants(matching: .any)["sidebar-securityAnalysis"].click()
        let sections = app.descendants(matching: .any)["security-sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["security-section-analyze"].click()
        let run = app.buttons["security-run"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        XCTAssertFalse(run.isEnabled, "Security Analysis must require explicit evidence selection")
        app.descendants(matching: .any)["security-section-intelligence"].click()
        XCTAssertTrue(app.buttons["security-update-intelligence"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["security-section-reports"].click()
        XCTAssertTrue(app.staticTexts["security-reports-empty"].waitForExistence(timeout: 5))
        attachScreenshot("security-analysis")
    }

    func testDemoActionsAreBlockedWithExplanation() throws {
        app.descendants(matching: .any)["sidebar-actions"].click()
        let action = app.descendants(matching: .any)["action-battery"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.click()
        let run = app.buttons["run-action"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        XCTAssertFalse(run.isEnabled, "Actions must be disabled in Demo Mode")
        attachScreenshot("action-detail")
    }

    func testCommandCategoriesExposeExistingActionsWithoutExecuting() throws {
        openWorkspace("actions")
        let categories: [(key: String, action: String)] = [
            ("device-basics", "battery"),
            ("apps-files", "app-query"),
            ("logging-capture", "packet-capture"),
            ("developer-dvt", "screenshot"),
            ("web-discovery", "web-tabs"),
            ("device-actions", "launch-app"),
            ("simulator", "sim-boot"),
        ]
        for category in categories {
            let picker = app.descendants(matching: .any)["command-categories"]
            guard picker.waitForExistence(timeout: 5) else {
                XCTFail("Missing Command Center category picker")
                return
            }
            picker.click()
            let option = app.descendants(matching: .any)["command-category-\(category.key)"]
            guard option.waitForExistence(timeout: 5) else {
                XCTFail("Missing command category \(category.key)")
                return
            }
            option.click()
            let action = app.descendants(matching: .any)["action-\(category.action)"]
            guard action.waitForExistence(timeout: 5) else {
                XCTFail("Command category \(category.key) does not expose \(category.action)")
                return
            }
            let unrelatedAction: String = category.key == "device-basics" ? "sim-boot" : "battery"
            XCTAssertFalse(app.descendants(matching: .any)["action-\(unrelatedAction)"].exists, "Command category \(category.key) must filter unrelated actions")
            XCTAssertFalse(app.buttons["running-operations"].exists, "Choosing \(category.key) must not execute an action")
        }
    }

    func testPaletteReopensTheSameActionAfterChangingItsCategory() throws {
        openWorkspace("actions")
        let battery = app.descendants(matching: .any)["action-battery"]
        guard battery.waitForExistence(timeout: 5) else {
            XCTFail("Missing battery action in Command Center")
            return
        }
        battery.click()
        let picker = app.descendants(matching: .any)["command-categories"]
        guard picker.waitForExistence(timeout: 5) else {
            XCTFail("Missing Command Center category picker")
            return
        }
        picker.click()
        let captureCategory = app.descendants(matching: .any)["command-category-logging-capture"]
        guard captureCategory.waitForExistence(timeout: 5) else {
            XCTFail("Missing logging and capture category")
            return
        }
        captureCategory.click()
        XCTAssertFalse(battery.exists, "The logging filter must hide the battery action")
        XCTAssertTrue(app.buttons["run-action"].exists, "Filtering must retain the selected battery action's detail")

        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["palette-search"]
        guard search.waitForExistence(timeout: 5) else {
            XCTFail("Action Palette search did not open")
            return
        }
        search.typeText("Battery snapshot\r")
        XCTAssertTrue(battery.waitForExistence(timeout: 5), "Palette navigation must reveal an action even when its ID is already selected")
        let run = app.buttons["run-action"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        XCTAssertFalse(run.isEnabled, "Palette navigation must preserve the Demo Mode execution block")
        XCTAssertFalse(app.buttons["running-operations"].exists, "Palette navigation must not execute the action")
    }

    func testDeveloperImageCardShowsStateAndBlocksDemoMount() throws {
        // The Device page summarizes the state and opens the Developer Image page.
        app.descendants(matching: .any)["sidebar-device"].click()
        let open = app.buttons["open-developer-image"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "The Device page does not link to the Developer Image page")
        open.click()
        XCTAssertTrue(app.descendants(matching: .any)["ddi-state"].waitForExistence(timeout: 10), "The developer image state is not shown")
        XCTAssertTrue(app.descendants(matching: .any)["ddi-mechanism"].exists, "The mount method choice is missing")
        let mount = app.buttons["mount-ddi"]
        XCTAssertTrue(mount.waitForExistence(timeout: 5))
        XCTAssertFalse(mount.isEnabled, "Mounting must be disabled in Demo Mode")
        attachScreenshot("developer-image")
    }

    func testFirmwareRequiresValidationAndBlocksDemoInstall() throws {
        let sidebar = app.descendants(matching: .any)["sidebar-firmware"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        sidebar.click()
        let install = app.buttons["firmware.install"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        XCTAssertFalse(install.isEnabled, "A demo device cannot supply a validated install plan")
        XCTAssertTrue(app.descendants(matching: .any)["firmware.readiness"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["firmware.file"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["firmware.mode"].exists)
        let watchRecovery = app.descendants(matching: .any)["firmware.watch-recovery"]
        XCTAssertTrue(watchRecovery.waitForExistence(timeout: 5))
        XCTAssertFalse(watchRecovery.isEnabled, "Recovery probes must be disabled in Demo Mode")
        attachScreenshot("firmware-readiness")
    }

    func testCommandPaletteNavigates() throws {
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["palette-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Location Lab\r")
        XCTAssertTrue(app.textFields["latitude-field"].waitForExistence(timeout: 5))
        attachScreenshot("location-lab")
    }

    func testLocationLabValidatesInput() throws {
        app.descendants(matching: .any)["sidebar-location"].click()
        let latitude = app.textFields["latitude-field"]
        XCTAssertTrue(latitude.waitForExistence(timeout: 5))
        latitude.doubleClick()
        latitude.typeKey("a", modifierFlags: .command)
        latitude.typeText("123")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'latitude from -90 to 90'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["set-location"].isEnabled)
    }

    func testMinimumSizeKeepsControlsReachable() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        // Drag the bottom-right corner inward as far as it goes.
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)))
        XCTAssertGreaterThanOrEqual(window.frame.width, 899)
        XCTAssertGreaterThanOrEqual(window.frame.height, 559)
        app.descendants(matching: .any)["sidebar-location"].click()
        XCTAssertTrue(app.buttons["set-location"].waitForExistence(timeout: 5))
        attachScreenshot("minimum-size-location")
    }
}
