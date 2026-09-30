import DeviceKit
import SwiftUI
import ToolkitCore
import ToolkitFeatures

// MARK: - Firmware

/// Firmware (IPSW) for iPhone and iPad: the device and its mode, Apple's firmware and whether
/// Apple signs it, the local library, and installing with the bundled idevicerestore.
struct FirmwareView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmation: PendingConfirmation?

    /// A device in recovery or DFU mode comes first: it is the one the installer will find.
    private var device: FirmwareDevice? {
        if let recovery = model.firmware.recoveryDevice { return FirmwareDevice(recovery) }
        if let selected = model.selectedDevice, selected.kind == .physical || selected.kind == .demo { return FirmwareDevice(selected) }
        return nil
    }

    var body: some View {
        let firmware = model.firmware
        WorkspacePage(workspace: .firmware) {
            if let problem = firmware.helperProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            deviceCard
            if let device, let productType = device.productType {
                appleFirmware(device, productType: productType)
            }
            libraryCard
            installCard
            about
        }
        .sheet(item: $confirmation) { pending in
            ConfirmationSheet(title: pending.title, detail: pending.detail, requirement: pending.requirement, target: pending.target, commandPreview: pending.commandPreview, onConfirm: pending.action)
        }
        .task { await firmware.scanLibrary() }
        .task { await firmware.watchRecovery(runner: model.runner) }
        .task(id: device?.productType) {
            if let device, let productType = device.productType, device.state != .demo {
                await firmware.loadCatalog(productType: productType, app: model)
            }
        }
        .onChange(of: firmware.selectedIPSW) { firmware.resetPreflight() }
        .onChange(of: firmware.mode) { firmware.resetPreflight() }
    }

    // MARK: Device

    private var deviceCard: some View {
        let firmware = model.firmware
        return Card(title: "Device", systemImage: "iphone", subtitle: "Connect the iPhone or iPad by USB. A device in recovery or DFU mode appears here on its own.") {
            if let device {
                InfoRow("Device", device.name)
                InfoRow("Model", device.productType ?? "Unknown", monospaced: true)
                if let deviceClass = device.deviceClass { InfoRow("Board", deviceClass.uppercased(), monospaced: true) }
                InfoRow("Mode", device.modeLabel)
                if case .recovery(let recovery) = device.state {
                    InfoRow("ECID", recovery.ecid, monospaced: true)
                }
                HStack {
                    switch device.state {
                    case .normal:
                        if let selected = model.selectedDevice {
                            Button("Enter Recovery Mode") {
                                confirmation = PendingConfirmation(title: "Enter recovery mode", detail: "\(selected.name) restarts into recovery mode. Nothing is erased. To leave recovery mode, use Exit Recovery Mode here.", requirement: .make(for: .deviceChange, target: selected.target), target: selected.target) {
                                    Task { await firmware.enterRecovery(selected, app: model) }
                                }
                            }
                            .disabled(firmware.isInstalling || !selected.supportsLockdownServices)
                        }
                    case .recovery(let recovery):
                        Button("Exit Recovery Mode") {
                            confirmation = PendingConfirmation(title: "Exit recovery mode", detail: "The device restarts normally. If its system is damaged it returns to recovery mode; then install firmware with Update or Restore.", requirement: .make(for: .deviceChange, target: device.target), target: device.target) {
                                Task { await firmware.exitRecovery(recovery, app: model) }
                            }
                        }
                        .disabled(firmware.isInstalling || recovery.mode != .recovery)
                    case .demo:
                        Text("Demo Mode shows the page without a device. Nothing can be installed.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else if model.selectedDevice?.kind == .simulator {
                Text("Simulators do not use firmware. Choose an iPhone or iPad, or connect one in recovery or DFU mode.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No iPhone or iPad found. Connect one by USB, unlock it, and tap Trust — or put it in recovery or DFU mode.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("How to put a device in DFU mode") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DFU mode is needed only when recovery mode does not work. Connect the device to this Mac first. For iPhone 8 and later, and iPad without a Home button:")
                    Text("1. Press and release Volume Up, then press and release Volume Down.")
                    Text("2. Press and hold the Side (or Top) button until the screen goes black.")
                    Text("3. Keep holding it and also hold Volume Down for 5 seconds.")
                    Text("4. Release the Side (or Top) button and keep holding Volume Down for 10 more seconds.")
                    Text("In DFU mode the screen stays black. If the Apple logo appears, it restarted normally: try again. The device appears on this page as \u{201C}DFU mode\u{201D}; install with Restore. To leave DFU mode, force-restart it (Volume Up, Volume Down, then hold the Side button until the Apple logo).")
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    // MARK: Apple's firmware

    private func appleFirmware(_ device: FirmwareDevice, productType: String) -> some View {
        let firmware = model.firmware
        return Card(title: "Apple's firmware for \(productType)", systemImage: "icloud.and.arrow.down", subtitle: "From Apple's firmware list, which offers the current firmware for each model. Signing status comes from Apple's signing server, asked with a random device ID.") {
            if firmware.isLoadingCatalog {
                ProgressView().controlSize(.small)
            } else if let error = firmware.catalogError {
                Label(error, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.orange)
            } else if firmware.releasesProductType == productType && firmware.releases.isEmpty {
                Text("Apple lists no firmware for this model.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(firmware.releasesProductType == productType ? firmware.releases : []) { release in
                releaseRow(release, device: device)
                Divider()
            }
            HStack {
                Button(firmware.releasesProductType == productType ? "Check Again" : "Check Apple's Firmware") {
                    Task { await firmware.loadCatalog(productType: productType, app: model, force: firmware.releasesProductType == productType) }
                }
                .disabled(firmware.isLoadingCatalog)
            }
        }
    }

    private func releaseRow(_ release: FirmwareRelease, device: FirmwareDevice) -> some View {
        let firmware = model.firmware
        let progress = firmware.downloads[release.build]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(release.version) (\(release.build))").font(.callout.weight(.semibold))
                    Text(release.fileName).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                SigningBadge(status: firmware.signing[release.build], checking: firmware.checkingSigning.contains(release.build))
            }
            if let sha1 = release.sha1 { InfoRow("Apple's SHA-1", sha1, monospaced: true) }
            if let progress {
                ProgressView(value: progress.total > 0 ? Double(progress.written) / Double(progress.total) : nil) {
                    Text(progress.total > 0 ? "\(ByteFormatting.string(progress.written)) of \(ByteFormatting.string(progress.total))" : "Starting…").font(.caption)
                }
            }
            HStack {
                Button("Check Signing") { Task { await firmware.checkSigning(release, deviceClass: device.deviceClass, app: model) } }
                    .disabled(firmware.checkingSigning.contains(release.build))
                if firmware.isDownloaded(release) {
                    Label("In the library", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
                } else if progress != nil {
                    Button("Stop Download") { firmware.cancelDownload(release) }
                        .help("The download continues where it stopped next time.")
                } else {
                    Button("Download") { firmware.download(release, app: model) }
                        .help("Downloads the IPSW to the firmware library and checks it against Apple's SHA-1.")
                }
            }
        }
    }

    // MARK: Library

    private var libraryCard: some View {
        let firmware = model.firmware
        let productType = device?.productType
        return Card(title: "Firmware library", systemImage: "externaldrive", subtitle: "IPSW files on this Mac, in \(firmware.directory.path).") {
            if firmware.isScanning && firmware.library.isEmpty {
                ProgressView().controlSize(.small)
            } else if firmware.library.isEmpty {
                Text("No firmware yet. Download one above, or add an .ipsw file.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(firmware.library) { file in
                libraryRow(file, productType: productType)
                Divider()
            }
            HStack {
                Button("Add IPSW…") {
                    if let url = FilePanels.chooseFile(title: "Choose an iPhone or iPad firmware (.ipsw)", allowedExtensions: ["ipsw"]) {
                        Task { await firmware.add(url, app: model) }
                    }
                }
                Button("Show Library in Finder") {
                    try? SecureFileIO.createPrivateDirectory(at: firmware.directory)
                    FilePanels.reveal(firmware.directory)
                }
                Button("Rescan") { Task { await firmware.scanLibrary() } }
                    .disabled(firmware.isScanning)
            }
        }
    }

    private func libraryRow(_ file: IPSWFile, productType: String?) -> some View {
        let firmware = model.firmware
        let matches = productType.map(file.supports(productType:))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.title).font(.callout.weight(.semibold))
                    Text("\(file.url.lastPathComponent) · \(ByteFormatting.string(Int64(file.size))) · \(file.manifest.supportedProductTypes.count) models")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if matches == false {
                    Label("Not for this device", systemImage: "xmark.circle").font(.caption).foregroundStyle(.orange)
                }
                SigningBadge(status: firmware.signing[file.id], checking: firmware.checkingSigning.contains(file.id))
            }
            if let fraction = firmware.verifying[file.id] {
                ProgressView(value: fraction) { Text("Verifying").font(.caption) }
            } else if let result = firmware.verification[file.id] {
                Text(result).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Check Signing") { Task { await firmware.checkSigning(file, deviceClass: device?.deviceClass, app: model) } }
                    .disabled(firmware.checkingSigning.contains(file.id))
                Button("Verify") { Task { await firmware.verify(file, app: model) } }
                    .disabled(firmware.verifying[file.id] != nil)
                    .help("Computes SHA-1 and SHA-256 and compares them with Apple's checksum")
                Button("Show in Finder") { FilePanels.reveal(file.url) }
                Button("Move to Trash") {
                    confirmation = PendingConfirmation(title: "Move \(file.url.lastPathComponent) to the Trash", detail: "The file stays in the Trash until you empty it.", requirement: .make(for: .hostWrite, target: nil), target: nil) {
                        Task { await firmware.moveToTrash(file, app: model) }
                    }
                }
                .disabled(firmware.isInstalling && firmware.selectedIPSW == file.id)
            }
        }
    }

    // MARK: Install

    private var installCard: some View {
        let firmware = model.firmware
        let productType = device?.productType
        let candidates = firmware.library.filter { productType == nil || $0.supports(productType: productType!) }
        return Card(title: "Install firmware", systemImage: "arrow.down.to.line.circle", subtitle: "Installs an IPSW from the library with idevicerestore, bundled with the app.") {
            Picker("Firmware", selection: Binding(get: { firmware.selectedIPSW }, set: { firmware.selectedIPSW = $0 })) {
                Text("Choose…").tag(String?.none)
                ForEach(candidates) { file in
                    Text("\(file.title) — \(file.url.lastPathComponent)").tag(Optional(file.id))
                }
            }
            .disabled(firmware.isInstalling)
            Picker("Install", selection: Binding(get: { firmware.mode }, set: { firmware.mode = $0 })) {
                ForEach(FirmwareInstall.Mode.allCases, id: \.self) { mode in
                    Text(mode.title + (mode == .update ? " (keep data)" : " (erase)")).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(firmware.isInstalling)
            Text(firmware.mode.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Label("Keep the device connected by USB until it finishes; it restarts several times.", systemImage: "cable.connector")
                Label("An internet connection is needed: Apple signs the firmware for this device during the install.", systemImage: "network")
                Label("Back up first. Restore erases everything, and an update that fails can require a restore.", systemImage: "externaldrive.badge.timemachine")
                Label("After a restore the device may ask for the Apple Account it was set up with (Activation Lock).", systemImage: "lock")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if !firmware.preflight.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(firmware.preflight) { check in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: check.passed == true ? "checkmark.circle.fill" : check.passed == false ? "xmark.circle.fill" : "questionmark.circle")
                                .foregroundStyle(check.passed == true ? .green : check.passed == false ? .red : .secondary)
                            Text(check.title).font(.callout.weight(.semibold))
                            Text(check.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if firmware.isInstalling || firmware.installStep != nil {
                progressView
            }

            HStack {
                if let device {
                    Button("Check Before Installing") { Task { await firmware.runPreflight(device, app: model) } }
                        .disabled(firmware.selectedFile == nil || firmware.isPreflighting || firmware.isInstalling || firmware.helperProblem != nil)
                        .help("Checks the model, Apple's signing, and that the installer finds the device. Nothing on the device changes.")
                    Button("\(firmware.mode.title)…") { confirmInstall(device) }
                        .disabled(firmware.selectedFile == nil || firmware.isInstalling || device.state == .demo || firmware.helperProblem != nil)
                    if firmware.isPreflighting { ProgressView().controlSize(.small) }
                }
                Spacer()
                if firmware.lastLogFile != nil {
                    Button("Show Log") { firmware.revealLog() }
                }
            }
        }
    }

    private var progressView: some View {
        let firmware = model.firmware
        return VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: firmware.installFraction) {
                Text(firmware.installStep ?? "Starting…").font(.callout.weight(.semibold))
            }
            if firmware.pastPointOfNoReturn && firmware.isInstalling {
                Label("The system is being written. It can't be stopped now — keep the device connected.", systemImage: "exclamationmark.octagon")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if !firmware.installLog.isEmpty {
                DisclosureGroup("Installer output") {
                    ScrollView {
                        Text(firmware.installLog.suffix(200).joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
                .font(.callout)
            }
        }
    }

    private func confirmInstall(_ device: FirmwareDevice) {
        let firmware = model.firmware
        guard let file = firmware.selectedFile else { return }
        let restore = firmware.mode == .restore
        let failed = firmware.preflight.filter { $0.passed == false }
        var lines = [restore
            ? "\(device.name) will be erased and \(file.title) installed. Everything on it is deleted."
            : "\(file.title) will be installed on \(device.name). Apps, settings, and data are kept."]
        lines.append("Stop works only until the system starts being written. After that, stopping would leave the device unusable, so the install always finishes.")
        lines.append("Apple's signing server receives the device's chip, board, and ECID to sign the firmware for it, as Finder does.")
        if firmware.preflight.isEmpty {
            lines.append("Tip: Check Before Installing first.")
        } else if !failed.isEmpty {
            lines.append("The check found problems: " + failed.map(\.title).joined(separator: ", ") + ".")
        }
        confirmation = PendingConfirmation(title: restore ? "Erase and restore \(device.name)" : "Update \(device.name)", detail: lines.joined(separator: "\n\n"), requirement: .make(for: restore ? .highImpact : .deviceChange, target: device.target), target: device.target) {
            Task { await firmware.install(device, app: model) }
        }
    }

    private var about: some View {
        Card(title: "About firmware installation", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Apple signs each firmware for each device when it is installed, and only while Apple still signs that version. Firmware Apple no longer signs cannot be installed, by this app or any other.")
                Text("Update installs over the current system and keeps data, like Finder's Update. Restore erases the device first, like Finder's Restore. A device in DFU mode can only be restored.")
                Text("Installation uses idevicerestore and libirecovery from the libimobiledevice project (LGPL), bundled with the app as separate programs. Their licenses and sources are listed in Third-Party Notices.")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Apple's signing status for one firmware.
struct SigningBadge: View {
    let status: FirmwareSigning.Status?
    let checking: Bool

    var body: some View {
        if checking {
            ProgressView().controlSize(.small)
        } else if let status {
            Label(status.label, systemImage: symbol(status))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(color(status))
                .background(color(status).opacity(0.12), in: Capsule())
                .help(status.explanation)
        } else {
            Text("Signing not checked").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func symbol(_ status: FirmwareSigning.Status) -> String {
        switch status {
        case .signed: return "checkmark.seal"
        case .notSigned: return "xmark.seal"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(_ status: FirmwareSigning.Status) -> Color {
        switch status {
        case .signed: return .green
        case .notSigned: return .red
        case .unknown: return .orange
        }
    }
}
