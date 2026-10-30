import DeviceKit
import SwiftUI
import ToolkitCore
import ToolkitFeatures

struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmation: PendingConfirmation?

    var body: some View {
        @Bindable var apps = model.apps
        VStack(alignment: .leading, spacing: 12) {
            TargetHeader()
#if DEBUG
            if let acceptance = model.inventoryAcceptance {
                HStack {
                    Button("Arm inventory acceptance") {
                        do { try acceptance.arm() } catch { model.present(error) }
                    }
                    .disabled(acceptance.state != .idle)
                    .accessibilityIdentifier("inventory-gate-arm")
                    Button("Release captured inventory") {
                        do { try acceptance.release() } catch { model.present(error) }
                    }
                    .disabled(acceptance.state != .held)
                    .accessibilityIdentifier("inventory-gate-release")
                    Text(acceptance.state.rawValue)
                        .accessibilityIdentifier("inventory-gate-state")
                }
            }
#endif
            if let device = model.selectedDevice {
                HStack(spacing: 12) {
                    Button {
                        Task {
                            await apps.refresh(app: model, device: device)
#if DEBUG
                            model.inventoryAcceptance?.inventoryRefreshReturned(target: device.target.udid)
#endif
                        }
                    } label: {
                        Label(apps.loadedFor == device.target ? "Refresh" : "Load Apps", systemImage: "arrow.clockwise")
                    }
                    .disabled(apps.isLoading)
                    .accessibilityIdentifier("load-apps")
                    if apps.isLoading { ProgressView().controlSize(.small) }
                    Toggle("Include built-in apps", isOn: $apps.includeSystemApps)
                    if device.kind == .physical && device.supportsLockdownServices {
                        Toggle("Calculate sizes", isOn: $apps.calculateSizes)
                    }
                    Spacer()
                    TextField("Search name or bundle ID", text: $apps.search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
                if apps.loadedFor != nil && apps.loadedFor != device.target {
                    Label("This list is from another device. Refresh to load \(device.name).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("apps-stale-inventory")
                }
                Table(apps.visibleRows, selection: $apps.selection, sortOrder: $apps.sortOrder) {
                    TableColumn("Name", value: \.name) { Text($0.name).accessibilityIdentifier("installed-app-\($0.bundleIdentifier)") }
                    TableColumn("Bundle ID", value: \.bundleIdentifier) { Text($0.bundleIdentifier).font(.callout.monospaced()) }
                    TableColumn("Version", value: \.version) { Text($0.build.isEmpty ? $0.version : "\($0.version) (\($0.build))") }
                    TableColumn("Type", value: \.kind)
                    TableColumn("Size") { Text($0.sizeText).monospacedDigit() }
                        .width(min: 70, ideal: 90)
                }
                .accessibilityIdentifier("installed-apps-table")
                .contextMenu(forSelectionType: AppRow.ID.self) { ids in
                    if let id = ids.first, let row = apps.rows.first(where: { $0.id == id }) {
                        Button("Copy Bundle ID") { Pasteboard.copy(row.bundleIdentifier) }
                        Button("Launch") { launch(row, device) }.disabled(!apps.canAct(on: row, device: device, selectedTarget: model.selectedTarget))
                            .accessibilityIdentifier("apps-context-launch")
                        Divider()
                        Button("Remove…", role: .destructive) { confirmRemove(row, device) }.disabled(!row.isRemovable || !apps.canAct(on: row, device: device, selectedTarget: model.selectedTarget))
                            .accessibilityIdentifier("apps-context-remove")
                    }
                }
                .overlay {
                    if apps.rows.isEmpty && !apps.isLoading {
                        ContentUnavailableView("No Apps Loaded", systemImage: "app.dashed", description: Text("Choose Load Apps to list what is installed on \(device.name). An empty list is not proof that no apps exist."))
                    }
                }
                HStack {
                    Text(apps.rows.isEmpty ? "" : "\(apps.visibleRows.count) of \(apps.rows.count) apps · source: \(apps.source)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("apps-inventory-source")
                    Spacer()
                    if let id = apps.selection.first, let row = apps.rows.first(where: { $0.id == id }) {
                        Button("Copy Bundle ID") { Pasteboard.copy(row.bundleIdentifier) }
                        Button("Launch") { launch(row, device) }.disabled(!apps.canAct(on: row, device: device, selectedTarget: model.selectedTarget))
                            .accessibilityIdentifier("apps-launch")
                        Button("Remove…", role: .destructive) { confirmRemove(row, device) }
                            .disabled(!row.isRemovable || !apps.canAct(on: row, device: device, selectedTarget: model.selectedTarget))
                            .accessibilityIdentifier("apps-remove")
                    }
                }
            }
        }
        .padding(20)
        .onChange(of: model.selectedTarget) { _, _ in confirmation = nil }
        .sheet(item: $confirmation) { pending in
            let confirmationSheet = ConfirmationSheet(title: pending.title, detail: pending.detail, requirement: pending.requirement, target: pending.target, commandPreview: nil, onConfirm: pending.action)
                .accessibilityIdentifier("apps-confirmation")
#if DEBUG
            if let acceptance = model.inventoryAcceptance, let target = pending.target,
               target.kind == .simulator, target.udid.uppercased() == acceptance.targets.first {
                VStack {
                    confirmationSheet
                    Button("Delete owned test simulator A") {
                        Task {
                            await model.run("Delete owned test simulator A", workspace: .apps, target: target, transport: "simctl shutdown/delete") { _ in
                                try await acceptance.deleteFirstSimulator(target: target)
                            }
                        }
                    }
                    .disabled(acceptance.isDeletingFirst || acceptance.state != .delivered)
                    .accessibilityIdentifier("inventory-delete-owned-a")
                    .padding(.bottom, 20)
                }
            } else {
                confirmationSheet
            }
#else
            confirmationSheet
#endif
        }
    }

    private func confirmRemove(_ row: AppRow, _ device: Device) {
        do {
            let request = try model.apps.prepareAction(for: row, device: device, selectedTarget: model.selectedTarget)
            confirmation = PendingConfirmation(title: "Remove \(row.name)?", detail: "\(row.name) (\(row.bundleIdentifier)) and its data will be deleted from \(device.name).", requirement: .make(for: .highImpact, target: request.device.target), target: request.device.target) {
                Task { await model.apps.uninstall(request, app: model) }
            }
        } catch { model.present(error) }
    }

    private func launch(_ row: AppRow, _ device: Device) {
        do {
            let request = try model.apps.prepareAction(for: row, device: device, selectedTarget: model.selectedTarget)
            confirmation = PendingConfirmation(title: "Launch \(row.name)?", detail: "The app is restarted on \(device.name) if it is already running.", requirement: .make(for: .deviceChange, target: request.device.target), target: request.device.target) {
                Task { await model.apps.launch(request, app: model) }
            }
        } catch { model.present(error) }
    }
}

struct InstallAppView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmation: PendingConfirmation?

    var body: some View {
        @Bindable var install = model.install
        WorkspacePage(workspace: .installApp) {
            TargetHeader(allowedKinds: [.physical, .simulator])
            Card(title: "Choose a package", systemImage: "shippingbox", subtitle: "Physical devices install signed .ipa packages (or .app bundles built for devices). Simulators install .app bundles built for the simulator. The package is inspected on this Mac before installation is offered.") {
                HStack {
                    Button("Choose .ipa or .app…") {
                        if let url = FilePanels.chooseFile(title: "Choose an app package", allowedExtensions: ["ipa", "app"]) {
                            Task { await install.choose(url, app: model) }
                        }
                    }
                    .accessibilityIdentifier("choose-package")
                    if let url = install.packageURL {
                        Text(url.lastPathComponent).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            if let inspection = install.inspection {
                InspectionView(inspection: inspection, device: model.selectedDevice)
            } else if let name = install.appBundleName {
                Card(title: name, systemImage: "app") {
                    Text("App bundles are installed as they are. Build for the simulator to install on a simulator, or for a device (signed) to install on a device.")
                        .foregroundStyle(.secondary)
                }
            }
            if let device = model.selectedDevice, install.packageURL != nil {
                Card(title: "Install", systemImage: "square.and.arrow.down.on.square") {
                    if device.kind == .physical && !device.supportsCoreDevice {
                        Toggle("Install as developer package", isOn: $install.installAsDeveloperPackage)
                            .help("Asks iOS to treat the package as a development build. Only meaningful for development-signed apps.")
                    }
                    let blocked = blockReason(device)
                    if let blocked {
                        Label(blocked, systemImage: "hand.raised").foregroundStyle(.orange)
                    }
                    Button("Install on \(device.name)…") {
                        confirmation = PendingConfirmation(title: "Install \(install.inspection?.appName ?? install.packageURL?.lastPathComponent ?? "app")?", detail: "The app will be installed on \(device.name). iOS still checks the signature, provisioning, and entitlements.", requirement: .make(for: .deviceChange, target: device.target), target: device.target) {
                            Task { await install.install(app: model, device: device) }
                        }
                    }
                    .disabled(blocked != nil)
                }
            }
        }
        .sheet(item: $confirmation) { pending in
            ConfirmationSheet(title: pending.title, detail: pending.detail, requirement: pending.requirement, target: pending.target, commandPreview: nil, onConfirm: pending.action)
        }
    }

    private func blockReason(_ device: Device) -> String? {
        let install = model.install
        switch device.kind {
        case .demo: return "Demo Mode cannot install apps."
        case .simulator:
            if !install.isAppBundle { return "Simulators install .app bundles built for the simulator, not .ipa files." }
            if device.simulatorState != .booted { return "Start the simulator first." }
            return nil
        case .physical:
            if let inspection = install.inspection, !inspection.isInstallable { return inspection.installabilityExplanation }
            return nil
        }
    }
}

struct InspectionView: View {
    let inspection: IPAInspection
    let device: Device?

    var body: some View {
        Card(title: "\(inspection.appName) \(inspection.version) (\(inspection.build))", systemImage: inspection.isInstallable ? "checkmark.shield" : "xmark.shield") {
            Label(inspection.installabilityExplanation, systemImage: inspection.isInstallable ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(inspection.isInstallable ? .green : .orange)
                .fixedSize(horizontal: false, vertical: true)
            InfoRow("Bundle identifier", inspection.bundleIdentifier, monospaced: true)
            InfoRow("Minimum iOS", inspection.minimumOSVersion ?? "Not declared")
            InfoRow("Code signature", inspection.signature.status.rawValue.capitalized, explanation: "Whether every file in the app still matches its signature. A broken signature always prevents installation.")
            InfoRow("Signing team", inspection.signature.teamIdentifier ?? "—", monospaced: true)
            InfoRow("Profile type", inspection.provisioning.profileKind, explanation: "Development and Ad Hoc profiles list the exact devices they allow; Enterprise profiles allow any device in the organization.")
            if let expiration = inspection.provisioning.expirationDate {
                InfoRow("Profile expires", expiration.formatted(date: .abbreviated, time: .omitted) + (inspection.provisioning.isExpired ? " (expired)" : ""))
            }
            if let device, device.kind == .physical, inspection.provisioning.status == .decoded {
                let included = inspection.provisioning.includes(udid: device.udid)
                Label(included ? "\(device.name) is included in the profile." : "\(device.name) is not listed in the profile, so iOS will likely refuse the app.", systemImage: included ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(included ? .green : .orange)
            }
            DisclosureGroup("Full inspection report") {
                RawOutputView(text: inspection.report, maxHeight: 260)
            }
        }
    }
}
