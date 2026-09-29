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
    var selectedIPSW: String?
    var mode: FirmwareInstall.Mode = .update
    private(set) var preflight: [FirmwarePreflight.Check] = []
    private(set) var isPreflighting = false
    private(set) var isInstalling = false
    private(set) var installStep: String?
    private(set) var installFraction: Double = 0
    private(set) var installLog: [String] = []
    private(set) var pastPointOfNoReturn = false
    private(set) var lastLogFile: URL?

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
        guard !checkingSigning.contains(release.build) else { return }
        checkingSigning.insert(release.build)
        defer { checkingSigning.remove(release.build) }
        let status = await app.run("Check signing for \(release.version)", workspace: .firmware, target: nil, transport: "gs.apple.com (TSS)", presentErrors: false) { _ in
            let manifest = try FirmwareManifest.parse(try await RemoteArchive.file(named: FirmwareManifest.fileName, in: release.url))
            guard let identity = manifest.identity(deviceClass: deviceClass) ?? manifest.identity() else {
                return FirmwareSigning.Status.unknown("The firmware has no install for this device model.")
            }
            return await FirmwareSigning.check(identity: identity)
        }
        signing[release.build] = status ?? .unknown("The firmware's build manifest could not be read from Apple's server.")
    }

    func checkSigning(_ file: IPSWFile, deviceClass: String?, app: AppModel) async {
        guard !checkingSigning.contains(file.id) else { return }
        checkingSigning.insert(file.id)
        defer { checkingSigning.remove(file.id) }
        guard let identity = file.manifest.identity(deviceClass: deviceClass) ?? file.manifest.identity() else {
            signing[file.id] = .unknown("The firmware has no install for this device model.")
            return
        }
        let status = await app.run("Check signing for \(file.title)", workspace: .firmware, target: nil, transport: "gs.apple.com (TSS)", presentErrors: false) { _ in
            await FirmwareSigning.check(identity: identity)
        }
        signing[file.id] = status ?? .unknown("Apple's signing server could not be reached.")
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
                verification[result.path] = "Matches Apple's checksum (SHA-1)."
                app.statusMessage = "Downloaded \(release.fileName) and verified it."
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

    func resetPreflight() { preflight = [] }

    /// Checks the model, the build identity, Apple's signing, and that idevicerestore finds the
    /// device (`--no-action`). Nothing on the device is changed.
    func runPreflight(_ device: FirmwareDevice, app: AppModel) async {
        guard let file = selectedFile, let helper = helper(.idevicerestore) else { return }
        isPreflighting = true
        defer { isPreflighting = false }
        var checks = FirmwarePreflight.localChecks(ipsw: file, productType: device.productType, deviceClass: device.deviceClass, mode: mode)
        preflight = checks + [FirmwarePreflight.Check(title: "Signed by Apple", passed: nil, detail: "Checking…"), FirmwarePreflight.Check(title: "Device found by the installer", passed: nil, detail: "Checking…")]
        await checkSigning(file, deviceClass: device.deviceClass, app: app)
        checks.append(FirmwarePreflight.signingCheck(signing[file.id] ?? .unknown("Not checked.")))
        preflight = checks + [FirmwarePreflight.Check(title: "Device found by the installer", passed: nil, detail: "Checking…")]
        if case .demo = device.state {
            checks.append(FirmwarePreflight.Check(title: "Device found by the installer", passed: false, detail: "Demo Mode has no device."))
        } else {
            checks.append(await detect(device, file: file, helper: helper, app: app))
        }
        preflight = checks
    }

    private func detect(_ device: FirmwareDevice, file: IPSWFile, helper: URL, app: AppModel) async -> FirmwarePreflight.Check {
        let runner = app.runner
        guard let paths = try? self.paths() else { return FirmwarePreflight.Check(title: "Device found by the installer", passed: false, detail: "The firmware folder could not be created.") }
        let mode = mode
        let output = LockedValue<[String]>([])
        let request: CommandRequest
        do {
            request = try FirmwareInstall.request(helper: helper, ipsw: file.url, mode: mode, target: device.installTarget, cacheDirectory: paths.cache, logFile: paths.log, preflightOnly: true)
        } catch {
            return FirmwarePreflight.Check(title: "Device found by the installer", passed: false, detail: (error as? ToolkitError)?.message ?? error.localizedDescription)
        }
        let result = await app.run("Firmware preflight", workspace: .firmware, target: device.target, transport: "idevicerestore --no-action", argv: request.arguments, outputPaths: [paths.log.path], presentErrors: false) { _ in
            try await FirmwareInstall.run(request, runner: runner, progress: { _, _ in }, line: { line in output.withLock { $0.append(line) } })
        }
        lastLogFile = paths.log
        if result != nil {
            let found = output.current.last { $0.localizedCaseInsensitiveContains("found device in") || $0.localizedCaseInsensitiveContains("mode") }
            return FirmwarePreflight.Check(title: "Device found by the installer", passed: true, detail: found ?? "idevicerestore found the device.")
        }
        return FirmwarePreflight.Check(title: "Device found by the installer", passed: false, detail: FirmwareInstall.failureReason(output: output.current.joined(separator: "\n")))
    }

    private func paths() throws -> (cache: URL, log: URL) {
        let cache = cacheDirectory.appendingPathComponent("idevicerestore")
        try SecureFileIO.createPrivateDirectory(at: cache)
        try SecureFileIO.createPrivateDirectory(at: logDirectory)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        return (cache, logDirectory.appendingPathComponent("idevicerestore-\(stamp).log"))
    }

    /// Installs the selected firmware. Stop works until the system starts being written; after
    /// that the install always runs to the end, because stopping would leave the device unusable.
    func install(_ device: FirmwareDevice, app: AppModel) async {
        guard let file = selectedFile, let helper = helper(.idevicerestore), !isInstalling else { return }
        let request: CommandRequest
        let logFile: URL
        do {
            let paths = try paths()
            logFile = paths.log
            request = try FirmwareInstall.request(helper: helper, ipsw: file.url, mode: mode, target: device.installTarget, cacheDirectory: paths.cache, logFile: paths.log, preflightOnly: false)
        } catch {
            app.present(error)
            return
        }
        isInstalling = true
        installStep = FirmwareInstall.steps[0]
        installFraction = 0
        installLog = []
        pastPointOfNoReturn = false
        lastLogFile = logFile
        defer { isInstalling = false }
        let runner = app.runner
        let committed = LockedValue(false)
        let result = await app.run("\(mode.title) \(file.title)", workspace: .firmware, target: device.target, transport: "idevicerestore", argv: request.arguments, outputPaths: [logFile.path]) { operation in
            let helperTask = Task {
                try await FirmwareInstall.run(request, runner: runner, progress: { step, fraction in
                    if FirmwareInstall.isPastPointOfNoReturn(step: step) { committed.withLock { $0 = true } }
                    operation.report(step, progress: fraction)
                    Task { @MainActor in
                        self.installStep = step
                        self.installFraction = fraction
                        if FirmwareInstall.isPastPointOfNoReturn(step: step) { self.pastPointOfNoReturn = true }
                    }
                }, line: { line in
                    Task { @MainActor in
                        self.installLog.append(line)
                        if self.installLog.count > 500 { self.installLog.removeFirst(100) }
                    }
                })
            }
            return try await withTaskCancellationHandler {
                try await helperTask.value
            } onCancel: {
                if committed.current {
                    operation.report("Can't stop now: the system is being written. Keep the device connected.")
                } else {
                    helperTask.cancel()
                }
            }
        }
        if result != nil {
            installStep = "Done"
            installFraction = 1
            app.statusMessage = "\(file.title) was installed on \(device.name). The device restarts and finishes setting up."
        }
    }

    func revealLog() {
        if let lastLogFile { NSWorkspace.shared.activateFileViewerSelecting([lastLogFile]) }
    }
}
