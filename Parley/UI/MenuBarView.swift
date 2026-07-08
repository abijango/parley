import SwiftUI

/// Menu-bar companion: quick start/stop, status, and a button to open the main
/// window. Full controls (metadata, live transcript) live in the window.
struct MenuBarView: View {
    @EnvironmentObject private var recording: RecordingController
    @ObservedObject private var live = RecordingController.shared.live
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "waveform")
                Text(AppInfo.name).font(Theme.Typography.controlLabel)   // TODO(app-name)
                Spacer()
                statusBadge
            }

            if case .error(let message) = live.state {
                StatusBanner(.danger, message)
            } else if let result = recording.lastResult {
                Text(result).font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            recordButton

            Button {
                openMainWindow()
            } label: {
                Label("Open \(AppInfo.name) Window", systemImage: "macwindow")  // TODO(app-name)
                    .frame(maxWidth: .infinity)
            }
            .glassButton()

            Divider()
            footer
        }
        .padding(Theme.Spacing.large)
        .frame(width: 280)
    }

    /// Status dot + text, the same treatment as the main window's status row.
    private var statusBadge: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .animation(Theme.Motion.quick, value: statusColor)
            Text(statusText).font(Theme.Typography.caption).foregroundStyle(.secondary)
        }
    }

    private var recordButton: some View {
        Button {
            Task {
                if recording.isRecording { recording.stop() }
                else { await recording.start() }
            }
        } label: {
            Label(recording.isRecording ? "Stop" : "Start",
                  systemImage: recording.isRecording ? "stop.fill" : "record.circle")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .glassProminentButton()
        .tint(recording.isRecording ? .red : .green)
        .disabled(live.state == .preparing || live.state == .stopping)
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
        .font(Theme.Typography.caption)
    }

    private func openMainWindow() {
        openWindow(id: ParleyApp.mainWindowID)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var statusText: String {
        switch live.state {
        case .idle: return "Ready"
        case .preparing: return "Preparing…"
        case .recording: return "Recording"
        case .stopping: return "Stopping…"
        case .error: return "Error"
        }
    }

    private var statusColor: Color {
        switch live.state {
        case .recording: return .red
        case .preparing, .stopping: return .orange
        case .error: return .red
        case .idle: return .secondary
        }
    }
}
