import SwiftUI

extension Notification.Name {
    /// Ask the main window's shell to show the live recording screen.
    static let parleyShowLiveScreen = Notification.Name("parley.showLiveScreen")
}

/// The "Recording" menu: Start / Stop Recording on ⇧⌘R, usable from anywhere in the
/// app. Starting also brings up the main window on the live screen.
struct RecordingCommands: View {
    /// The shortcut, shared with the Start/Stop button's tooltip.
    static let shortcut = KeyboardShortcut("r", modifiers: [.command, .shift])
    static let shortcutLabel = "⇧⌘R"

    @ObservedObject private var recording = RecordingController.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(recording.isRecording ? "Stop Recording" : "Start Recording") {
            Self.toggle(recording, showLive: {
                openWindow(id: ParleyApp.mainWindowID)
                NotificationCenter.default.post(name: .parleyShowLiveScreen, object: nil)
            })
        }
        .keyboardShortcut(Self.shortcut)
    }

    /// Start or stop, ignoring presses while a start/stop is already in flight.
    @MainActor static func toggle(_ recording: RecordingController, showLive: () -> Void = {}) {
        let state = recording.live.state
        guard state != .preparing, state != .stopping else { return }
        if recording.isRecording {
            recording.stop()
        } else {
            showLive()
            Task { await recording.start() }
        }
    }
}
