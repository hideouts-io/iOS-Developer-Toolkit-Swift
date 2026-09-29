import Foundation
import ToolkitCore

/// A firmware (IPSW) Apple offers for a device model.
public struct FirmwareRelease: Sendable, Hashable, Identifiable, Codable {
    public var id: String { "\(productType)-\(build)" }
    public var productType: String
    public var version: String
    public var build: String
    public var url: URL
    /// Apple's published SHA-1 of the IPSW.
    public var sha1: String?

    public init(productType: String, version: String, build: String, url: URL, sha1: String?) {
        self.productType = productType
        self.version = version
        self.build = build
        self.url = url
        self.sha1 = sha1
    }

    /// The IPSW's file name (`iPhone18,1_27.0.1_24A446_Restore.ipsw`).
    public var fileName: String { url.lastPathComponent }
}

/// Apple's firmware catalog: the version list Finder and idevicerestore use
/// (`https://itunes.apple.com/check/version`). It lists the firmware Apple currently offers for
/// each model; older firmware is not listed.
public enum FirmwareCatalog {
    public static let url = URL(string: "https://itunes.apple.com/check/version")!
    /// The catalog is refreshed after a day, like idevicerestore does.
    public static let maximumAge: TimeInterval = 86_400
    /// The catalog is a few megabytes; anything far larger is not the catalog.
    static let maximumBytes = 64 * 1024 * 1024

    /// Firmware for `productType`, newest first.
    public static func releases(fromCatalog data: Data, productType: String) throws -> [FirmwareRelease] {
        guard data.count <= maximumBytes,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let groups = root["MobileDeviceSoftwareVersionsByVersion"] as? [String: Any] else {
            throw ToolkitError(.protocolViolation, message: "Apple's firmware list could not be read.", recovery: "Try again later.")
        }
        var byBuild: [String: FirmwareRelease] = [:]
        for case let group as [String: Any] in groups.values {
            guard let models = group["MobileDeviceSoftwareVersions"] as? [String: Any],
                  let builds = models[productType] as? [String: Any] else { continue }
            for case let entry as [String: Any] in builds.values {
                guard let restore = entry["Restore"] as? [String: Any],
                      let version = restore["ProductVersion"] as? String,
                      let build = restore["BuildVersion"] as? String,
                      let link = restore["FirmwareURL"] as? String,
                      var components = URLComponents(string: link) else { continue }
                // Apple's CDN serves the same files over HTTPS.
                if components.scheme == "http" { components.scheme = "https" }
                guard let url = components.url, url.pathExtension == "ipsw" else { continue }
                byBuild[build] = FirmwareRelease(productType: productType, version: version, build: build, url: url, sha1: (restore["FirmwareSHA1"] as? String)?.lowercased())
            }
        }
        return byBuild.values.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    /// The catalog, from `cache` when it is fresh, otherwise downloaded (and cached).
    public static func load(cache: URL, fetcher: DataFetching = URLSessionDataFetcher(), now: Date = Date()) async throws -> Data {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cache.path),
           let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) < maximumAge,
           let data = try? Data(contentsOf: cache) {
            return data
        }
        let data = try await fetcher.data(from: url, limit: maximumBytes)
        _ = try releases(fromCatalog: data, productType: "")   // must at least parse
        try SecureFileIO.createPrivateDirectory(at: cache.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: cache)
        try SecureFileIO.writeNewFile(data, to: cache)
        return data
    }
}

/// Downloads small documents (the catalog). Injected so tests never touch the network.
public protocol DataFetching: Sendable {
    func data(from url: URL, limit: Int) async throws -> Data
}

public struct URLSessionDataFetcher: DataFetching {
    public init() {}

    public func data(from url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("iOS Developer Toolkit", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ToolkitError(.serviceUnavailable, message: "This Mac could not reach Apple's servers.", recovery: "Check the internet connection and try again.", technicalDetail: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToolkitError(.serviceUnavailable, message: "Apple's server did not answer as expected.", recovery: "Try again later.", technicalDetail: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(url.absoluteString)")
        }
        guard data.count <= limit else { throw ToolkitError(.protocolViolation, message: "Apple's server sent more data than expected.") }
        return data
    }
}
