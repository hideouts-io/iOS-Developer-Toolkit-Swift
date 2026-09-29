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

    /// Builds the idevicerestore command. `preflightOnly` (`--no-action`) only finds the device and
    /// reads its mode and model, then stops; nothing on the device is changed.
    public static func request(helper: URL, ipsw: URL, mode: Mode, target: Target, cacheDirectory: URL, logFile: URL, preflightOnly: Bool) throws -> CommandRequest {
        guard ipsw.pathExtension.lowercased() == "ipsw", FileManager.default.fileExists(atPath: ipsw.path) else {
            throw ToolkitError.invalidInput("Choose an .ipsw file.")
        }
        var arguments = ["--plain-progress", "--no-input", "--cache-path", cacheDirectory.path, "--logfile", logFile.path]
        switch target {
        case .udid(let udid):
            guard udid.range(of: #"^[0-9A-Fa-f-]{24,40}$"#, options: .regularExpression) != nil else { throw ToolkitError.invalidInput("That is not a device UDID.") }
            arguments += ["--udid", udid]
        case .ecid(let ecid):
            guard ecid.range(of: #"^(0x)?[0-9A-Fa-f]{1,16}$"#, options: .regularExpression) != nil else { throw ToolkitError.invalidInput("That is not a device ECID.") }
            arguments += ["--ecid", ecid]
        }
        if mode == .restore { arguments.append("--erase") }
        if preflightOnly { arguments.append("--no-action") }
        arguments.append(ipsw.path)
        return CommandRequest(executable: helper, arguments: arguments, environment: CommandEnvironment.minimal(), timeout: nil, displayName: preflightOnly ? "idevicerestore (preflight)" : "idevicerestore (\(mode.rawValue))")
    }

    /// The stages idevicerestore reports (`RESTORE_STEP_*`).
    public static let steps = [
        "Finding the device", "Preparing", "Sending the system", "Verifying the system",
        "Installing firmware", "Installing baseband firmware", "Updating accessories firmware", "Sending images",
    ]

    /// Parses a `--plain-progress` line: `progress: <step> <fraction>`.
    public static func progress(_ line: Substring) -> (step: String, fraction: Double)? {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "progress:", let step = Int(parts[1]), let fraction = Double(parts[2]) else { return nil }
        let name = steps.indices.contains(step) ? steps[step] : "Step \(step)"
        return (name, min(max(fraction, 0), 1))
    }

    /// Whether stopping now could leave the device unusable until it is restored again.
    public static func isPastPointOfNoReturn(step: String) -> Bool {
        guard let index = steps.firstIndex(of: step) else { return false }
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
    /// Runs idevicerestore, reporting each progress step and every other output line. Throws a
    /// plain-language error when it fails; stopping the task stops the helper.
    public static func run(_ request: CommandRequest, runner: CommandRunning,
                           progress: @escaping @Sendable (_ step: String, _ fraction: Double) -> Void,
                           line: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        var output = LineSplitter(), errors = LineSplitter()
        var transcript: [String] = []
        func handle(_ lines: [Substring]) {
            for text in lines {
                if let update = Self.progress(text) {
                    progress(update.step, update.fraction)
                } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    transcript.append(String(text))
                    if transcript.count > 2_000 { transcript.removeFirst(500) }
                    line(String(text))
                }
            }
        }
        var final: CommandResult?
        for try await event in runner.stream(request) {
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
        }
        let behavior = mode == .update ? "Update" : "Erase"
        let identity = ipsw.manifest.identities.first { ($0.restoreBehavior == behavior) && (deviceClass == nil || $0.deviceClass?.lowercased() == deviceClass?.lowercased()) }
        checks.append(Check(title: mode == .update ? "Can update in place" : "Can restore",
                            passed: identity != nil,
                            detail: identity != nil ? "The firmware has a \(behavior.lowercased()) install for this device." : "The firmware has no \(behavior.lowercased()) install for this device\(mode == .update ? "; use Restore instead" : "")."))
        return checks
    }

    public static func signingCheck(_ status: FirmwareSigning.Status) -> Check {
        Check(title: "Signed by Apple", passed: status == .signed ? true : (status == .notSigned ? false : nil), detail: status.explanation)
    }
}
