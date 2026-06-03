import SwiftUI

/// Menu-bar companion: quick start/stop, status, and a button to open the main
/// window. Full controls (metadata, live transcript) live in the window.
struct MenuBarView: View {
    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform")
                Text(AppInfo.name).font(.headline)   // TODO(app-name)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }

            if case .error(let message) = recording.state {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let result = recording.lastResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            recordButton

            Button {
                openMainWindow()
            } label: {
                Label("Open \(AppInfo.name) Window", systemImage: "macwindow")  // TODO(app-name)
                    .frame(maxWidth: .infinity)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
    }

    private var recordButton: some View {
        Button {
            Task {
                if recording.isRecording { recording.stop() }
                else { await recording.start() }
            }
        } label: {
            HStack {
                Image(systemName: recording.isRecording ? "stop.fill" : "record.circle")
                Text(recording.isRecording ? "Stop" : "Start")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(recording.isRecording ? .red : .green)
        .disabled(recording.state == .preparing || recording.state == .stopping)
    }

    private var footer: some View {
        HStack {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
            Spacer()
            Button("Quit") {
                recording.teardownForQuit()
                NSApplication.shared.terminate(nil)
            }
        }
        .font(.caption)
    }

    private func openMainWindow() {
        openWindow(id: ParleyApp.mainWindowID)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var statusText: String {
        switch recording.state {
        case .idle: return "Ready"
        case .preparing: return "Preparing…"
        case .recording: return "● Recording"
        case .stopping: return "Stopping…"
        case .error: return "Error"
        }
    }
}
