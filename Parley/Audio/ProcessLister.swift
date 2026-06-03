import Foundation
import AppKit

/// A user-pickable running application for per-app audio capture.
struct CapturableApp: Identifiable, Hashable {
    let id: pid_t            // process id
    let name: String
    let bundleIdentifier: String?

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: id)?.icon
    }
}

/// Lists running applications the user could capture audio from. We can't know
/// which are actively producing audio without taps, so we list regular,
/// foreground-capable apps (excluding ourselves) and let the user choose.
enum ProcessLister {
    static func capturableApps() -> [CapturableApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return CapturableApp(
                    id: app.processIdentifier,
                    name: name,
                    bundleIdentifier: app.bundleIdentifier
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
