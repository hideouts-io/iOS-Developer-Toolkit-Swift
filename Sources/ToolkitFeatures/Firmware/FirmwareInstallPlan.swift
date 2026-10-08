import Darwin
import DeviceKit
import Foundation
import ToolkitCore

/// The file and device the user confirmed. None of these values are read from the UI later.
public struct FirmwareInstallSelection: Sendable, Hashable {
    public let ipsw: URL
    public let target: FirmwareInstall.Target
    public let productType: String?
    public let deviceClass: String?
    public let chipID: Int?
    public let boardID: Int?
    public let mode: FirmwareInstall.Mode

    public init(ipsw: URL, target: FirmwareInstall.Target, productType: String?, deviceClass: String?, chipID: Int?, boardID: Int?, mode: FirmwareInstall.Mode) {
        self.ipsw = ipsw.standardizedFileURL
        self.target = target
        self.productType = productType
        self.deviceClass = deviceClass?.lowercased()
        self.chipID = chipID
        self.boardID = boardID
        self.mode = mode
    }
}

/// A local SHA-256 binds the bytes; inode, size and change times detect a later replacement or
/// edit, including one that restores the modification time. This is not Apple provenance.
public struct FirmwareFileIdentity: Sendable, Hashable {
    struct Metadata: Sendable, Hashable {
        let volume: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    let metadata: Metadata
    public let sha1: String
    public let sha256: String

    static func read(_ url: URL) throws -> Self {
        let before = try attributes(url)
        let sums = try IPSWLibrary.checksums(of: url)
        guard before == (try attributes(url)) else { throw changedFile() }
        return Self(metadata: before, sha1: sums.sha1, sha256: sums.sha256)
    }

    func requireUnchanged(_ url: URL) throws {
        guard metadata == (try Self.attributes(url)) else { throw Self.changedFile() }
    }

    private static func attributes(_ url: URL) throws -> Metadata {
        guard url.isFileURL else { throw ToolkitError.invalidInput("Firmware and restore helpers must be local files.") }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw ToolkitError.fileSystem("The file could not be read for firmware validation.", path: url.path)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else {
            throw ToolkitError.invalidInput("Firmware validation requires a nonempty regular file, not a symbolic link.")
        }
        return Metadata(volume: info.st_dev, inode: info.st_ino, size: info.st_size,
                        modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                        changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
    }

    private static func changedFile() -> ToolkitError {
        ToolkitError(.invalidInput, message: "The firmware or restore helper changed after validation.", recovery: "Check Before Installing again. Nothing was installed.")
    }
}

/// The identity freshly reported by the pinned helper's read-only device detection.
public struct FirmwareInstallerDevice: Sendable, Hashable {
    public enum Mode: String, Sendable { case normal, recovery, dfu }
    public let ecid: UInt64
    public let productType: String
    public let deviceClass: String
    public let mode: Mode

    static func parse(_ output: String) throws -> Self {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let ecids = lines.filter { $0.hasPrefix("ECID: ") }
        let devices = lines.filter { $0.hasPrefix("Identified device as ") }
        let modes = lines.filter { $0.hasPrefix("Found device in ") && $0.hasSuffix(" mode") }
        guard ecids.count == 1, devices.count == 1, modes.count == 1,
              let ecid = UInt64(ecids[0].dropFirst("ECID: ".count)), ecid > 0 else {
            throw ToolkitError(.protocolViolation, message: "The installer did not report one exact device identity.", recovery: "Reconnect only the intended device and check again.")
        }
        let identity = devices[0].dropFirst("Identified device as ".count).split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let modeText = modes[0].dropFirst("Found device in ".count).dropLast(" mode".count).lowercased()
        guard identity.count == 2, !identity[0].isEmpty, !identity[1].isEmpty, let mode = Mode(rawValue: modeText) else {
            throw ToolkitError(.protocolViolation, message: "The installer reported an unsupported device or mode.", recovery: "Reconnect the device in normal, recovery or DFU mode and check again.")
        }
        return Self(ecid: ecid, productType: identity[1], deviceClass: identity[0].lowercased(), mode: mode)
    }
}

/// Created only by mandatory validation. The signing result applies to this exact manifest
/// identity, with a random ECID/nonce; the installer still personalizes the real device itself.
public struct ValidatedFirmwareInstall: Sendable {
    public let selection: FirmwareInstallSelection
    public let fileIdentity: FirmwareFileIdentity
    public let productVersion: String
    public let productBuild: String
    public let device: FirmwareInstallerDevice
    public let buildIdentity: FirmwareManifest.Identity
    public let signing: FirmwareSigning.Status
    public let installerPreflight: CommandResult
    public let downloadIntegrity: FirmwareDownloadProvenance
    public let validatedAt: Date
    public let helper: URL
    public let helperIdentity: FirmwareFileIdentity

    /// Limits reuse of a read-only preview. The application performs fresh validation after
    /// confirmation; no preview is treated as permission to skip signing or device detection.
    public static let maximumAge: TimeInterval = 120

    private init(selection: FirmwareInstallSelection, fileIdentity: FirmwareFileIdentity, manifest: FirmwareManifest, device: FirmwareInstallerDevice,
                 buildIdentity: FirmwareManifest.Identity, signing: FirmwareSigning.Status, installerPreflight: CommandResult,
                 downloadIntegrity: FirmwareDownloadProvenance, validatedAt: Date, helper: URL, helperIdentity: FirmwareFileIdentity) {
        self.selection = selection
        self.fileIdentity = fileIdentity
        productVersion = manifest.productVersion
        productBuild = manifest.productBuild
        self.device = device
        self.buildIdentity = buildIdentity
        self.signing = signing
        self.installerPreflight = installerPreflight
        self.downloadIntegrity = downloadIntegrity
        self.validatedAt = validatedAt
        self.helper = helper
        self.helperIdentity = helperIdentity
    }

    public func requireMatches(_ selection: FirmwareInstallSelection) throws {
        guard self.selection == selection else {
            throw ToolkitError(.invalidInput, message: "The device, firmware or install mode differs from the validated selection.", recovery: "Check Before Installing again.")
        }
    }

    public func requireCurrent(now: Date) throws {
        guard now >= validatedAt, now.timeIntervalSince(validatedAt) <= Self.maximumAge,
              now.timeIntervalSince(installerPreflight.finishedAt) <= Self.maximumAge else {
            throw ToolkitError(.invalidInput, message: "Firmware validation has expired.", recovery: "Check signing and the connected device again before installing.")
        }
        try fileIdentity.requireUnchanged(selection.ipsw)
        try helperIdentity.requireUnchanged(helper)
    }

    /// Hashes and rereads the IPSW, detects the exact target, selects the helper's exact variant,
    /// and makes a fresh TSS request. Every failure refuses installation, including unknown TSS.
    public static func validate(selection: FirmwareInstallSelection, helper: URL, cacheDirectory: URL, logFile: URL,
                                catalogSHA1: String?, runner: CommandRunning, signingTransport: PersonalizationTransport) async throws -> Self {
        try Task.checkCancellation()
        let fileIdentity = try FirmwareFileIdentity.read(selection.ipsw)
        let file = try IPSWLibrary.inspect(selection.ipsw)
        try fileIdentity.requireUnchanged(selection.ipsw)
        let integrity = try FirmwareDownloadProvenance.assess(sha1: fileIdentity.sha1, catalogSHA1: catalogSHA1)
        guard integrity != .digestMismatch else {
            throw ToolkitError(.invalidInput, message: "This IPSW does not match Apple's catalog checksum.", recovery: "Download the firmware again. Nothing was installed.")
        }
        let helperIdentity = try FirmwareFileIdentity.read(helper)
        let request = try FirmwareInstall.preflightRequest(helper: helper, ipsw: selection.ipsw, mode: selection.mode,
                                                          target: selection.target, cacheDirectory: cacheDirectory, logFile: logFile)
        let result = try await runner.run(request)
        guard result.request == request, result.succeeded else {
            throw ToolkitError(.commandFailed, message: FirmwareInstall.failureReason(output: result.standardOutputText + "\n" + result.standardErrorText),
                               recovery: "The installer preflight failed. Reconnect the device and check again.", technicalDetail: result.technicalSummary)
        }
        let device = try FirmwareInstallerDevice.parse(result.standardOutputText)
        if case .ecid(let expected) = selection.target {
            guard FirmwareInstall.ecid(expected) == device.ecid else {
                throw ToolkitError.invalidInput("The installer found a different device. Select the intended device and check again.")
            }
        }
        guard (selection.productType == nil || selection.productType == device.productType),
              (selection.deviceClass == nil || selection.deviceClass == device.deviceClass) else {
            throw ToolkitError.invalidInput("The connected device does not match the selected model or board. Refresh the device list and check again.")
        }
        guard selection.mode != .update || device.mode != .dfu else {
            throw ToolkitError.invalidInput("Update is unavailable in DFU mode. Restore is available only with erase confirmation.")
        }
        let identity = try FirmwarePreflight.installIdentity(manifest: file.manifest, productType: device.productType, deviceClass: device.deviceClass,
                                                            chipID: selection.chipID, boardID: selection.boardID, mode: selection.mode)
        let signing = await FirmwareSigning.check(identity: identity, transport: signingTransport)
        try Task.checkCancellation()
        guard signing == .signed else {
            throw ToolkitError(.serviceUnavailable, message: signing == .notSigned ? "Apple rejected signing for this device's matching install identity." : "Apple signing could not be verified for the matching install identity.",
                               recovery: "Installation is blocked. Check signing again when this Mac can reach Apple.", technicalDetail: signing.explanation)
        }
        let plan = Self(selection: selection, fileIdentity: fileIdentity, manifest: file.manifest, device: device, buildIdentity: identity,
                        signing: signing, installerPreflight: result, downloadIntegrity: integrity, validatedAt: Date(), helper: helper, helperIdentity: helperIdentity)
        try plan.requireCurrent(now: Date())
        return plan
    }
}
