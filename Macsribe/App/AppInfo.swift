import Foundation

/// Centralized app identity. Reference `AppInfo.name` everywhere instead of
/// hardcoding the product name so the eventual rename is a one-line change.
///
/// TODO(app-name): "Macsribe" is a PLACEHOLDER. When the final name is chosen,
/// update `name` here and sweep `grep -rn "TODO(app-name)"` for the rest
/// (project.yml, Info.plist, bundle id, the `Macsribe/` source dir).
enum AppInfo {
    /// User-facing application name.
    static let name = "Macsribe"

    /// Folder name used under ~/Library/Application Support for models, logs, etc.
    static var supportDirectoryName: String { name }
}
