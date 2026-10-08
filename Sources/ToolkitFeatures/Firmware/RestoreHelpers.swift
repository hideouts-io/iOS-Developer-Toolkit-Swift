import Foundation
import ToolkitCore

/// The firmware helpers bundled with the app: `idevicerestore` and `irecovery` from the
/// libimobiledevice project, built by `scripts/build-restore-helpers.sh` and shipped in
/// `Contents/Helpers`. They are separate programs, run only through `CommandRunner` with argument
/// vectors (idevicerestore is LGPL-3.0; its libraries LGPL-2.1).
public enum RestoreHelper: String, CaseIterable, Sendable {
    case idevicerestore
    case irecovery

    /// Where the helper is: the app's `Contents/Helpers`, or `IDT_RESTORE_HELPERS` (a folder, for
    /// development and tests).
    public func locate(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        var candidates: [URL] = []
        if let folder = environment["IDT_RESTORE_HELPERS"], !folder.isEmpty {
            candidates.append(URL(fileURLWithPath: folder).appendingPathComponent(rawValue))
        }
        candidates.append(bundle.bundleURL.appendingPathComponent("Contents/Helpers/\(rawValue)"))
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw ToolkitError(.toolMissing, message: "The firmware tools are not included in this build.", recovery: "Use a release build of the app, or run scripts/build-restore-helpers.sh and set IDT_RESTORE_HELPERS to its bin folder.", technicalDetail: "Checked: " + candidates.map(\.path).joined(separator: ", "))
    }
}

// MARK: - Recovery and DFU mode

/// A device in recovery or DFU mode, as `irecovery -q` reports it.
public struct RecoveryDevice: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        case recovery
        case dfu
        case other(String)

        public var label: String {
            switch self {
            case .recovery: return "Recovery mode"
            case .dfu: return "DFU mode"
            case .other(let text): return text
            }
        }
    }

    public var mode: Mode
    public var ecid: String
    public var chipID: String?
    public var boardID: String?
    public var productType: String?
    public var model: String?
}

public enum RecoveryProbe {
    public static func queryRequest(helper: URL) -> CommandRequest {
        CommandRequest(executable: helper, arguments: ["-q"], timeout: 20, displayName: "irecovery -q")
    }

    /// Asks a device in recovery mode to restart normally (`irecovery -n`).
    public static func exitRecoveryRequest(helper: URL, ecid: String) throws -> CommandRequest {
        guard ecid.range(of: #"^(0x)?[0-9A-Fa-f]{1,16}$"#, options: .regularExpression) != nil else {
            throw ToolkitError.invalidInput("That is not a device ECID.")
        }
        return CommandRequest(executable: helper, arguments: ["-i", ecid, "-n"], timeout: 60, displayName: "irecovery -n")
    }

    /// Parses `irecovery -q` (`KEY: value` lines). `nil` when no device answered.
    public static func parse(_ output: String) -> RecoveryDevice? {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !key.contains(" ") { fields[key] = value }
        }
        guard let ecid = fields["ECID"], let modeText = fields["MODE"] else { return nil }
        let mode: RecoveryDevice.Mode
        switch modeText.lowercased() {
        case "recovery": mode = .recovery
        case "dfu": mode = .dfu
        default: mode = .other(modeText)
        }
        return RecoveryDevice(mode: mode, ecid: ecid, chipID: fields["CPID"], boardID: fields["BDID"], productType: fields["PRODUCT"], model: fields["MODEL"])
    }
}

// MARK: - Installing firmware

public enum FirmwareInstall {
    public enum Mode: String, Sendable, CaseIterable {
        /// Installs the firmware and keeps the device's data (like Finder's Update).
        case update
        /// Erases the device and installs the firmware (like Finder's Restore).
        case restore

        public var title: String { self == .update ? "Update" : "Restore" }
        public var explanation: String {
            switch self {
            case .update: return "Installs this firmware and keeps apps, settings, and data."
            case .restore: return "Erases everything on the device, then installs this firmware. Back up first. After a restore, the device may ask for the Apple Account it was set up with (Activation Lock)."
            }
        }
    }

    /// The device to install on: by UDID in normal mode, by ECID in recovery or DFU mode.
    public enum Target: Sendable, Hashable {
        case udid(String)
        case ecid(String)
    }

    /// Finds the selected device and reads its mode and identity. The pinned helper exits before
    /// checking firmware compatibility or signing; the validated plan performs those separately.
    public static func preflightRequest(helper: URL, ipsw: URL, mode: Mode, target: Target, cacheDirectory: URL, logFile: URL) throws -> CommandRequest {
        let arguments = try commandArguments(ipsw: ipsw, mode: mode, target: target, cacheDirectory: cacheDirectory, logFile: logFile)
        return CommandRequest(executable: helper, arguments: arguments + ["--no-action", ipsw.path], timeout: 60, displayName: "idevicerestore (preflight)")
    }

    /// The only install command constructor consumes a validated plan. Pinning the exact variant
    /// prevents the default Update mode's erase fallback in idevicerestore 60192e97f87d.
    public static func request(plan: ValidatedFirmwareInstall, cacheDirectory: URL, logFile: URL, now: Date) throws -> CommandRequest {
        try plan.requireCurrent(now: now)
        guard let variant = plan.buildIdentity.variant else { throw ToolkitError.invalidInput("The validated firmware has no install variant.") }
        let arguments = try commandArguments(ipsw: plan.selection.ipsw, mode: plan.selection.mode,
                                             target: .ecid("0x" + String(plan.device.ecid, radix: 16)), cacheDirectory: cacheDirectory, logFile: logFile)
        return CommandRequest(executable: plan.helper, arguments: arguments + ["--variant", variant, plan.selection.ipsw.path], timeout: nil,
                              displayName: "idevicerestore (\(plan.selection.mode.rawValue))")
    }

    static func ecid(_ text: String) -> UInt64? {
        let number = text.lowercased().hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text, radix: 10)
        guard let number, number > 0 else { return nil }
        return number
    }

    private static func commandArguments(ipsw: URL, mode: Mode, target: Target, cacheDirectory: URL, logFile: URL) throws -> [String] {
        guard ipsw.pathExtension.lowercased() == "ipsw", FileManager.default.fileExists(atPath: ipsw.path) else {
            throw ToolkitError.invalidInput("Choose an .ipsw file.")
        }
        var arguments = ["--plain-progress", "--no-input", "--cache-path", cacheDirectory.path, "--logfile", logFile.path]
        switch target {
        case .udid(let udid):
            guard udid.range(of: #"^[0-9A-Fa-f-]{24,40}$"#, options: .regularExpression) != nil else { throw ToolkitError.invalidInput("That is not a device UDID.") }
            arguments += ["--udid", udid]
        case .ecid(let ecid):
            guard let number = Self.ecid(ecid) else { throw ToolkitError.invalidInput("That is not a nonzero decimal or hexadecimal device ECID.") }
            arguments += ["--ecid", "0x" + String(number, radix: 16)]
        }
        if mode == .restore { arguments.append("--erase") }
        return arguments
    }

    /// The stages idevicerestore reports (`RESTORE_STEP_*`).
    public static let steps = [
        "Finding the device", "Preparing", "Sending the system", "Verifying the system",
        "Installing firmware", "Installing baseband firmware", "Updating accessories firmware", "Sending images",
    ]

    /// Parses a `--plain-progress` line: `progress: <step> <fraction>`.
    public static func progress(_ line: Substring) -> (step: String, fraction: Double)? {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "progress:", let step = Int(parts[1]), let fraction = Double(parts[2]), fraction.isFinite else { return nil }
        let name = steps.indices.contains(step) ? steps[step] : "Step \(step)"
        return (name, min(max(fraction, 0), 1))
    }

    /// Whether stopping now could leave the device unusable until it is restored again.
    public static func isPastPointOfNoReturn(step: String) -> Bool {
        guard let index = steps.firstIndex(of: step) else { return true }
        return index >= 2
    }

    /// A plain-language reason for a failed run, from idevicerestore's output.
    public static func failureReason(output: String) -> String {
        let lower = output.lowercased()
        if lower.contains("isn't eligible") || lower.contains("not eligible") || lower.contains("status 94") {
            return "Apple does not sign this firmware for this device any more, so it cannot be installed."
        }
        if lower.contains("unable to find device") || lower.contains("no device found") || lower.contains("unable to discover device") {
            return "The device could not be found. Keep it connected by USB and unlocked (or in recovery mode) and try again."
        }
        if lower.contains("product type") && lower.contains("not") {
            return "This firmware is not for this device model."
        }
        if let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("ERROR:") }) {
            return String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        return "The firmware tool stopped with an error."
    }
}

extension RecoveryProbe {
    /// The device in recovery or DFU mode, if one is connected. Never changes anything.
    public static func query(runner: CommandRunning, helper: URL) async -> RecoveryDevice? {
        guard let result = try? await runner.run(queryRequest(helper: helper)), result.succeeded else { return nil }
        return parse(result.standardOutputText)
    }
}

extension FirmwareInstall {
    /// Owns the helper independently of cancellation of the application operation. Critical
    /// cancellation is refused, and protection is released only when that helper has finished.
    public static func run(plan: ValidatedFirmwareInstall, cacheDirectory: URL, logFile: URL, runner: OwnedCommandRunning, protection: FirmwareWriteProtection,
                           progress: @escaping @Sendable (_ step: String, _ fraction: Double) -> Void,
                           line: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        defer { protection.complete() }
        try Task.checkCancellation()
        let request = try request(plan: plan, cacheDirectory: cacheDirectory, logFile: logFile, now: Date())
        let cancellation = CommandCancellation()
        let helperTask = Task {
            defer { protection.complete() }
            return try await consume(request, events: runner.stream(request, cancellation: cancellation), progress: { step, fraction in
                protection.receiveProgress(step: step, fraction: fraction)
                progress(step, fraction)
            }, line: { output in
                protection.receiveOutput(output)
                line(output)
            })
        }
        return try await withTaskCancellationHandler {
            try await helperTask.value
        } onCancel: {
            if !protection.cancelBeforeWriting({ cancellation.cancel() }), protection.isCritical {
                line("Firmware is being written. Stop and normal Quit are disabled until the installer exits.")
            }
        }
    }

    /// Streams one helper command. Internal so an application install cannot accept an arbitrary
    /// command vector instead of a validated plan.
    static func run(_ request: CommandRequest, runner: CommandRunning,
                           progress: @escaping @Sendable (_ step: String, _ fraction: Double) -> Void,
                           line: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        try await consume(request, events: runner.stream(request), progress: progress, line: line)
    }

    private static func consume(_ request: CommandRequest, events: AsyncThrowingStream<CommandStreamEvent, Error>,
                                progress: @escaping @Sendable (_ step: String, _ fraction: Double) -> Void,
                                line: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        var output = LineSplitter(), errors = LineSplitter()
        var transcript: [String] = []
        func handle(_ lines: [Substring]) {
            for text in lines {
                if let update = Self.progress(text) {
                    progress(update.step, update.fraction)
                } else if text.hasPrefix("progress:") {
                    progress("Unknown installer stage", 0)
                } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    transcript.append(String(text))
                    if transcript.count > 2_000 { transcript.removeFirst(500) }
                    line(String(text))
                }
            }
        }
        var final: CommandResult?
        for try await event in events {
            switch event {
            case .standardOutput(let data): handle(output.consume(data))
            case .standardError(let data): handle(errors.consume(data))
            case .finished(let result): final = result
            }
        }
        handle(output.flush())
        handle(errors.flush())
        try Task.checkCancellation()
        guard let final else { throw ToolkitError(.internalInconsistency, message: "\(request.displayName) ended without a result.") }
        guard final.succeeded else {
            throw ToolkitError(.commandFailed, message: failureReason(output: transcript.joined(separator: "\n")),
                               recovery: "The full log is in the firmware folder. If the device is stuck in recovery mode, install the firmware again with Restore.",
                               technicalDetail: final.technicalSummary)
        }
        return final
    }
}

/// The checks made before installing, so a firmware that cannot be installed is caught before the
/// device is touched.
public enum FirmwarePreflight {
    public struct Check: Sendable, Hashable, Identifiable {
        public var id: String { title }
        public var title: String
        /// `nil` while the check has not run.
        public var passed: Bool?
        public var detail: String

        public init(title: String, passed: Bool?, detail: String) {
            self.title = title
            self.passed = passed
            self.detail = detail
        }
    }

    /// The checks that need only the IPSW and the device's model.
    public static func localChecks(ipsw: IPSWFile, productType: String?, deviceClass: String?, mode: FirmwareInstall.Mode) -> [Check] {
        var checks: [Check] = []
        if let productType {
            let supported = ipsw.supports(productType: productType)
            checks.append(Check(title: "Made for this model", passed: supported,
                                detail: supported ? "\(ipsw.title) supports \(productType)." : "\(ipsw.title) is for \(ipsw.manifest.supportedProductTypes.joined(separator: ", ")), not \(productType)."))
        } else {
            checks.append(Check(title: "Device identity", passed: false, detail: "The device's product type is not known. Check the connected device before installing."))
        }
        let behavior = mode == .update ? "Update" : "Erase"
        let identity = try? installIdentity(manifest: ipsw.manifest, productType: productType, deviceClass: deviceClass, chipID: nil, boardID: nil, mode: mode)
        checks.append(Check(title: mode == .update ? "Can update in place" : "Can restore",
                            passed: identity != nil,
                            detail: identity != nil ? "The firmware has a matching \(behavior.lowercased()) install for this device." : "A matching \(behavior.lowercased()) identity has not been established.\(mode == .update ? " Restore may be available, but Restore erases all data." : "")"))
        return checks
    }

    /// Mirrors the pinned helper's exact DeviceClass/variant selection and refuses duplicate
    /// variants, missing board identity, and behavior mismatches rather than guessing an identity.
    public static func installIdentity(manifest: FirmwareManifest, productType: String?, deviceClass: String?, chipID: Int?, boardID: Int?, mode: FirmwareInstall.Mode) throws -> FirmwareManifest.Identity {
        guard let productType, manifest.supportedProductTypes.contains(productType) else {
            throw ToolkitError.invalidInput("This firmware is not verified for the selected product type.")
        }
        guard let deviceClass, !deviceClass.isEmpty else {
            throw ToolkitError.invalidInput("The device's board identity is unknown. Check the connected device before installing.")
        }
        let behavior = mode == .update ? "Update" : "Erase"
        let variant = mode == .update ? "Customer Upgrade Install (IPSW)" : "Customer Erase Install (IPSW)"
        let matches = manifest.identities.filter { $0.deviceClass?.lowercased() == deviceClass.lowercased() && $0.variant == variant }
        guard matches.count == 1, let identity = matches.first, identity.restoreBehavior == behavior,
              identity.chipID > 0, identity.boardID >= 0, identity.securityDomain > 0,
              identity.uniqueBuildID?.isEmpty == false, !identity.manifest.isEmpty,
              (chipID == nil || chipID == identity.chipID), (boardID == nil || boardID == identity.boardID),
              (identity.values["Ap,ProductType"] == nil || identity.values["Ap,ProductType"]?.stringValue == productType) else {
            throw ToolkitError(.invalidInput, message: mode == .update ? "Update is unavailable: this IPSW has no unambiguous data-preserving Update identity for this device." : "Restore is unavailable: this IPSW has no unambiguous erase identity for this device.",
                               recovery: mode == .update ? "Restore may be available, but Restore erases all data and needs separate confirmation." : "Choose firmware for the exact device model and board.")
        }
        return identity
    }

    public static func signingCheck(_ status: FirmwareSigning.Status) -> Check {
        Check(title: "Signed by Apple", passed: status == .signed ? true : (status == .notSigned ? false : nil), detail: status.explanation)
    }
}
