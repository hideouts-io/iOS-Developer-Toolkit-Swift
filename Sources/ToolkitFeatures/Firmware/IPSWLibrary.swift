import CryptoKit
import Foundation
import ToolkitCore

// MARK: - Reading a file from an IPSW on Apple's servers

/// Reads byte ranges of a remote file. Injected so tests never touch the network.
public protocol RangeFetching: Sendable {
    func size(of url: URL) async throws -> UInt64
    func data(_ url: URL, range: ClosedRange<UInt64>) async throws -> Data
}

public struct HTTPRangeFetcher: RangeFetching {
    public init() {}

    public func size(of url: URL) async throws -> UInt64 {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.expectedContentLength > 0 else {
            throw ToolkitError(.serviceUnavailable, message: "Apple's download server did not answer.", recovery: "Check the internet connection and try again.")
        }
        return UInt64(http.expectedContentLength)
    }

    public func data(_ url: URL, range: ClosedRange<UInt64>) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 206, UInt64(data.count) == range.upperBound - range.lowerBound + 1 else {
            throw ToolkitError(.serviceUnavailable, message: "Apple's download server did not return the requested part of the firmware.", recovery: "Try again later.")
        }
        return data
    }
}

/// Reads one small file from a ZIP on a web server without downloading the whole archive (an
/// IPSW is several gigabytes; its build manifest is a few hundred kilobytes).
public enum RemoteArchive {
    public static func file(named name: String, in url: URL, fetcher: RangeFetching = HTTPRangeFetcher(), limit: UInt64 = FirmwareManifest.maximumBytes) async throws -> Data {
        let size = try await fetcher.size(of: url)
        guard size >= 22 else { throw ToolkitError.invalidInput("The firmware file is too small to be an IPSW.") }
        let tailLength = min(size, 65_557)
        var location = try ZipArchive.directoryLocation(tail: try await fetcher.data(url, range: (size - tailLength)...(size - 1)))
        if let recordOffset = location.zip64RecordOffset {
            try ZipArchive.applyZip64Record(try await fetcher.data(url, range: recordOffset...(recordOffset + 55)), to: &location)
        }
        try ZipArchive.checkLocation(location, fileSize: size)
        let directory = try await fetcher.data(url, range: location.offset...(location.offset + location.size - 1))
        guard let entry = try ZipArchive.entries(directory: directory, count: location.entryCount).first(where: { $0.name == name }) else {
            throw ToolkitError.invalidInput("The firmware has no \(name).")
        }
        guard entry.uncompressedSize <= limit, entry.compressedSize <= limit else {
            throw ToolkitError.invalidInput("\(name) is larger than expected.")
        }
        // The local header is 30 bytes plus the name and an extra field (read generously).
        let header = try await fetcher.data(url, range: entry.localHeaderOffset...min(size - 1, entry.localHeaderOffset + 30 + 1024 + 65_535))
        let start = try ZipArchive.dataOffset(localHeader: header, for: entry)
        guard entry.compressedSize > 0 else { return Data() }
        let compressed = try await fetcher.data(url, range: start...(start + entry.compressedSize - 1))
        return try ZipArchive.decompress(compressed, entry: entry)
    }
}

// MARK: - The local IPSW library

/// An IPSW on this Mac.
public struct IPSWFile: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var size: UInt64
    public var manifest: FirmwareManifest

    public var title: String { "iOS \(manifest.productVersion) (\(manifest.productBuild))" }

    public func supports(productType: String) -> Bool { manifest.supportedProductTypes.contains(productType) }
}

public enum IPSWLibrary {
    /// IPSW archives hold several gigabytes of system images.
    public static let maximumTotal: UInt64 = 64 * 1024 * 1024 * 1024

    public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/\(ToolkitVersion.applicationName)/Firmware")
    }

    /// Reads an IPSW's build manifest.
    public static func inspect(_ url: URL) throws -> IPSWFile {
        let archive = try ZipArchive(url: url, maximumTotal: maximumTotal)
        guard let entry = archive.entry(named: FirmwareManifest.fileName) else {
            throw ToolkitError.invalidInput("\(url.lastPathComponent) is not an iPhone or iPad firmware (it has no build manifest).")
        }
        let manifest = try FirmwareManifest.parse(try archive.data(for: entry, limit: FirmwareManifest.maximumBytes))
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        return IPSWFile(url: url, size: size, manifest: manifest)
    }

    /// Every readable IPSW in `directory`, newest first. Unreadable files are skipped.
    public static func scan(_ directory: URL) -> [IPSWFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "ipsw" }
            .compactMap { try? inspect($0) }
            .sorted { $0.manifest.productVersion.compare($1.manifest.productVersion, options: .numeric) == .orderedDescending }
    }

    /// SHA-1 (Apple's published checksum) and SHA-256 of a file, read in chunks.
    public static func checksums(of url: URL, progress: (Double) -> Void = { _ in }) throws -> (sha1: String, sha256: String) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ToolkitError.fileSystem("The firmware could not be opened.", path: url.path) }
        defer { try? handle.close() }
        let total = max(1, (try? handle.seekToEnd()) ?? 1)
        try handle.seek(toOffset: 0)
        var sha1 = Insecure.SHA1(), sha256 = SHA256()
        var done: UInt64 = 0
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            sha1.update(data: chunk); sha256.update(data: chunk)
            done += UInt64(chunk.count)
            progress(Double(done) / Double(total))
        }
        return (sha1.finalize().map { String(format: "%02x", $0) }.joined(), sha256.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

// MARK: - Downloading

/// The source of a download's integrity result. A local hash alone is not an Apple checksum.
public enum FirmwareDownloadProvenance: Sendable, Hashable {
    case appleCatalogSHA1Matched
    case appleCatalogDigestUnavailable
    case digestMismatch

    public var explanation: String {
        switch self {
        case .appleCatalogSHA1Matched: return "Apple catalog SHA-1 matched."
        case .appleCatalogDigestUnavailable: return "Apple's catalog checksum is unavailable. SHA-256 was computed locally."
        case .digestMismatch: return "Does not match Apple's catalog checksum. Download the firmware again."
        }
    }

    public static func assess(sha1: String, catalogSHA1: String?) throws -> Self {
        guard let catalogSHA1 else { return .appleCatalogDigestUnavailable }
        guard catalogSHA1.range(of: #"^[0-9A-Fa-f]{40}$"#, options: .regularExpression) != nil else {
            throw ToolkitError.invalidInput("Apple's catalog checksum is not a SHA-1 digest. Refresh the firmware list.")
        }
        return sha1 == catalogSHA1.lowercased() ? .appleCatalogSHA1Matched : .digestMismatch
    }
}

public struct FirmwareDownloadResult: Sendable, Hashable {
    public let url: URL
    public let sha256: String
    public let provenance: FirmwareDownloadProvenance
}

/// Downloads an IPSW into the library, resuming a previous attempt when possible. Rejects a
/// catalog SHA-1 mismatch and explicitly reports when Apple supplied no checksum.
public final class FirmwareDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (Int64, Int64) -> Void)?
    private var task: URLSessionDownloadTask?
    private var staging: URL?

    public static func resumeFile(for destination: URL) -> URL { destination.appendingPathExtension("resume") }

    /// Downloads `release` to `directory`/`release.fileName` and verifies it.
    public func download(_ release: FirmwareRelease, to directory: URL, progress: @escaping @Sendable (_ written: Int64, _ total: Int64) -> Void) async throws -> FirmwareDownloadResult {
        try SecureFileIO.createPrivateDirectory(at: directory)
        let destination = directory.appendingPathComponent(release.fileName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolkitError.invalidInput("\(release.fileName) is already in the library.")
        }
        let resumeFile = Self.resumeFile(for: destination)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 86_400
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let downloaded: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    self.progressHandler = progress
                    self.staging = directory.appendingPathComponent(".\(release.fileName).part")
                    if let data = try? Data(contentsOf: resumeFile) {
                        task = session.downloadTask(withResumeData: data)
                    } else {
                        task = session.downloadTask(with: release.url)
                    }
                    task?.resume()
                }
            }
        } onCancel: {
            lock.withLock { task }?.cancel(byProducingResumeData: { data in
                if let data { try? data.write(to: resumeFile, options: .atomic) }
            })
        }
        try? FileManager.default.removeItem(at: resumeFile)
        return try Self.complete(staged: downloaded, release: release, destination: destination)
    }

    /// Finalizes the staged download only after hashing; used for downloads with and without a
    /// catalog digest so the caller never has to infer verification from a successful transfer.
    static func complete(staged: URL, release: FirmwareRelease, destination: URL) throws -> FirmwareDownloadResult {
        let sums = try IPSWLibrary.checksums(of: staged)
        let provenance = try FirmwareDownloadProvenance.assess(sha1: sums.sha1, catalogSHA1: release.sha1)
        if provenance == .digestMismatch {
            do { try FileManager.default.removeItem(at: staged) } catch {
                throw ToolkitError(.fileSystem, message: "The firmware checksum did not match, and its staged file could not be deleted.", recovery: "Remove the staged file from the firmware library before downloading again.", technicalDetail: staged.path)
            }
            throw ToolkitError(.fileSystem, message: "The downloaded firmware does not match Apple's catalog checksum, so it was deleted.", recovery: "Download it again.", technicalDetail: "SHA-1 expected \(release.sha1 ?? "unavailable"), got \(sums.sha1)")
        }
        try FileManager.default.moveItem(at: staged, to: destination)
        return FirmwareDownloadResult(url: destination, sha256: sums.sha256, provenance: provenance)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.withLock { progressHandler }?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let (staging, continuation) = lock.withLock { () -> (URL?, CheckedContinuation<URL, Error>?) in
            defer { self.continuation = nil }
            return (self.staging, self.continuation)
        }
        guard let staging, let continuation else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            continuation.resume(throwing: ToolkitError(.serviceUnavailable, message: "Apple's download server did not send the firmware.", technicalDetail: "HTTP \(status)"))
            return
        }
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: location, to: staging)
            continuation.resume(returning: staging)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if (error as? URLError)?.code == .cancelled {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(throwing: ToolkitError(.serviceUnavailable, message: "The firmware download stopped.", recovery: "Check the internet connection and download again; it continues where it stopped.", technicalDetail: error.localizedDescription))
        }
    }
}
