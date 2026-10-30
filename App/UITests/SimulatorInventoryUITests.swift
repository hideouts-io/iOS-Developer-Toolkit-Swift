import DeviceKit
import Foundation
import ToolkitCore
import XCTest

/// Native acceptance on two task-owned simulators. The explicit opt-in keeps ordinary local
/// UI smoke tests from creating or changing simulators; CI enables it in a separate step.
@MainActor
final class SimulatorInventoryUITests: XCTestCase {
    private var app: XCUIApplication?
    private var ownedSimulators: [String] = []
    private var deletedSimulators: Set<String> = []
    private var fixtureDirectory: URL?
    private let runner = ProcessCommandRunner()
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
        let client = SimulatorClient(runner: runner)
        var cleanupFailures: [String] = []
        for identifier in ownedSimulators.reversed() where !deletedSimulators.contains(identifier) {
            do {
                let records = try await client.list()
                if let record = records.first(where: { $0.udid == identifier }), record.state == .booted {
                    try await client.shutdown(record.device.target)
                }
            } catch {
                cleanupFailures.append("Could not shut down an owned inventory simulator: \(error)")
            }
            do {
                _ = try await command(["simctl", "delete", identifier], timeout: 120)
            } catch {
                cleanupFailures.append("Could not delete an owned inventory simulator: \(error)")
            }
        }
        if !ownedSimulators.isEmpty {
            do {
                let remaining = try await client.list()
                if remaining.contains(where: { ownedSimulators.contains($0.udid) }) {
                    cleanupFailures.append("Both owned simulators must be absent after cleanup")
                }
            } catch {
                cleanupFailures.append("Could not independently verify simulator cleanup: \(error)")
            }
        }
        if let fixtureDirectory {
            do { try FileManager.default.removeItem(at: fixtureDirectory) }
            catch { cleanupFailures.append("Could not remove the owned fixture directory: \(error)") }
        }
        XCTAssertTrue(cleanupFailures.isEmpty, cleanupFailures.joined(separator: "\n"))
    }

    func testInventoryOwnershipAcrossTwoSimulatorsAndDeliveredLateResult() async throws {
        let client = SimulatorClient(runner: runner)
        let records = try await client.list()
        let template = try XCTUnwrap(records.first { $0.isAvailable && $0.device.family == .iPhone },
                                    "The runner needs an available iPhone simulator runtime")
        let type = try XCTUnwrap(template.deviceTypeIdentifier)
        let a = try await createSimulator(name: "IDT Inventory A", type: type, runtime: template.runtimeIdentifier)
        let b = try await createSimulator(name: "IDT Inventory B", type: type, runtime: template.runtimeIdentifier)
        let created = try await client.list()
        let targetA = try XCTUnwrap(created.first { $0.udid == a }).device.target
        let targetB = try XCTUnwrap(created.first { $0.udid == b }).device.target
        try await client.boot(targetA)
        try await client.boot(targetB)

        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "inventory-ui")
        fixtureDirectory = directory
        let fixtureA = try await buildFixture(bundle: aOnly, name: "000 Inventory A", in: directory)
        let fixtureB = try await buildFixture(bundle: bOnly, name: "000 Inventory B", in: directory)
        let fixtureShared = try await buildFixture(bundle: shared, name: "001 Inventory Shared", in: directory)
        try await client.install(appAt: fixtureA, on: targetA)
        try await client.install(appAt: fixtureShared, on: targetA)
        try await client.install(appAt: fixtureB, on: targetB)
        try await client.install(appAt: fixtureShared, on: targetB)

        let application = XCUIApplication()
        app = application
        application.launchArguments = ["-ui-testing", "YES", "-demo-mode", "NO",
                                       "-inventory-acceptance-a", a, "-inventory-acceptance-b", b,
                                       "-workspace", "apps", "-ApplePersistenceIgnoreState", "YES"]
        application.launchEnvironment["IDT_RESTORE_HELPERS"] = ""
        application.launch()
        XCTAssertTrue(application.wait(for: .runningForeground, timeout: 10))
        XCTAssertFalse(element("demo-banner").exists)

        selectSimulator(a)
        loadInventory(containing: aOnly)
        element("installed-app-\(aOnly)").click()
        wait(element("apps-launch"), predicate: "exists == true AND enabled == true", timeout: 10)

        selectSimulator(b)
        wait(element("apps-launch"), predicate: "exists == false", timeout: 10)
        XCTAssertFalse(element("apps-remove").exists, "Changing target must clear row selection")
        wait(element("apps-stale-inventory"), predicate: "exists == true", timeout: 10)
        element("installed-app-\(aOnly)").click()
        wait(element("apps-launch"), predicate: "exists == true AND enabled == false", timeout: 10)
        XCTAssertFalse(element("apps-remove").isEnabled)
        assertStaleContextActionsAreDisabled(row: element("installed-app-\(aOnly)"))
        XCTAssertFalse(element("running-operations").exists, "Blocked controls must start no operation")

        loadInventory(containing: bOnly)
        XCTAssertFalse(element("installed-app-\(aOnly)").exists)
        XCTAssertFalse(element("apps-stale-inventory").exists)
        element("installed-app-\(shared)").click()
        wait(element("apps-remove"), predicate: "exists == true AND enabled == true", timeout: 10)
        element("apps-remove").click()
        confirmRemoval(on: targetB)
        wait(element("installed-app-\(shared)"), predicate: "exists == false", timeout: 120)
        wait(element("running-operations"), predicate: "exists == false", timeout: 120)
        let appsA = try await client.apps(targetA)
        let appsB = try await client.apps(targetB)
        XCTAssertTrue(appsA.contains { $0.bundleIdentifier == shared }, "A must retain the shared fixture")
        XCTAssertTrue(appsA.contains { $0.bundleIdentifier == aOnly })
        XCTAssertFalse(appsB.contains { $0.bundleIdentifier == shared }, "The confirmed removal must affect B")
        XCTAssertTrue(appsB.contains { $0.bundleIdentifier == bOnly })

        // The runner first captures a genuine successful A response, then holds it past
        // cancellation. Releasing it after B loads proves rejection of an actually delivered
        // obsolete result, rather than merely proving that cancellation prevented delivery.
        selectSimulator(a)
        loadInventory(containing: aOnly)
        element("inventory-gate-arm").click()
        wait(element("inventory-gate-state"), predicate: "label == 'armed'", timeout: 10)
        element("load-apps").click()
        wait(element("inventory-gate-state"), predicate: "label == 'held'", timeout: 120)
        selectSimulator(b)
        loadInventory(containing: bOnly)
        element("installed-app-\(bOnly)").click()
        wait(element("apps-launch"), predicate: "exists == true AND enabled == true", timeout: 10)
        let currentSource = element("apps-inventory-source").label
        element("inventory-gate-release").click()
        wait(element("inventory-gate-state"), predicate: "label == 'delivered'", timeout: 10)
        wait(element("running-operations"), predicate: "exists == false", timeout: 30)
        XCTAssertEqual(application.sheets.count, 0, "A late reply must parse successfully without presenting an error")
        XCTAssertEqual(application.alerts.count, 0)
        XCTAssertTrue(element("installed-app-\(bOnly)").exists)
        XCTAssertFalse(element("installed-app-\(aOnly)").exists)
        XCTAssertFalse(element("apps-stale-inventory").exists)
        XCTAssertEqual(element("apps-inventory-source").label, currentSource)
        XCTAssertTrue(element("apps-launch").isEnabled, "Late A must preserve B's selected valid row")

        // A modal confirmation cannot assume that the target picker remains reachable.
        // Real loss of owned A exercises the observed target-change dismissal path instead.
        selectSimulator(a)
        loadInventory(containing: aOnly)
        element("installed-app-\(shared)").click()
        element("apps-remove").click()
        wait(element("apps-confirmation"), predicate: "exists == true", timeout: 10)
        XCTAssertFalse(element("confirm-button").isEnabled)
        try await client.shutdown(targetA)
        _ = try await command(["simctl", "delete", a], timeout: 120)
        deletedSimulators.insert(a)
        wait(element("apps-confirmation"), predicate: "exists == false", timeout: 180)
        selectSimulator(b)
        let finalBApps = try await client.apps(targetB)
        XCTAssertTrue(finalBApps.contains { $0.bundleIdentifier == bOnly })
        XCTAssertFalse(finalBApps.contains { $0.bundleIdentifier == shared })
        print("[inventory acceptance] stale controls, B-only removal, delivered late-A rejection, and target-loss confirmation dismissal passed")
    }

    private func element(_ identifier: String) -> XCUIElement {
        guard let app else { preconditionFailure("The acceptance app has not launched") }
        return app.descendants(matching: .any)[identifier]
    }

    private func wait(_ element: XCUIElement, predicate: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Expected \(element.identifier): \(predicate)")
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

    private func confirmRemoval(on target: DeviceTarget) {
        wait(element("apps-confirmation"), predicate: "exists == true", timeout: 10)
        let field = element("confirmation-field")
        field.click()
        field.typeText("IRREVERSIBLE \(target.confirmationSuffix)")
        element("confirmation-backup-acknowledgement").click()
        wait(element("confirm-button"), predicate: "enabled == true", timeout: 10)
        element("confirm-button").click()
        wait(element("apps-confirmation"), predicate: "exists == false", timeout: 10)
    }

    private func createSimulator(name: String, type: String, runtime: String) async throws -> String {
        let result = try await command(["simctl", "create", "\(name) \(UUID().uuidString)", type, runtime], timeout: 120)
        let identifier = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: identifier) else {
            throw ToolkitError(.protocolViolation, message: "simctl create returned no valid simulator identifier.",
                               recovery: nil, technicalDetail: nil)
        }
        ownedSimulators.append(uuid.uuidString)
        return uuid.uuidString
    }

    private func buildFixture(bundle: String, name: String, in directory: URL) async throws -> URL {
        let app = directory.appendingPathComponent("\(bundle).app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("\(bundle).swift")
        try Data("import Foundation\nwhile true { sleep(1) }\n".utf8).write(to: source)
        #if arch(arm64)
        let triple = "arm64-apple-ios17.0-simulator"
        #else
        let triple = "x86_64-apple-ios17.0-simulator"
        #endif
        _ = try await command(["--sdk", "iphonesimulator", "swiftc", "-target", triple,
                               "-o", app.appendingPathComponent("Fixture").path, source.path], timeout: 300)
        let info: PlistValue = [
            "CFBundleIdentifier": .string(bundle), "CFBundleExecutable": "Fixture", "CFBundleName": .string(name),
            "CFBundleDisplayName": .string(name), "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "17.0",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "UIDeviceFamily": [1, 2],
        ]
        try info.encoded(format: .xml).write(to: app.appendingPathComponent("Info.plist"))
        let sign = CommandRequest(executable: try AppleTool.codesign.locate(), arguments: ["--sign", "-", app.path],
                                  timeout: 60, displayName: "sign inventory fixture")
        let signed = try await runner.run(sign)
        guard signed.succeeded else {
            throw ToolkitError(.commandFailed, message: "Could not sign the inventory fixture.",
                               recovery: nil, technicalDetail: signed.technicalSummary)
        }
        return app
    }

    private func command(_ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let request = CommandRequest(executable: try AppleTool.xcrun.locate(), arguments: arguments,
                                     timeout: timeout, displayName: "inventory acceptance tool")
        let result = try await runner.run(request)
        guard result.succeeded else {
            throw ToolkitError(.commandFailed, message: "An inventory acceptance tool failed.",
                               recovery: nil, technicalDetail: result.technicalSummary)
        }
        return result
    }
}
