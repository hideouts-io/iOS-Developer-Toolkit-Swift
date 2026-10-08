import DeviceKit
import Foundation

/// The app's navigation destinations. Shared by the UI, workspace profiles, and the support
/// bundle so their identifiers cannot drift apart.
public enum Workspace: String, CaseIterable, Codable, Sendable, Identifiable {
    case overview
    case device
    case developerImage
    case firmware
    case readiness
    case apps
    case installApp
    case location
    case liveLogs
    case actions
    case backup
    case evidence
    case securityAnalysis
    case externalTools
    case activity
    case help
    case safety

    public var id: String { rawValue }

    /// Presentation order is separate from persisted identifiers and legacy numbered shortcuts.
    public static let primaryWorkspaces: [Workspace] = [
        .overview, .device, .readiness, .location, .liveLogs, .actions, .apps,
        .backup, .installApp, .evidence, .externalTools, .help, .safety,
    ]
    public static let additionalWorkspaces: [Workspace] = [.firmware, .securityAnalysis]
    public static var sidebarWorkspaces: [Workspace] { primaryWorkspaces + additionalWorkspaces }
    public static var navigationOrder: [Workspace] { sidebarWorkspaces + [.activity] }

    /// Older profiles and shortcuts still open Developer Image inside Device & DDI.
    public var sidebarWorkspace: Workspace { self == .developerImage ? .device : self }

    public var title: String {
        switch self {
        case .overview: return "Home"
        case .device: return "Device & DDI"
        case .developerImage: return "Developer Image"
        case .firmware: return "Firmware"
        case .readiness: return "Capability Matrix"
        case .apps: return "Installed Apps"
        case .installApp: return "Sideload IPA"
        case .location: return "Location Lab"
        case .liveLogs: return "Live Logs"
        case .actions: return "Command Center"
        case .backup: return "Backup"
        case .evidence: return "Evidence Capture"
        case .securityAnalysis: return "Security Analysis"
        case .externalTools: return "Ecosystem Tools"
        case .activity: return "Session Activity"
        case .help: return "Man Pages"
        case .safety: return "Scope & Safety"
        }
    }

    public var symbolName: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .device: return "iphone"
        case .developerImage: return "opticaldiscdrive"
        case .firmware: return "arrow.triangle.2.circlepath.circle"
        case .readiness: return "checklist"
        case .apps: return "app.badge"
        case .installApp: return "square.and.arrow.down.on.square"
        case .location: return "location"
        case .liveLogs: return "text.alignleft"
        case .actions: return "bolt"
        case .backup: return "externaldrive.badge.timemachine"
        case .evidence: return "archivebox"
        case .securityAnalysis: return "shield.checkered"
        case .externalTools: return "wrench.and.screwdriver"
        case .activity: return "clock.arrow.circlepath"
        case .help: return "book"
        case .safety: return "shield.lefthalf.filled"
        }
    }

    public var subtitle: String {
        switch self {
        case .overview: return "What you can do and where to start"
        case .device: return "Identity, trust, Developer Mode, and Developer Image workflows"
        case .developerImage: return "Check, mount, and unmount Apple's developer image"
        case .firmware: return "IPSW library, Apple signing status, recovery mode, update and restore"
        case .readiness: return "Current-device prerequisites and real-device compatibility history"
        case .apps: return "Installed apps: search, sizes, launch, and remove"
        case .installApp: return "Inspect an .ipa or .app, then install it"
        case .location: return "Simulate coordinates, routes, and GPX tracks"
        case .liveLogs: return "Stream Unified Logs or syslog with filters and findings"
        case .actions: return "Guided device and developer actions"
        case .backup: return "Encrypted local backups and forensic handoffs"
        case .evidence: return "Hashed, documented evidence collection"
        case .securityAnalysis: return "Local IOC analysis, correlation, and reports"
        case .externalTools: return "Validate Meta idb Companion and inspect its target inventory"
        case .activity: return "Everything this session has run"
        case .help: return "Built-in help for the Apple tools the app uses"
        case .safety: return "What the app can and cannot do"
        }
    }

    public enum Group: String, CaseIterable, Sendable {
        case start = "Start"
        case device = "Device"
        case develop = "Develop"
        case data = "Data & Evidence"
        case reference = "Reference"
    }

    public var group: Group {
        switch self {
        case .overview: return .start
        case .device, .developerImage, .firmware, .readiness, .apps, .installApp: return .device
        case .location, .liveLogs, .actions: return .develop
        case .backup, .evidence, .securityAnalysis, .externalTools: return .data
        case .activity, .help, .safety: return .reference
        }
    }

    /// Whether the workspace can be used with this kind of device.
    public func supports(_ kind: DeviceKind?) -> Bool {
        switch self {
        case .backup, .evidence, .firmware: return kind == .physical || kind == nil || kind == .demo
        default: return true
        }
    }
}

/// A clearly labelled simulated device for walkthroughs, screenshots, and UI tests. No device
/// operation can run against it.
public enum DemoMode {
    public static let identifier = "DEMO-IPHONE-17-PRO"
    public static let banner = "Demo Mode — this is a simulated iPhone for walkthroughs and screenshots. No device is connected and device actions are disabled."

    public static var device: Device {
        Device(
            kind: .demo,
            udid: identifier,
            name: "Demo iPhone (simulated)",
            productType: "iPhone18,1",
            marketingName: "iPhone 17 Pro",
            family: .iPhone,
            osName: "iOS",
            osVersion: "26.0",
            buildVersion: "23A341",
            architecture: "arm64e",
            hardwareModel: "D93AP",
            transports: [.usb],
            pairingState: .paired,
            developerMode: .enabled,
            ddiServicesAvailable: true,
            tunnelState: "connected",
            sources: [.demo]
        )
    }
}
