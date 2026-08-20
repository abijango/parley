import Foundation

/// Centralized app identity. Reference `AppInfo.name` everywhere instead of
/// hardcoding the product name. `TODO(app-name)` markers elsewhere tag the
/// identifiers derived from the name (bundle id, keychain service, support dir).
enum AppInfo {
    /// User-facing application name.
    static let name = "Parley"

    /// Folder name used under ~/Library/Application Support for models, logs, etc.
    static var supportDirectoryName: String { name }

    /// True when this process is an XCTest TEST_HOST of Parley.app.
    static var isXCTestHost: Bool { NSClassFromString("XCTestCase") != nil }
}
