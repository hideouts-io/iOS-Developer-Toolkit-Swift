import Foundation

/// The toolkit's marketing version. The release workflow checks that this matches the tag and
/// the app's Info.plist.
public enum ToolkitVersion {
    public static let current = "1.0.0"
    /// The app's name. It also names its folders (caches, Application Support, and the default
    /// Documents folders), which keeps them apart from the Python app's "iOS Developer Toolkit" folders.
    public static let applicationName = "iOS Developer Toolkit (Swift)"
}
