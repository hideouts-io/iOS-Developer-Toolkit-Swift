import DeviceKit
import SwiftUI
import ToolkitCore
import ToolkitFeatures

// MARK: - Developer Image

/// Apple's developer image (Developer Disk Image): its state on the selected device, mounting and
/// unmounting, how it is mounted, and which images this Mac has.
struct DeveloperImageView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmation: PendingConfirmation?
    @State private var inventory: DeveloperImageHostInventory?

    var body: some View {
        WorkspacePage(workspace: .developerImage) {
            TargetHeader()
            if let device = model.selectedDevice {
                switch device.kind {
                case .simulator:
                    Card(title: "Not needed for simulators", systemImage: "checkmark.circle") {
                        Text("Simulators include developer services, so no developer image is mounted. Choose an iPhone or iPad to use this page.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .physical, .demo:
                    DeveloperImageStatusCard(device: device, confirmation: $confirmation)
                    mountMethod
                    imagesOnThisMac(device)
                    if let mounted = model.developerImage.status(for: device)?.mountedImages, !mounted.isEmpty {
                        mountedImages(mounted)
                    }
                    about(device)
                }
            } else {
                ContentUnavailableView("No Device Selected", systemImage: "externaldrive.badge.questionmark", description: Text("Connect an iPhone or iPad by USB, unlock it, and tap Trust. Then choose it in the toolbar."))
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .sheet(item: $confirmation) { pending in
            ConfirmationSheet(title: pending.title, detail: pending.detail, requirement: pending.requirement, target: pending.target, commandPreview: nil, onConfirm: pending.action)
        }
        .task(id: model.developerImage.folders) { reloadInventory() }
    }

    private var mountMethod: some View {
        let images = model.developerImage
        return Card(title: "How to mount", systemImage: "gearshape.2", subtitle: "Used by Mount Developer Image. If one way fails, try another.") {
            Picker("Mount with", selection: Binding(get: { images.mechanism }, set: { images.mechanism = $0 })) {
                ForEach(DeveloperImageMechanism.allCases, id: \.self) { mechanism in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mechanism.label)
                        Text(mechanism.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .tag(mechanism)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityIdentifier("ddi-mechanism")
        }
    }

    private func imagesOnThisMac(_ device: Device) -> some View {
        let images = model.developerImage
        return Card(title: "Images on this Mac", systemImage: "internaldrive", subtitle: "iOS 17 and later use the personalized image that Xcode installs. iOS 16 and earlier need the image for that exact iOS version, from Xcode or a folder you add.") {
            if let inventory {
                if inventory.personalized.isEmpty && inventory.legacy.isEmpty {
                    Label("No developer images found. Install Xcode and open it once, or add a folder that contains one.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(inventory.personalized.enumerated()), id: \.offset) { _, source in
                    InfoRow("Personalized image", source.displayName + (source.supportedProductTypes.isEmpty ? "" : " · \(source.supportedProductTypes.count) device models"))
                }
                ForEach(Array(inventory.legacy.enumerated()), id: \.offset) { _, source in
                    InfoRow("iOS \(source.version)", source.displayName)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if !images.folders.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Folders you added").font(.callout.weight(.semibold))
                    ForEach(images.folders, id: \.self) { folder in
                        HStack {
                            Text(folder.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Remove") { images.removeFolder(folder) }.controlSize(.small)
                        }
                    }
                }
            }
            HStack {
                Button("Add Image Folder…") {
                    if let folder = FilePanels.chooseFolder(title: "Choose a folder that contains a developer image", canCreate: false) {
                        model.statusMessage = images.addFolder(folder)
                        Task { await images.refresh(device, app: model) }
                    }
                }
                Button("Update This Mac's Images from Xcode") { runAction("host-ddis-update", device) }
                    .disabled(!device.supportsCoreDevice)
                    .help("Asks Xcode to download or update its developer images (devicectl manage ddis update)")
            }
        }
    }

    private func mountedImages(_ mounted: [MountedImage]) -> some View {
        Card(title: "Mounted on the device", systemImage: "externaldrive.connected.to.line.below") {
            ForEach(Array(mounted.enumerated()), id: \.offset) { _, image in
                InfoRow(image.imageType ?? "Image", image.mountPath ?? (image.isMounted == true ? "Mounted" : "Not mounted"), monospaced: image.mountPath != nil)
            }
        }
    }

    private func about(_ device: Device) -> some View {
        Card(title: "About developer images", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Screenshots, location simulation, launching apps, and Instruments need Apple's developer image mounted on the device. Logs, backups, diagnostics, app lists, and packet capture do not.")
                Text("The image stays mounted until the device restarts. Mounting needs the device unlocked, and on iOS 16 and later it needs Developer Mode on.")
                Text("On iOS 17 and later, Apple personalizes the image for the device before it is mounted, just as Xcode does: this Mac sends the device's chip, board, and ECID with a one-time nonce to Apple's signing server.")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if device.kind == .physical && device.developerMode != .enabled {
                    Button("How to Turn On Developer Mode…") { model.isDeveloperModeGuidePresented = true }
                }
                Button("Open Readiness Check") { model.workspace = .readiness }
            }
        }
    }

    private func reloadInventory() {
        let folders = model.developerImage.folders
        let coreDevice = model.selectedDevice?.supportsCoreDevice ?? false
        Task.detached(priority: .userInitiated) {
            let found = DeveloperImageHostInventory.discover(userFolders: folders, coreDeviceAvailable: coreDevice)
            await MainActor.run { inventory = found }
        }
    }

    private func runAction(_ id: String, _ device: Device) {
        guard let action = ActionCatalog.descriptor(id) else { return }
        let executor = model.executor
        let target = device.target
        Task {
            if let result = await model.run(action.title, workspace: .developerImage, target: target, transport: action.mechanism, { _ in try await executor.execute(action, target: target, values: [:]) }) {
                model.statusMessage = result.summary
                reloadInventory()
            }
        }
    }
}

/// The developer image's state on one device, with Check Again, Mount, and Unmount.
struct DeveloperImageStatusCard: View {
    @Environment(AppModel.self) private var model
    let device: Device
    @Binding var confirmation: PendingConfirmation?

    var body: some View {
        let images = model.developerImage
        let status = images.status(for: device)
        let busy = images.isBusy(device)
        Card(title: "On \(device.name)", systemImage: "externaldrive.badge.checkmark") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if let status {
                        Label(status.state.label, systemImage: status.state.symbolName)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Self.color(for: status.state))
                            .accessibilityIdentifier("ddi-state")
                        Text(status.headline).font(.callout)
                    } else {
                        Text("Not checked yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let status {
                    Text(status.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let remediation = status.remediation {
                        Label(remediation, systemImage: "lightbulb")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(status.detailRows.filter { $0.0 != "State" && $0.0 != "Next step" }.enumerated()), id: \.offset) { _, row in
                                InfoRow(row.0, row.1, monospaced: row.0 == "Chip / board")
                            }
                            if let technical = status.technicalDetail {
                                InfoRow("Technical detail", technical, monospaced: true)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                }
                HStack {
                    Button("Check Again") { Task { await images.refresh(device, app: model) } }
                        .disabled(busy)
                    Button("Mount Developer Image") {
                        confirmation = PendingConfirmation(title: "Mount the developer image", detail: Self.mountDetail(status, device: device, mechanism: images.mechanism), requirement: .make(for: .deviceChange, target: device.target), target: device.target) {
                            Task { await images.mount(device, app: model) }
                        }
                    }
                    .disabled(busy || device.kind != .physical || !(status?.state.canMount ?? false))
                    .accessibilityIdentifier("mount-ddi")
                    Button("Unmount") {
                        confirmation = PendingConfirmation(title: "Unmount the developer image", detail: "Developer services stop until the image is mounted again. Restarting the device has the same effect.", requirement: .make(for: .deviceChange, target: device.target), target: device.target) {
                            Task { await images.unmount(device, app: model) }
                        }
                    }
                    .disabled(busy || status?.state != .mounted || !device.supportsLockdownServices)
                    .accessibilityIdentifier("unmount-ddi")
                }
            }
        }
    }

    static func color(for state: DeveloperImageState) -> Color {
        switch state {
        case .mounted: return .green
        case .notRequired: return .secondary
        case .available, .personalizationRequired: return .blue
        case .missing, .incompatible, .blocked: return .orange
        case .failed: return .red
        }
    }

    static func mountDetail(_ status: DeveloperImageStatus?, device: Device, mechanism: DeveloperImageMechanism) -> String {
        var lines = ["The developer image will be uploaded to \(device.name) and mounted (\(mechanism.label)). Keep the device unlocked and connected until it finishes."]
        if status?.requiredKind == .personalized && status?.state == .personalizationRequired {
            lines.append("Apple personalizes the image for this device first: this Mac sends the device's chip, board, and ECID with a one-time nonce to Apple's signing server (gs.apple.com), as Xcode does. An internet connection is required.")
        }
        if let host = status?.hostImage { lines.append("Image: \(host).") }
        return lines.joined(separator: "\n\n")
    }
}
