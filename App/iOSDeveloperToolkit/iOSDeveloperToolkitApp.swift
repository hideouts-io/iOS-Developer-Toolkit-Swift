import SwiftUI
import ToolkitCore
import ToolkitFeatures

@main
struct IOSDeveloperToolkitApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(ToolkitVersion.applicationName, id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    delegate.model = model
                    model.start()
                    ScreenshotHarness.runIfRequested(model: model)
                }
        }
        // Fits a 13-inch MacBook Air (1280×800 points) with room for the Dock and menu bar.
        .defaultSize(width: 1180, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            ToolkitCommands(model: model)
        }

        WindowGroup("Live Log", id: "log-window", for: UUID.self) { $sessionID in
            if let sessionID, let session = model.logs.sessions.first(where: { $0.id == sessionID }) {
                LogSessionView(session: session)
                    .environment(model)
                    .frame(minWidth: 640, minHeight: 400)
            } else {
                ContentUnavailableView("Log Closed", systemImage: "text.alignleft", description: Text("This log window's capture is no longer open."))
            }
        }
        .defaultSize(width: 900, height: 600)

        Window("Diagnostic Log", id: "diagnostic-log") {
            DiagnosticLogView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 360)
        }
        .defaultSize(width: 860, height: 520)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated {
            let critical = model?.firmware.terminationBlocked == true
            if critical { explainFirmwareWriting() }
            return FirmwareTerminationPolicy.terminateAfterLastWindowClosed(critical: critical)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model else { return .terminateNow }
            let busy = !model.operations.isEmpty || model.firmware.isInstalling || model.logs.sessions.contains { $0.state.isActive }
            let decision = FirmwareTerminationPolicy.decision(critical: model.firmware.terminationBlocked, busy: busy)
            if decision == .deny {
                explainFirmwareWriting()
                return .terminateCancel
            }
            if decision == .confirm {
                let alert = NSAlert()
                alert.messageText = "Operations are still running"
                alert.informativeText = "Quitting stops them. Live log captures are saved and finalized; backups and evidence collections that are still running will be incomplete."
                if model.firmware.isInstalling {
                    alert.informativeText += " Cancelling firmware installation before writing can leave an incomplete operation and may require another install. Quit becomes unavailable once firmware writing starts."
                }
                alert.addButton(withTitle: "Quit Anyway")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            }
            // A modal alert runs a nested event loop. Writing may have started while it was open.
            guard !model.firmware.terminationBlocked else {
                explainFirmwareWriting()
                return .terminateCancel
            }
            if model.firmware.isInstalling {
                Task { @MainActor in
                    guard await model.firmware.cancelForTermination() else {
                        self.explainFirmwareWriting()
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    }
                    sender.reply(toApplicationShouldTerminate: self.finishTermination(model) == .terminateNow)
                }
                return .terminateLater
            }
            return finishTermination(model)
        }
    }

    @MainActor
    private func explainFirmwareWriting() {
        let alert = NSAlert()
        alert.messageText = "Firmware is being written"
        alert.informativeText = "Normal application termination is disabled until the installer exits. Keep this Mac powered and the device connected. This protection cannot prevent Force Quit, power loss or cable removal."
        alert.addButton(withTitle: "Keep Running")
        alert.runModal()
    }

    @MainActor
    private func finishTermination(_ model: AppModel) -> NSApplication.TerminateReply {
        guard !model.firmware.terminationBlocked else {
            explainFirmwareWriting()
            return .terminateCancel
        }
        if let target = model.location.lastSimulatedTarget {
            // Leave devices as we found them: clear a location this session simulated.
            let controller = model.executor.location
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                try? await controller.clear(on: target)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 8)
        }
        guard !model.firmware.terminationBlocked else {
            explainFirmwareWriting()
            return .terminateCancel
        }
        model.stop()
        return .terminateNow
    }
}

struct ToolkitCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Create Support Bundle…") { SupportBundleExporter.export(model: model) }
        }
        CommandMenu("Device") {
            Button("Refresh Devices") { Task { await model.refreshDevices() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("Run Readiness Check") {
                if let device = model.selectedDevice {
                    model.workspace = .readiness
                    Task { await model.runReadiness(for: device) }
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.selectedDevice == nil)
            Divider()
            Button("Reconnect a Device…") { model.isReconnectGuidePresented = true }
            Button("Developer Mode Guide") { model.isDeveloperModeGuidePresented = true }
            Toggle("Demo Mode", isOn: Binding(get: { model.demoMode }, set: { model.demoMode = $0 }))
        }
        CommandGroup(after: .sidebar) {
            Button("Command Palette…") { model.isCommandPalettePresented = true }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Previous Workspace") { model.workspace = model.workspace.previous }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Workspace") { model.workspace = model.workspace.next }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Divider()
            ForEach(Array(Workspace.numbered.enumerated()), id: \.element) { index, workspace in
                Button(workspace.title) { model.workspace = workspace }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { model.isShortcutReferencePresented = true }
                .keyboardShortcut("/", modifiers: .command)
            Button("Diagnostic Log") { openWindow(id: "diagnostic-log") }
            Button("Scope & Safety") { model.workspace = .safety }
        }
    }
}
