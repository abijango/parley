import SwiftUI

/// Menu-bar entry point.
/// TODO(app-name): struct name `ParleyApp`.
@main
struct ParleyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recording = RecordingController.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        // Single main window (not WindowGroup — this is a one-window utility).
        Window(AppInfo.name, id: Self.mainWindowID) {   // TODO(app-name): window title
            MainWindowView()
                .environmentObject(recording)
                .environmentObject(settings)
                .environmentObject(recording.models)
                .environmentObject(recording.vault)
                .environmentObject(recording.store)
        }
        .defaultSize(width: 560, height: 700)

        // Menu-bar companion: quick controls + status without opening the window.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(recording)
                .environmentObject(settings)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(recording)
                .environmentObject(settings)
                .environmentObject(recording.models)
                .environmentObject(recording.vault)
                .environmentObject(recording.callDetector)
        }
    }

    static let mainWindowID = "main"

    private var menuBarSymbol: String {
        switch recording.state {
        case .recording: return "record.circle.fill"
        case .preparing, .stopping: return "waveform.circle"
        case .error: return "exclamationmark.triangle"
        case .idle: return "waveform"
        }
    }
}
