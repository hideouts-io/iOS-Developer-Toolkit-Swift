import Foundation
import XCTest

/// Native acceptance on two task-owned simulators. The explicit opt-in keeps ordinary local
/// UI smoke tests from creating or changing simulators; CI enables it in a separate step.
@MainActor
final class SimulatorInventoryUITests: XCTestCase {
    private var app: XCUIApplication?
    private let aOnly = "io.hideouts.idt.inventory.a"
    private let bOnly = "io.hideouts.idt.inventory.b"
    private let shared = "io.hideouts.idt.inventory.shared"

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IDT_INVENTORY_UI_TESTS"] == "1",
                          "Requires the explicit two-owned-simulator native acceptance opt-in.")
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    func testInventoryOwnershipAcrossTwoSimulatorsAndDeliveredLateResult() throws {
        let manifest = try XCTUnwrap(ProcessInfo.processInfo.environment["IDT_INVENTORY_MANIFEST"],
                                         "CI must supply the two owned simulator fixtures")
        guard manifest.utf8.count <= 4096 else {
            throw InventoryFixtureFailure(message: "The inventory fixture manifest exceeds 4 KiB.")
        }
        let fixtures = try JSONDecoder().decode(InventoryFixtures.self, from: Data(manifest.utf8))
        guard let first = UUID(uuidString: fixtures.first), let second = UUID(uuidString: fixtures.second),
              UUID(uuidString: fixtures.owner)?.uuidString == fixtures.owner, first != second,
              first.uuidString == fixtures.first, second.uuidString == fixtures.second else {
            throw InventoryFixtureFailure(message: "The inventory fixture manifest requires two distinct canonical UUIDs and an owner UUID.")
        }
        let a = fixtures.first
        let b = fixtures.second

        let application = XCUIApplication()
        app = application
        application.launchArguments = ["-ui-testing", "YES", "-demo-mode", "NO",
                                       "-inventory-acceptance-a", a, "-inventory-acceptance-b", b,
                                       "-inventory-acceptance-owner", fixtures.owner,
                                       "-workspace", "apps", "-ApplePersistenceIgnoreState", "YES"]
        application.launchEnvironment["IDT_RESTORE_HELPERS"] = ""
        application.launch()
        XCTAssertTrue(application.wait(for: .runningForeground, timeout: 10))
        XCTAssertFalse(element("demo-banner").exists)

        // The discovery command has a 60-second deadline plus process-exit cleanup.
        // Observe its completion with the menu closed, then require a healthy result;
        // an open native menu can retain the initial, not-yet-checked item snapshot.
        let discovery = element("connection-summary")
        wait(discovery, predicate: "exists == true AND NOT (label CONTAINS 'Simulators: Not checked yet')", timeout: 75)
        XCTAssertNotNil(discovery.label.range(of: "Simulators: [1-9][0-9]* devices", options: .regularExpression),
                        "Initial simulator discovery must succeed before opening the target menu: \(discovery.label)")

        selectSimulator(a)
        loadInventory(containing: aOnly)
        selectApp(aOnly)
        wait(element("apps-launch"), predicate: "exists == true AND enabled == true", timeout: 10)

        selectSimulator(b)
        wait(element("apps-launch"), predicate: "exists == false", timeout: 10)
        XCTAssertFalse(element("apps-remove").exists, "Changing target must clear row selection")
        wait(element("apps-stale-inventory"), predicate: "exists == true", timeout: 10)
        selectApp(aOnly)
        wait(element("apps-launch"), predicate: "exists == true AND enabled == false", timeout: 10)
        XCTAssertFalse(element("apps-remove").isEnabled)
        assertStaleContextActionsAreDisabled(row: element("installed-app-\(aOnly)"))
        XCTAssertFalse(element("running-operations").exists, "Blocked controls must start no operation")

        loadInventory(containing: bOnly)
        XCTAssertFalse(element("installed-app-\(aOnly)").exists)
        XCTAssertFalse(element("apps-stale-inventory").exists)
        selectApp(shared)
        wait(element("apps-remove"), predicate: "exists == true AND enabled == true", timeout: 10)
        element("apps-remove").click()
        confirmRemoval(on: b)
        wait(element("installed-app-\(shared)"), predicate: "exists == false", timeout: 120)
        wait(element("running-operations"), predicate: "exists == false", timeout: 120)
        // Verify isolation through the production app's real inventories, without spawning
        // tools from the sandboxed UI-test runner. CI owns fixture provisioning and cleanup.
        selectSimulator(a)
        loadInventory(containing: aOnly)
        XCTAssertTrue(element("installed-app-\(shared)").exists, "A must retain the shared fixture")
        selectSimulator(b)
        loadInventory(containing: bOnly)
        XCTAssertFalse(element("installed-app-\(shared)").exists, "The confirmed removal must affect B")

        // The runner first captures a genuine successful A response, then holds it past
        // cancellation. Releasing it after B loads proves rejection of an actually delivered
        // obsolete result, rather than merely proving that cancellation prevented delivery.
        selectSimulator(a)
        loadInventory(containing: aOnly)
        element("inventory-gate-arm").click()
        wait(element("inventory-gate-state"), predicate: "value == 'armed'", timeout: 10)
        element("load-apps").click()
        wait(element("inventory-gate-state"), predicate: "value == 'held'", timeout: 120)
        selectSimulator(b)
        loadInventory(containing: bOnly)
        selectApp(bOnly)
        wait(element("apps-launch"), predicate: "exists == true AND enabled == true", timeout: 10)
        let currentSource = try XCTUnwrap(element("apps-inventory-source").value as? String)
        XCTAssertFalse(currentSource.isEmpty, "The inventory provenance must expose a readable native value")
        element("inventory-gate-release").click()
        wait(element("inventory-gate-state"), predicate: "value == 'delivered'", timeout: 10)
        wait(element("running-operations"), predicate: "exists == false", timeout: 30)
        XCTAssertEqual(application.sheets.count, 0, "A late reply must parse successfully without presenting an error")
        XCTAssertEqual(application.alerts.count, 0)
        XCTAssertTrue(element("installed-app-\(bOnly)").exists)
        XCTAssertFalse(element("installed-app-\(aOnly)").exists)
        XCTAssertFalse(element("apps-stale-inventory").exists)
        XCTAssertEqual(element("apps-inventory-source").value as? String, currentSource)
        XCTAssertTrue(element("apps-launch").isEnabled, "Late A must preserve B's selected valid row")

        // A modal confirmation cannot assume that the target picker remains reachable.
        // Real loss of owned A exercises the observed target-change dismissal path instead.
        selectSimulator(a)
        loadInventory(containing: aOnly)
        selectApp(shared)
        element("apps-remove").click()
        wait(element("confirm-button"), predicate: "exists == true", timeout: 10)
        XCTAssertEqual(application.sheets.count, 1)
        XCTAssertFalse(element("confirm-button").isEnabled)
        let deleteOwnedA = element("inventory-delete-owned-a")
        wait(deleteOwnedA, predicate: "exists == true AND enabled == true", timeout: 10)
        deleteOwnedA.click()
        wait(element("confirm-button"), predicate: "exists == false", timeout: 180)
        selectSimulator(b)
        loadInventory(containing: bOnly)
        wait(element("running-operations"), predicate: "exists == false", timeout: 120)
        XCTAssertEqual(application.sheets.count, 0, "Owned target loss must complete without an error sheet")
        XCTAssertEqual(application.alerts.count, 0)
        XCTAssertFalse(element("installed-app-\(shared)").exists)
        print("[inventory acceptance] stale controls, B-only removal, delivered late-A rejection, and target-loss confirmation dismissal passed")
    }

    private func element(_ identifier: String) -> XCUIElement {
        guard let app else { preconditionFailure("The acceptance app has not launched") }
        return app.descendants(matching: .any)[identifier]
    }

    private func wait(_ element: XCUIElement, predicate: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed {
            let hierarchy = app.map { String($0.debugDescription.prefix(64_000)) } ?? "The acceptance app has not launched."
            let attachment = XCTAttachment(string: hierarchy)
            attachment.name = "inventory-accessibility-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(result, .completed,
                       "The native accessibility condition did not settle: \(predicate). Inspect the attached hierarchy and preceding element query.")
    }

    private func selectSimulator(_ identifier: String) {
        let picker = element("target-picker")
        wait(picker, predicate: "exists == true AND hittable == true", timeout: 30)
        picker.click()
        let target = element("target-simulator-\(identifier)")
        wait(target, predicate: "exists == true AND hittable == true", timeout: 30)
        target.click()
        wait(target, predicate: "exists == false", timeout: 10)
    }

    private func selectApp(_ bundle: String) {
        let rows = element("installed-apps-table").outlineRows.containing(.any, identifier: "installed-app-\(bundle)")
        XCTAssertEqual(rows.count, 1, "The stable app identifier must resolve to one native outline row")
        let row = rows.element
        wait(row, predicate: "exists == true AND hittable == true", timeout: 10)
        row.click()
        wait(row, predicate: "selected == true", timeout: 10)
    }

    private func loadInventory(containing bundle: String) {
        let load = element("load-apps")
        wait(load, predicate: "exists == true AND enabled == true", timeout: 10)
        load.click()
        wait(element("installed-app-\(bundle)"), predicate: "exists == true AND hittable == true", timeout: 120)
        wait(load, predicate: "enabled == true", timeout: 120)
        XCTAssertFalse(element("apps-stale-inventory").exists)
    }

    private func assertStaleContextActionsAreDisabled(row: XCUIElement) {
        row.rightClick()
        let menu = element("installed-apps-table").menus.element
        wait(menu, predicate: "exists == true", timeout: 10)
        // As in the Demo smoke test, SwiftUI omits identifiers on disabled native menu items.
        // Assert the complete action order inside the table identified above; no text clicks.
        let actions = menu.menuItems.matching(NSPredicate(format: "title != ''"))
        XCTAssertEqual(actions.count, 3)
        XCTAssertTrue(actions.element(boundBy: 0).isEnabled)
        XCTAssertFalse(actions.element(boundBy: 1).isEnabled)
        XCTAssertFalse(actions.element(boundBy: 2).isEnabled)
        app?.typeKey(.escape, modifierFlags: [])
    }

    private func confirmRemoval(on identifier: String) {
        wait(element("confirm-button"), predicate: "exists == true", timeout: 10)
        XCTAssertEqual(app?.sheets.count, 1)
        let field = element("confirmation-field")
        wait(field, predicate: "exists == true AND hittable == true", timeout: 10)
        field.click()
        field.typeText("IRREVERSIBLE \(identifier.replacingOccurrences(of: "-", with: "").suffix(6))")
        element("confirmation-backup-acknowledgement").click()
        wait(element("confirm-button"), predicate: "enabled == true", timeout: 10)
        element("confirm-button").click()
        wait(element("confirm-button"), predicate: "exists == false", timeout: 10)
    }

    private struct InventoryFixtures: Decodable {
        let first: String
        let second: String
        let owner: String
    }

    private struct InventoryFixtureFailure: Error {
        let message: String
    }
}
