import CryptoKit
import Darwin
import DeviceKit
import Foundation
import ToolkitCore

/// An inspected private copy bound to the original package's content. Installation consumes
/// `packageURL`, after revalidation, and cleanup removes only this preparation's scratch folder.
public struct PreparedAppPackage: Sendable {
    public let id: UUID
    public let originalURL: URL
    public let packageURL: URL
    public let directory: URL
    public let inspection: IPAInspection?
    public let appName: String
    public let supportedPlatforms: [String]
    public let signature: CodeSignatureSummary?

    private let expectedIdentity: String
    private let directoryDevice: dev_t
    private let directoryInode: ino_t
    private static let maximumBytes = ZipArchive.maximumTotalUncompressedBytes

    public static func prepare(_ source: URL) throws -> PreparedAppPackage {
        try Task.checkCancellation()
        guard source.isFileURL, ["ipa", "app"].contains(source.pathExtension.lowercased()) else {
            throw ToolkitError.invalidInput("Choose an .ipa package or an iOS .app bundle.")
        }
        let original = source.standardizedFileURL
        let identity = try packageIdentity(original)
        let directory = try SecureFileIO.makeTemporaryDirectory(prefix: "idt-prepared-app")
        let copy = directory.appendingPathComponent(original.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: original, to: copy)
            try Task.checkCancellation()
            guard try packageIdentity(original) == identity, try packageIdentity(copy) == identity else {
                throw ToolkitError(.invalidInput, message: "The package changed while it was being prepared.", recovery: "Choose the package again after its build or copy has finished.", technicalDetail: original.path)
            }
            let inspection: IPAInspection?
            let appName: String
            let platforms: [String]
            let signature: CodeSignatureSummary?
            if original.pathExtension.lowercased() == "ipa" {
                let inspected = try IPAInspector.inspect(copy)
                inspection = inspected
                appName = inspected.appName
                platforms = try validatedPlatforms(inspected.supportedPlatforms)
                signature = inspected.signature
            } else {
                let info = try bundleInfo(copy)
                inspection = nil
                appName = info.name
                platforms = info.platforms
                signature = CodeSignatureInspector.inspect(bundle: copy)
            }
            guard try packageIdentity(copy) == identity, try packageIdentity(original) == identity else {
                throw ToolkitError(.invalidInput, message: "The package changed during inspection.", recovery: "Choose the completed package again.", technicalDetail: original.path)
            }
            let ownership = try metadata(directory)
            return PreparedAppPackage(id: UUID(), originalURL: original, packageURL: copy, directory: directory, inspection: inspection, appName: appName, supportedPlatforms: platforms, signature: signature, expectedIdentity: identity, directoryDevice: ownership.st_dev, directoryInode: ownership.st_ino)
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch let cleanupError {
                throw ToolkitError.wrap(error, message: "Could not prepare the app package.", recovery: "Choose a valid package again.").appendingDetail("Could not remove the incomplete private copy at \(directory.path): \(cleanupError.localizedDescription)")
            }
            throw error
        }
    }

    /// Checks captured metadata for the existing installation routes without filesystem I/O.
    /// Call `revalidate()` immediately before execution. A physical device still decides provisioning.
    public func validate(for target: DeviceTarget, supportsCoreDevice: Bool, simulatorBooted: Bool) throws {
        switch target.kind {
        case .demo:
            throw ToolkitError(.unsupported, message: "Demo Mode does not install packages.", recovery: "Select a real simulator or an authorized physical device.", technicalDetail: nil)
        case .simulator:
            guard inspection == nil, packageURL.pathExtension.lowercased() == "app" else {
                throw ToolkitError(.unsupported, message: "Simulators install .app bundles built for the simulator, not .ipa files.", recovery: "Build for an iOS Simulator destination and choose the resulting .app bundle.", technicalDetail: nil)
            }
            guard supportedPlatforms.contains("iPhoneSimulator") else {
                throw ToolkitError(.unsupported, message: "This app bundle was not built for an iOS Simulator.", recovery: "Choose the .app from an iOS Simulator build.", technicalDetail: nil)
            }
            guard simulatorBooted else {
                throw ToolkitError(.invalidInput, message: "Boot the selected simulator before installing the app.", recovery: "Boot it in Device & DDI, then confirm installation again.", technicalDetail: nil)
            }
        case .physical:
            guard supportedPlatforms.contains("iPhoneOS") else {
                throw ToolkitError(.unsupported, message: "This package was not built for a physical iOS device.", recovery: "Choose an iPhoneOS build with the required device signing and provisioning.", technicalDetail: nil)
            }
            if let inspection {
                guard inspection.isInstallable else {
                    throw ToolkitError(.invalidInput, message: inspection.installabilityExplanation, recovery: "Rebuild and sign the package in Xcode, then choose it again.", technicalDetail: nil)
                }
            } else {
                guard supportsCoreDevice else {
                    throw ToolkitError(.unsupported, message: "Installing a .app bundle on a physical device requires Xcode CoreDevice tools.", recovery: "Select Xcode or choose a signed .ipa for native installation.", technicalDetail: nil)
                }
                guard signature?.status == .valid else {
                    throw ToolkitError(.invalidInput, message: "The app bundle does not have an intact code signature.", recovery: "Rebuild and sign the iOS app in Xcode, then choose it again.", technicalDetail: signature?.detail)
                }
            }
        }
    }

    public func revalidate() throws {
        try verifyDirectoryOwnership()
        guard try Self.packageIdentity(originalURL) == expectedIdentity, try Self.packageIdentity(packageURL) == expectedIdentity else {
            throw ToolkitError(.invalidInput, message: "The selected package or its prepared copy changed after inspection.", recovery: "Choose the package again and review a new installation confirmation.", technicalDetail: originalURL.path)
        }
    }

    public func remove() throws {
        try verifyDirectoryOwnership()
        do { try FileManager.default.removeItem(at: directory) }
        catch { throw ToolkitError.fileSystem("Could not remove the prepared app package.", path: directory.path, underlying: error) }
    }

    private func verifyDirectoryOwnership() throws {
        let current = try Self.metadata(directory)
        guard current.st_mode & S_IFMT == S_IFDIR, current.st_mode & 0o777 == 0o700, current.st_dev == directoryDevice, current.st_ino == directoryInode else {
            throw ToolkitError.fileSystem("The private app-package folder was replaced. It will not be used or removed.", path: directory.path, underlying: nil)
        }
    }

    private static func validatedPlatforms(_ values: [String]) throws -> [String] {
        guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else {
            throw ToolkitError.invalidInput("The app's Info.plist must declare CFBundleSupportedPlatforms.")
        }
        return values
    }

    private static func bundleInfo(_ bundle: URL) throws -> (name: String, platforms: [String]) {
        let descriptor = try openChild(root: bundle, relativePath: "Info.plist")
        let data = try readFile(descriptor, maximumBytes: IPAInspector.maximumInfoPlistBytes)
        let info = try PlistValue.decode(data)
        guard info.dictionaryValue != nil else { throw ToolkitError.invalidInput("The app's Info.plist is not a dictionary.") }
        func required(_ key: String) throws -> String {
            guard let value = info[key]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolkitError.invalidInput("The app's Info.plist is missing \(key).")
            }
            return value
        }
        let identifier = try required("CFBundleIdentifier")
        try BundleIdentifier.validate(identifier)
        _ = try required("CFBundleShortVersionString")
        _ = try required("CFBundleVersion")
        let executable = try required("CFBundleExecutable")
        guard !executable.contains("/"), !executable.contains("\0"), executable != ".", executable != ".." else {
            throw ToolkitError.invalidInput("The app's CFBundleExecutable is not a safe filename.")
        }
        let executableInfo = try metadata(bundle.appendingPathComponent(executable))
        guard executableInfo.st_mode & S_IFMT == S_IFREG, executableInfo.st_mode & 0o111 != 0 else {
            throw ToolkitError.invalidInput("The app's declared executable is missing or is not an executable regular file.")
        }
        guard let platformValues = info["CFBundleSupportedPlatforms"]?.arrayValue else {
            throw ToolkitError.invalidInput("The app's Info.plist must declare CFBundleSupportedPlatforms as a string array.")
        }
        let platforms = platformValues.compactMap(\.stringValue)
        guard platforms.count == platformValues.count else { throw ToolkitError.invalidInput("CFBundleSupportedPlatforms contains a non-string value.") }
        let name: String
        if info["CFBundleDisplayName"] != nil { name = try required("CFBundleDisplayName") }
        else { name = try required("CFBundleName") }
        return (name, try validatedPlatforms(platforms))
    }

    private struct TreeEntry: Codable {
        let path: String
        let kind: String
        let permissions: mode_t
        let hash: String?
        let link: String?
    }

    private static func packageIdentity(_ url: URL) throws -> String {
        try Task.checkCancellation()
        let info = try metadata(url)
        if url.pathExtension.lowercased() == "ipa" {
            guard info.st_mode & S_IFMT == S_IFREG else { throw ToolkitError.invalidInput("The IPA package must be a regular file, not a symbolic link.") }
            let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw fileError("Could not open the IPA package safely.", url: url) }
            return try hashFile(descriptor, url: url, maximumBytes: maximumBytes).hash
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ToolkitError.invalidInput("The app bundle must be a directory, not a symbolic link.") }
        let root = url.resolvingSymlinksInPath()
        var enumerationFailure: ToolkitError?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [], options: [], errorHandler: { failedURL, error in
            enumerationFailure = ToolkitError.fileSystem("Could not enumerate every app-bundle file.", path: failedURL.path, underlying: error)
            return false
        }) else {
            throw ToolkitError.fileSystem("Could not inspect the app bundle's files.", path: root.path, underlying: nil)
        }
        var entries = [TreeEntry(path: "", kind: "directory", permissions: info.st_mode & 0o7777, hash: nil, link: nil)]
        var totalBytes: UInt64 = 0
        for case let enumeratedURL as URL in enumerator {
            try Task.checkCancellation()
            guard entries.count < ZipArchive.maximumEntries else { throw ToolkitError.invalidInput("The app bundle exceeds the package file-count limit.") }
            // FileManager may return /var URLs for a canonical /private/var root. Resolve only
            // the parent so a leaf symbolic link remains visible to lstat and the identity.
            let child = enumeratedURL.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(enumeratedURL.lastPathComponent)
            guard child.path.hasPrefix(root.path + "/") else { throw ToolkitError.invalidInput("An app-bundle path escaped its root.") }
            let relativePath = String(child.path.dropFirst(root.path.count + 1))
            let fileMetadata = try metadata(child)
            let kind = fileMetadata.st_mode & S_IFMT
            switch kind {
            case S_IFREG:
                let descriptor = try openChild(root: root, relativePath: relativePath)
                let file = try hashFile(descriptor, url: child, maximumBytes: maximumBytes - totalBytes)
                totalBytes += file.bytes
                entries.append(TreeEntry(path: relativePath, kind: "file", permissions: fileMetadata.st_mode & 0o7777, hash: file.hash, link: nil))
            case S_IFDIR:
                guard child.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw ToolkitError.invalidInput("An app-bundle directory escaped its root.") }
                entries.append(TreeEntry(path: relativePath, kind: "directory", permissions: fileMetadata.st_mode & 0o7777, hash: nil, link: nil))
            case S_IFLNK:
                enumerator.skipDescendants()
                let link = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                let destination = child.deletingLastPathComponent().appendingPathComponent(link).standardizedFileURL
                let resolved = child.resolvingSymlinksInPath()
                guard !link.hasPrefix("/"), !link.contains("\0"), destination.path.hasPrefix(root.standardizedFileURL.path + "/"), resolved.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: resolved.path) else {
                    throw ToolkitError.invalidInput("The app bundle contains an absolute, escaping, broken, or cyclic symbolic link: \(relativePath)")
                }
                entries.append(TreeEntry(path: relativePath, kind: "symlink", permissions: fileMetadata.st_mode & 0o7777, hash: nil, link: link))
            default:
                throw ToolkitError.invalidInput("The app bundle contains a non-regular file: \(relativePath)")
            }
        }
        if let enumerationFailure { throw enumerationFailure }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SecureFileIO.sha256(of: try encoder.encode(entries.sorted { $0.path < $1.path }))
    }

    /// Opens every directory component without following links, so a changed bundle path cannot
    /// redirect a content read outside the bundle. Internal framework links are inventoried as links.
    private static func openChild(root: URL, relativePath: String) throws -> Int32 {
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw fileError("Could not open the app bundle safely.", url: root) }
        var ownedDescriptors = [directory]
        do {
            let components = relativePath.split(separator: "/").map(String.init)
            guard let last = components.last, !components.contains(".."), !components.contains(".") else { throw ToolkitError.invalidInput("An unsafe app-bundle path was rejected.") }
            for component in components.dropLast() {
                let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw fileError("Could not open an app-bundle directory safely.", url: root.appendingPathComponent(relativePath)) }
                ownedDescriptors.append(next)
                ownedDescriptors.removeAll { $0 == directory }
                try closeDescriptor(directory, root: root)
                directory = next
            }
            let descriptor = openat(directory, last, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw fileError("Could not open an app-bundle file safely.", url: root.appendingPathComponent(relativePath)) }
            ownedDescriptors.append(descriptor)
            ownedDescriptors.removeAll { $0 == directory }
            try closeDescriptor(directory, root: root)
            return descriptor
        } catch {
            var cleanupFailures: [String] = []
            for descriptor in ownedDescriptors {
                do { try closeDescriptor(descriptor, root: root) }
                catch { cleanupFailures.append((error as? ToolkitError)?.technicalDetail ?? error.localizedDescription) }
            }
            guard cleanupFailures.isEmpty else {
                throw ToolkitError.wrap(error, message: "Could not open the app-bundle file safely.", recovery: "Choose the package again.").appendingDetail("Closing app-bundle descriptors also failed: \(cleanupFailures.joined(separator: "; "))")
            }
            throw error
        }
    }

    /// A close failure leaves descriptor ownership platform-dependent; surface it without retrying
    /// a descriptor number that could already have been released and reused by another thread.
    private static func closeDescriptor(_ descriptor: Int32, root: URL) throws {
        guard close(descriptor) == 0 else { throw fileError("Could not close an app-bundle descriptor.", url: root) }
    }

    private static func hashFile(_ descriptor: Int32, url: URL, maximumBytes: UInt64) throws -> (hash: String, bytes: UInt64) {
        try withFileHandle(descriptor) { handle in
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw fileError("Could not inspect the package file.", url: url) }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, UInt64(info.st_size) <= maximumBytes else {
                throw ToolkitError.invalidInput("The package contains an invalid file or exceeds the 8 GB package preparation limit.")
            }
            var hasher = SHA256()
            var bytes: UInt64 = 0
            while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
                try Task.checkCancellation()
                guard UInt64(data.count) <= maximumBytes - bytes else { throw ToolkitError.invalidInput("The package changed size or exceeds the package preparation limit.") }
                bytes += UInt64(data.count)
                hasher.update(data: data)
            }
            return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
        }
    }

    private static func readFile(_ descriptor: Int32, maximumBytes: UInt64) throws -> Data {
        try withFileHandle(descriptor) { handle in
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                throw ToolkitError.fileSystem("Could not read the app's Info.plist metadata.", path: nil, underlying: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, UInt64(info.st_size) <= maximumBytes else {
                throw ToolkitError.invalidInput("The app's Info.plist must be a regular file within the 10 MB inspection limit.")
            }
            var data = Data()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                guard UInt64(chunk.count) <= maximumBytes - UInt64(data.count) else {
                    throw ToolkitError.invalidInput("The app's Info.plist exceeds the 10 MB inspection limit.")
                }
                data.append(chunk)
            }
            return data
        }
    }

    private static func withFileHandle<Value>(_ descriptor: Int32, operation: (FileHandle) throws -> Value) throws -> Value {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let value: Value
        do { value = try operation(handle) }
        catch {
            do { try handle.close() }
            catch let cleanupError {
                throw ToolkitError.wrap(error, message: "Could not read the app package.", recovery: "Choose the package again.").appendingDetail("Closing the package file also failed: \(cleanupError.localizedDescription)")
            }
            throw error
        }
        do { try handle.close() }
        catch { throw ToolkitError.fileSystem("Could not close the app-package file after reading it.", path: nil, underlying: error) }
        return value
    }

    private static func metadata(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw fileError("Could not read the package's file metadata.", url: url) }
        return info
    }

    private static func fileError(_ message: String, url: URL) -> ToolkitError {
        ToolkitError.fileSystem(message, path: url.path, underlying: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
    }
}
