import AppKit
import DeviceKit
import Foundation
import Observation
import ToolkitCore
import ToolkitFeatures

/// The device the Firmware page works with: a connected device in normal mode, or one in
/// recovery or DFU mode (which the rest of the app cannot see).
struct FirmwareDevice: Hashable {
    enum State: Hashable {
        case normal
        case recovery(RecoveryDevice)
        case demo
    }

    var state: State
    var name: String
    var productType: String?
    /// The build identity's device class (`d93ap`), used to pick the right one.
    var deviceClass: String?
    var target: DeviceTarget

    var installTarget: FirmwareInstall.Target {
        switch state {
        case .recovery(let device): return .ecid(device.ecid)
        case .normal, .demo: return .udid(target.udid)
        }
    }

    func installSelection(ipsw: URL, mode: FirmwareInstall.Mode) -> FirmwareInstallSelection {
        let chip: Int?
        let board: Int?
        if case .recovery(let device) = state {
            func number(_ text: String?) -> Int? {
                guard let text else { return nil }
                return text.lowercased().hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) : Int(text)
            }
            chip = number(device.chipID)
            board = number(device.boardID)
        } else {
            chip = nil
            board = nil
        }
        return FirmwareInstallSelection(ipsw: ipsw, target: installTarget, productType: productType, deviceClass: deviceClass, chipID: chip, boardID: board, mode: mode)
    }

    var modeLabel: String {
        switch state {
        case .normal: return "Normal"
        case .recovery(let device): return device.mode.label
        case .demo: return "Normal (demo)"
        }
    }

    init(_ device: Device) {
        state = device.kind == .demo ? .demo : .normal
        name = device.name
        productType = device.productType
        deviceClass = device.hardwareModel?.lowercased()
        target = device.target
    }

    init(_ recovery: RecoveryDevice) {
        state = .recovery(recovery)
        name = "\(recovery.productType ?? "Device") in \(recovery.mode.label.lowercased())"
        productType = recovery.productType
        deviceClass = recovery.model?.lowercased()
        target = DeviceTarget(kind: .physical, udid: recovery.ecid, name: name, osVersion: nil, usbmuxDeviceID: nil, coreDeviceIdentifier: nil, transport: .usb)
    }
}

/// Firmware (IPSW) state: Apple's firmware for the device, signing status, downloads, the local
/// library, recovery and DFU mode, and installation through the bundled idevicerestore.
@Observable
@MainActor
final class FirmwareModel {
    // Apple's firmware for the current model.
    private(set) var releases: [FirmwareRelease] = []
    private(set) var releasesProductType: String?
    private(set) var isLoadingCatalog = false
    private(set) var catalogError: String?
    /// Signing status by build (Apple's firmware) or by path (library files).
    private(set) var signing: [String: FirmwareSigning.Status] = [:]
    private(set) var checkingSigning: Set<String> = []

    // Downloads, by build.
    private(set) var downloads: [String: (written: Int64, total: Int64)] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    // The library.
    private(set) var library: [IPSWFile] = []
    private(set) var isScanning = false
    private(set) var verification: [String: String] = [:]
    private(set) var verifying: [String: Double] = [:]

    // Recovery and DFU.
    private(set) var recoveryDevice: RecoveryDevice?
    private(set) var helperProblem: String?

    // Installing.
    var selectedIPSW: String? { didSet { if selectedIPSW != oldValue { resetPreflight() } } }
    var mode: FirmwareInstall.Mode = .update { didSet { if mode != oldValue { resetPreflight() } } }
    private(set) var preflight: [FirmwarePreflight.Check] = []
    private(set) var validatedInstall: ValidatedFirmwareInstall?
    private var preflightRevision = UUID()
    private(set) var isPreflighting = false
    private(set) var isInstalling = false
    private(set) var installStep: String?
    private(set) var installFraction: Double = 0
    private(set) var installLog: [String] = []
    private(set) var pastPointOfNoReturn = false
    private(set) var lastLogFile: URL?
    private var installationTask: Task<Void, Never>?
    private var writeProtection: FirmwareWriteProtection?

    /// Read the synchronized guard directly: progress may reach the critical phase before a
    /// queued UI update arrives on the main actor.
    var terminationBlocked: Bool { writeProtection?.isCritical == true }

    let directory = IPSWLibrary.defaultDirectory()
    private var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/\(ToolkitVersion.applicationName)/Firmware")
    }
    private var logDirectory: URL { directory.appendingPathComponent("Logs") }

    // MARK: Helpers

    func helper(_ helper: RestoreHelper) -> URL? {
        do {
            let url = try helper.locate()
            helperProblem = nil
            return url
        } catch {
            helperProblem = (error as? ToolkitError)?.message ?? error.localizedDescription
            return nil
        }
    }

    // MARK: Apple's firmware

    private func signingKey(_ firmwareID: String, deviceClass: String?) -> String {
        firmwareID + "\u{0}" + (deviceClass?.lowercased() ?? "generic")
    }

    func signingStatus(_ firmwareID: String, deviceClass: String?) -> FirmwareSigning.Status? {
        signing[signingKey(firmwareID, deviceClass: deviceClass)]
    }

    func isCheckingSigning(_ firmwareID: String, deviceClass: String?) -> Bool {
        checkingSigning.contains(signingKey(firmwareID, deviceClass: deviceClass))
    }

    func loadCatalog(productType: String, app: AppModel, force: Bool = false) async {
        guard !isLoadingCatalog, force || releasesProductType != productType else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        catalogError = nil
        let cache = cacheDirectory.appendingPathComponent("version.plist")
        if force { try? FileManager.default.removeItem(at: cache) }
        let result = await app.run("Check Apple's firmware", workspace: .firmware, target: nil, transport: "itunes.apple.com/check/version", presentErrors: false) { _ in
            try FirmwareCatalog.releases(fromCatalog: try await FirmwareCatalog.load(cache: cache), productType: productType)
        }
        if let result {
            releases = result
            releasesProductType = productType
        } else {
            catalogError = "Apple's firmware list could not be loaded. Check the internet connection and try again."
        }
    }

    /// Asks Apple whether it signs `release` for this model. Only the firmware's build manifest is
    /// read (not the whole IPSW); the request uses a random device ID.
    func checkSigning(_ release: FirmwareRelease, deviceClass: String?, app: AppModel) async {
        let key = signingKey(release.id, deviceClass: deviceClass)
        guard !checkingSigning.contains(key) else { return }
        checkingSigning.insert(key)
        defer { checkingSigning.remove(key) }
        let status = await app.run("Check signing for \(release.version)", workspace: .firmware, target: nil, transport: "gs.apple.com (TSS)", presentErrors: false) { _ in
            let manifest = try FirmwareManifest.parse(try await RemoteArchive.file(named: FirmwareManifest.fileName, in: release.url))
            guard manifest.supportedProductTypes.contains(release.productType), let identity = FirmwareSigning.identityForCheck(manifest: manifest, deviceClass: deviceClass) else {
                return FirmwareSigning.Status.unknown("The firmware has no install for this device model.")
            }
            return await FirmwareSigning.check(identity: identity)
        }
        signing[key] = status ?? .unknown("The firmware's build manifest could not be read from Apple's server.")
    }

    func checkSigning(_ file: IPSWFile, deviceClass: String?, app: AppModel) async {
        let key = signingKey(file.id, deviceClass: deviceClass)
        guard !checkingSigning.contains(key) else { return }
        checkingSigning.insert(key)
        defer { checkingSigning.remove(key) }
        guard let identity = FirmwareSigning.identityForCheck(manifest: file.manifest, deviceClass: deviceClass) else {
            signing[key] = .unknown("The firmware has no install for this device model.")
            return
        }
        let status = await app.run("Check signing for \(file.title)", workspace: .firmware, target: nil, transport: "gs.apple.com (TSS)", presentErrors: false) { _ in
            await FirmwareSigning.check(identity: identity)
        }
        signing[key] = status ?? .unknown("Apple's signing server could not be reached.")
    }

    // MARK: Downloads

    func isDownloaded(_ release: FirmwareRelease) -> Bool {
        library.contains { $0.url.lastPathComponent == release.fileName }
    }

    func download(_ release: FirmwareRelease, app: AppModel) {
        guard downloadTasks[release.build] == nil else { return }
        let directory = directory
        downloads[release.build] = (0, 0)
        downloadTasks[release.build] = Task {
            let result = await app.run("Download \(release.fileName)", workspace: .firmware, target: nil, transport: "updates.cdn-apple.com", outputPaths: [directory.appendingPathComponent(release.fileName).path]) { operation in
                try await FirmwareDownloader().download(release, to: directory) { written, total in
                    operation.report("\(ByteFormatting.string(written)) of \(ByteFormatting.string(total))", progress: total > 0 ? Double(written) / Double(total) : nil)
                    Task { @MainActor in self.downloads[release.build] = (written, total) }
                }
            }
            downloads[release.build] = nil
            downloadTasks[release.build] = nil
            if let result {
                verification[result.url.path] = result.provenance.explanation + "\nLocal SHA-256 \(result.sha256)"
                app.statusMessage = "Downloaded \(release.fileName). \(result.provenance.explanation)"
                await scanLibrary()
            }
        }
    }

    func cancelDownload(_ release: FirmwareRelease) {
        downloadTasks[release.build]?.cancel()
    }

    // MARK: Library

    func scanLibrary() async {
        isScanning = true
        defer { isScanning = false }
        let directory = directory
        library = await Task.detached(priority: .userInitiated) { IPSWLibrary.scan(directory) }.value
        if let selectedIPSW, !library.contains(where: { $0.id == selectedIPSW }) { self.selectedIPSW = nil }
    }

    /// Copies an IPSW into the library after checking that it is one (a clone on the same volume).
    func add(_ url: URL, app: AppModel) async {
        let directory = directory
        let result = await app.run("Add \(url.lastPathComponent)", workspace: .firmware, target: nil, transport: "Local copy", outputPaths: [directory.appendingPathComponent(url.lastPathComponent).path]) { _ in
            try await Task.detached(priority: .userInitiated) {
                _ = try IPSWLibrary.inspect(url)
                try SecureFileIO.createPrivateDirectory(at: directory)
                let destination = directory.appendingPathComponent(url.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw ToolkitError.invalidInput("\(url.lastPathComponent) is already in the library.")
                }
                try FileManager.default.copyItem(at: url, to: destination)
                return destination
            }.value
        }
        if result != nil {
            app.statusMessage = "Added \(url.lastPathComponent) to the firmware library."
            await scanLibrary()
        }
    }

    /// SHA-1 and SHA-256 of a library file, compared with Apple's SHA-1 when the build is known.
    func verify(_ file: IPSWFile, app: AppModel) async {
        guard verifying[file.id] == nil else { return }
        verifying[file.id] = 0
        defer { verifying[file.id] = nil }
        // Apple's SHA-1 applies only to the exact file Apple lists (same name), not to another
        // model's IPSW of the same build.
        let expected = releases.first { $0.fileName == file.url.lastPathComponent }?.sha1
        let id = file.id
        let url = file.url
        let sums = await app.run("Verify \(file.url.lastPathComponent)", workspace: .firmware, target: nil, transport: "SHA-1 / SHA-256 (CryptoKit)") { operation in
            try await Task.detached(priority: .userInitiated) {
                try IPSWLibrary.checksums(of: url) { fraction in
                    operation.report("Reading the firmware", progress: fraction)
                    Task { @MainActor in self.verifying[id] = fraction }
                }
            }.value
        }
        guard let sums else { return }
        if let expected {
            verification[id] = sums.sha1 == expected
                ? "Matches Apple's checksum (SHA-1 \(sums.sha1))."
                : "Does not match Apple's checksum. Expected SHA-1 \(expected), got \(sums.sha1). Delete it and download it again."
        } else {
            verification[id] = "SHA-1 \(sums.sha1)\nSHA-256 \(sums.sha256)\nApple's checksum for this build is not in the firmware list, so compare these with a trusted source."
        }
    }

    func moveToTrash(_ file: IPSWFile, app: AppModel) async {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            app.statusMessage = "Moved \(file.url.lastPathComponent) to the Trash."
        } catch {
            app.present(ToolkitError.fileSystem("\(file.url.lastPathComponent) could not be moved to the Trash.", path: file.url.path))
        }
        await scanLibrary()
    }

    // MARK: Recovery and DFU

    /// Looks for a device in recovery or DFU mode every few seconds while the page is open.
    func watchRecovery(runner: CommandRunning) async {
        guard let helper = helper(.irecovery) else { return }
        while !Task.isCancelled {
            if !isInstalling {
                recoveryDevice = await RecoveryProbe.query(runner: runner, helper: helper)
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func enterRecovery(_ device: Device, app: AppModel) async {
        let target = device.target
        if await app.run("Enter recovery mode", workspace: .firmware, target: target, transport: "lockdown EnterRecovery", { _ in
            try await DeviceSession.with(target) { try await $0.enterRecovery() }
            return true
        }) != nil {
            app.statusMessage = "\(device.name) is restarting into recovery mode. It appears here in a few seconds."
        }
    }

    func exitRecovery(_ recovery: RecoveryDevice, app: AppModel) async {
        guard let helper = helper(.irecovery) else { return }
        let runner = app.runner
        let target = FirmwareDevice(recovery).target
        if await app.run("Exit recovery mode", workspace: .firmware, target: target, transport: "irecovery -n", argv: ["irecovery", "-i", recovery.ecid, "-n"], { _ in
            let result = try await runner.run(try RecoveryProbe.exitRecoveryRequest(helper: helper, ecid: recovery.ecid))
            guard result.succeeded else {
                throw ToolkitError(.commandFailed, message: "The device did not leave recovery mode.", recovery: "If it keeps returning to recovery mode, its system needs to be installed again: use Update first, then Restore.", technicalDetail: result.technicalSummary)
            }
            return true
        }) != nil {
            app.statusMessage = "The device is restarting normally."
            recoveryDevice = nil
        }
    }

    // MARK: Installing

    var selectedFile: IPSWFile? { library.first { $0.id == selectedIPSW } }

    func currentDevice(in app: AppModel) -> FirmwareDevice? {
        if let recoveryDevice { return FirmwareDevice(recoveryDevice) }
        if let device = app.selectedDevice, device.kind == .physical || device.kind == .demo { return FirmwareDevice(device) }
        return nil
    }

    func resetPreflight() {
        preflightRevision = UUID()
        preflight = []
        validatedInstall = nil
    }

    func canInstall(_ device: FirmwareDevice) -> Bool {
        guard !isInstalling, !isPreflighting, device.state != .demo, let file = selectedFile, let plan = validatedInstall else { return false }
        do {
            try plan.requireMatches(device.installSelection(ipsw: file.url, mode: mode))
            try plan.requireCurrent(now: Date())
            return true
        } catch { return false }
    }

    /// Produces a read-only readiness preview. Installation repeats all mandatory validation
    /// after confirmation, so neither a cached signing badge nor this preview can bypass it.
    func runPreflight(_ device: FirmwareDevice, app: AppModel) async {
        guard !isPreflighting, !isInstalling, let file = selectedFile else { return }
        isPreflighting = true
        defer { isPreflighting = false }
        _ = await validate(device.installSelection(ipsw: file.url, mode: mode), device: device, app: app)
    }

    private func validate(_ selection: FirmwareInstallSelection, device: FirmwareDevice, app: AppModel) async -> ValidatedFirmwareInstall? {
        resetPreflight()
        let revision = preflightRevision
        guard device.state != .demo, let helper = helper(.idevicerestore) else {
            preflight = [.init(title: "Install readiness", passed: false, detail: device.state == .demo ? "Demo Mode has no device." : helperProblem ?? "The firmware helper is unavailable.")]
            return nil
        }
        let paths: (cache: URL, log: URL)
        do { paths = try self.paths() } catch {
            preflight = [.init(title: "Install readiness", passed: false, detail: error.localizedDescription)]
            app.present(error)
            return nil
        }
        preflight = [.init(title: "Install readiness", passed: nil, detail: "Checking the file, exact device, install identity and Apple signing…")]
        let runner = app.runner
        let expected = releases.first { $0.fileName == selection.ipsw.lastPathComponent && $0.productType == selection.productType }?.sha1
        let failure = LockedValue<String?>(nil)
        let plan = await app.run("Validate firmware \(selection.mode.title)", workspace: .firmware, target: device.target, transport: "Local SHA-256, idevicerestore --no-action, Apple TSS", outputPaths: [paths.log.path], presentErrors: false) { operation in
            operation.report("Checking firmware and the connected device")
            do {
                return try await ValidatedFirmwareInstall.validate(selection: selection, helper: helper, cacheDirectory: paths.cache, logFile: paths.log,
                                                                  catalogSHA1: expected, runner: runner, signingTransport: AppleTSSTransport())
            } catch {
                failure.withLock { $0 = (error as? ToolkitError)?.message ?? error.localizedDescription }
                throw error
            }
        }
        lastLogFile = paths.log
        guard revision == preflightRevision else { return nil }
        guard let current = currentDevice(in: app), let file = selectedFile, current.installSelection(ipsw: file.url, mode: mode) == selection else {
            resetPreflight()
            preflight = [.init(title: "Install readiness", passed: false, detail: "The selected device, firmware or mode changed. Check again.")]
            return nil
        }
        guard let plan else {
            preflight = [.init(title: "\(selection.mode.title) unavailable", passed: false, detail: failure.current ?? "Validation was stopped. Check again before installing.")]
            return nil
        }
        validatedInstall = plan
        preflight = [
            .init(title: "Device identity", passed: true, detail: "Verified: \(plan.device.productType), \(plan.device.deviceClass.uppercased())."),
            .init(title: "\(selection.mode.title) identity", passed: true, detail: selection.mode == .update ? "Data-preserving Update identity verified." : "Erase identity verified. Restore erases all data."),
            .init(title: "Apple signing", passed: true, detail: "Signed for the matching install identity."),
            .init(title: "Installer preflight", passed: true, detail: "Passed for this device in \(plan.device.mode.rawValue) mode."),
            .init(title: "Download integrity", passed: plan.downloadIntegrity == .appleCatalogSHA1Matched ? true : nil, detail: plan.downloadIntegrity.explanation),
        ]
        return plan
    }

    private func paths() throws -> (cache: URL, log: URL) {
        let cache = cacheDirectory.appendingPathComponent("idevicerestore")
        try SecureFileIO.createPrivateDirectory(at: cache)
        try SecureFileIO.createPrivateDirectory(at: logDirectory)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        return (cache, logDirectory.appendingPathComponent("idevicerestore-\(stamp)-\(UUID().uuidString).log"))
    }

    /// Captures the confirmed selection, validates it afresh, and keeps ownership until the
    /// helper exits. Critical cancellation is refused even through the global operation button.
    func install(_ selection: FirmwareInstallSelection, device: FirmwareDevice, app: AppModel) async {
        guard !isInstalling, !isPreflighting, let file = selectedFile,
              let current = currentDevice(in: app), current == device,
              current.installSelection(ipsw: file.url, mode: mode) == selection else {
            app.present(ToolkitError.invalidInput("The confirmed device, firmware or install mode changed. Check again before installing."))
            return
        }
        isInstalling = true
        let protection = FirmwareWriteProtection(controller: FirmwareProcessTerminationControl())
        writeProtection = protection
        defer {
            protection.complete()
            writeProtection = nil
            installationTask = nil
            isInstalling = false
            pastPointOfNoReturn = false
        }
        let task = Task { await performInstall(selection, device: device, app: app, protection: protection) }
        installationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }

    /// Used by normal termination before writing. If a critical phase wins the cancellation
    /// race, refuse quit; otherwise wait for installation ownership to finish before replying.
    func cancelForTermination() async -> Bool {
        guard !terminationBlocked else { return false }
        guard let task = installationTask else { return true }
        task.cancel()
        guard !terminationBlocked else { return false }
        await task.value
        return !terminationBlocked
    }

    private func performInstall(_ selection: FirmwareInstallSelection, device: FirmwareDevice, app: AppModel, protection: FirmwareWriteProtection) async {
        guard let plan = await validate(selection, device: device, app: app), !Task.isCancelled else { return }
        let request: CommandRequest
        let paths: (cache: URL, log: URL)
        do {
            paths = try self.paths()
            request = try FirmwareInstall.request(plan: plan, cacheDirectory: paths.cache, logFile: paths.log, now: Date())
        } catch {
            app.present(error)
            return
        }
        installStep = FirmwareInstall.steps[0]
        installFraction = 0
        installLog = []
        pastPointOfNoReturn = false
        lastLogFile = paths.log
        let runner = app.runner
        let result = await app.run("\(selection.mode.title) iOS \(plan.productVersion) (\(plan.productBuild))", workspace: .firmware, target: device.target, transport: "idevicerestore", argv: request.arguments, outputPaths: [paths.log.path]) { operation in
                try await FirmwareInstall.run(plan: plan, cacheDirectory: paths.cache, logFile: paths.log, runner: runner, protection: protection, progress: { step, fraction in
                    operation.report(step, progress: fraction)
                    Task { @MainActor in
                        guard self.writeProtection === protection else { return }
                        self.installStep = step
                        self.installFraction = fraction
                        if protection.isCritical { self.pastPointOfNoReturn = true }
                    }
                }, line: { line in
                    Task { @MainActor in
                        guard self.writeProtection === protection else { return }
                        if protection.isCritical { self.pastPointOfNoReturn = true }
                        self.installLog.append(line)
                        if self.installLog.count > 500 { self.installLog.removeFirst(100) }
                    }
                })
        }
        if result != nil {
            installStep = "Done"
            installFraction = 1
            app.statusMessage = "iOS \(plan.productVersion) (\(plan.productBuild)) was installed on \(device.name). The device restarts and finishes setting up."
        }
    }

    func revealLog() {
        if let lastLogFile { NSWorkspace.shared.activateFileViewerSelecting([lastLogFile]) }
    }
}
