import DeviceKit
import Foundation
import ToolkitCore

/// The parts of an IPSW's `BuildManifest.plist` the toolkit uses.
public struct FirmwareManifest: Sendable, Hashable {
    public struct Identity: Sendable, Hashable {
        public var chipID: Int
        public var boardID: Int
        public var deviceClass: String?
        public var variant: String?
        /// "Erase" for a restore, "Update" for an update that keeps data.
        public var restoreBehavior: String?
        public var uniqueBuildID: Data?
        public var securityDomain: Int
        public var requiresUIDMode: Bool
        /// The identity's other top-level values (`Ap,OSLongVersion`, `Ap,ProductType`, …).
        public var values: [String: PlistValue]
        public var manifest: [String: PlistValue]
    }

    public var productVersion: String
    public var productBuild: String
    public var supportedProductTypes: [String]
    public var identities: [Identity]

    public static let fileName = "BuildManifest.plist"
    public static let maximumBytes: UInt64 = 32 * 1024 * 1024

    public static func parse(_ data: Data) throws -> FirmwareManifest {
        let plist: PlistValue
        do { plist = try PlistValue.decode(data) } catch {
            throw ToolkitError.invalidInput("The firmware's build manifest could not be read.")
        }
        guard let version = plist["ProductVersion"]?.stringValue, let build = plist["ProductBuildVersion"]?.stringValue else {
            throw ToolkitError.invalidInput("The file is not an iPhone or iPad firmware (its build manifest has no version).")
        }
        let identities: [Identity] = (plist["BuildIdentities"]?.arrayValue ?? []).compactMap { item in
            guard let chip = hexOrInt(item["ApChipID"]), let board = hexOrInt(item["ApBoardID"]),
                  let manifest = item["Manifest"]?.dictionaryValue else { return nil }
            let info = item["Info"]
            let values = (item.dictionaryValue ?? [:]).filter { $0.key != "Manifest" && $0.key != "Info" }
            return Identity(chipID: chip, boardID: board, deviceClass: info?["DeviceClass"]?.stringValue, variant: info?["Variant"]?.stringValue,
                            restoreBehavior: info?["RestoreBehavior"]?.stringValue, uniqueBuildID: item["UniqueBuildID"]?.dataValue,
                            securityDomain: hexOrInt(item["ApSecurityDomain"]) ?? 1, requiresUIDMode: info?["RequiresUIDMode"]?.boolValue ?? false,
                            values: values, manifest: manifest)
        }
        return FirmwareManifest(productVersion: version, productBuild: build,
                                supportedProductTypes: (plist["SupportedProductTypes"]?.arrayValue ?? []).compactMap(\.stringValue),
                                identities: identities)
    }

    static func hexOrInt(_ value: PlistValue?) -> Int? {
        if let number = value?.intValue { return number }
        guard let text = value?.stringValue?.lowercased() else { return nil }
        return text.hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) : Int(text)
    }

    /// The identity to use: the device's chip and board when known, preferring an erase install
    /// (the one Apple signs whenever the firmware is signed).
    public func identity(chipID: Int? = nil, boardID: Int? = nil, deviceClass: String? = nil, behavior: String = "Erase") -> Identity? {
        let matching = identities.filter {
            (chipID == nil || $0.chipID == chipID) && (boardID == nil || $0.boardID == boardID)
                && (deviceClass == nil || $0.deviceClass?.lowercased() == deviceClass?.lowercased())
        }
        return matching.first { $0.restoreBehavior == behavior } ?? matching.first
    }
}

/// Whether Apple still signs a firmware, asked the way Finder and idevicerestore do: a signing
/// request (TSS) to Apple for one of the firmware's build identities. The request uses a random
/// device ID and nonce, so no device information is sent.
public enum FirmwareSigning {
    public enum Status: Sendable, Hashable {
        case signed
        case notSigned
        case unknown(String)

        public var label: String {
            switch self {
            case .signed: return "Signed"
            case .notSigned: return "Not signed"
            case .unknown: return "Unknown"
            }
        }

        public var explanation: String {
            switch self {
            case .signed: return "Apple signs this firmware now, so it can be installed."
            case .notSigned: return "Apple no longer signs this firmware, so it cannot be installed."
            case .unknown(let reason): return reason
            }
        }
    }

    /// Components that belong in other requests (baseband, SE, recovery OS) or are not signed.
    static let skippedComponents: Set<String> = ["BasebandFirmware", "SE,UpdatePayload", "BaseSystem", "Diags", "Ap,ExclaveOS"]
    /// Identity values copied into the request when present.
    static let copiedValues = ["Ap,OSLongVersion", "Ap,OSReleaseType", "Ap,ProductMarketingVersion", "Ap,ProductType", "Ap,SDKPlatform",
                               "Ap,Target", "Ap,TargetType", "Ap,Timestamp", "UniqueBuildID", "PearlCertificationRootPub", "NeRDEpoch",
                               "AllowNeRDBoot", "PermitNeRDPivot"]

    /// The application-processor signing request, built the way libtatsu builds it for a restore.
    public static func request(identity: FirmwareManifest.Identity, ecid: UInt64 = UInt64.random(in: 1...UInt64(1) << 52), nonce: Data = randomBytes(32), sepNonce: Data = randomBytes(20), requestID: UUID = UUID()) -> PlistValue {
        var request: [String: PlistValue] = [
            "@HostPlatformInfo": "mac",
            "@VersionInfo": .string(ImagePersonalization.clientVersion),
            "@UUID": .string(requestID.uuidString.uppercased()),
            "@ApImg4Ticket": true,
            "ApBoardID": .integer(Int64(identity.boardID)),
            "ApChipID": .integer(Int64(identity.chipID)),
            "ApECID": .integer(Int64(bitPattern: ecid)),
            "ApNonce": .data(nonce),
            "ApProductionMode": true,
            "ApSecurityDomain": .integer(Int64(identity.securityDomain)),
            "ApSecurityMode": true,
            "SepNonce": .data(sepNonce),
            "UID_MODE": false,
        ]
        if identity.requiresUIDMode { request["Ap,SikaFuse"] = 0 }
        for key in copiedValues { if let value = identity.values[key] { request[key] = value } }
        for (key, item) in identity.manifest where !skippedComponents.contains(key) {
            guard let entry = item.dictionaryValue, let info = entry["Info"] else { continue }
            let trusted = entry["Trusted"]?.boolValue == true
            let rules = info["RestoreRequestRules"]?.arrayValue
            if rules == nil && !trusted { continue }
            if info["IsFTAB"]?.boolValue == true { continue }
            var tssEntry = entry
            tssEntry.removeValue(forKey: "Info")
            if let rules {
                tssEntry = ImagePersonalization.applyRules(rules, to: tssEntry)
            } else {
                tssEntry["EPRO"] = true
                tssEntry["ESEC"] = true
            }
            if trusted && tssEntry["Digest"] == nil { tssEntry["Digest"] = .data(Data()) }
            if !tssEntry.isEmpty { request[key] = .dictionary(tssEntry) }
        }
        return .dictionary(request)
    }

    public static func status(fromResponse body: Data) -> Status {
        let reply = ImagePersonalization.status(fromResponse: body)
        switch reply.status {
        case 0 where reply.message.uppercased() == "SUCCESS": return .signed
        case 94: return .notSigned
        default: return .unknown("Apple's signing server gave an unexpected answer (status \(reply.status.map(String.init) ?? "none"): \(reply.message)).")
        }
    }

    public static func check(identity: FirmwareManifest.Identity, transport: PersonalizationTransport = AppleTSSTransport()) async -> Status {
        do {
            let body = try request(identity: identity).encoded(format: .xml)
            return status(fromResponse: try await transport.send(body))
        } catch {
            return .unknown((error as? ToolkitError)?.message ?? error.localizedDescription)
        }
    }

    public static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}
