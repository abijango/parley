import SwiftUI

/// Launch-time sheet listing sessions that were recording when the app crashed.
/// The audio survived intact (CAF), so each can be **Resumed** (continue the same
/// note), **Recovered** (finalize what we have, optionally re-transcribing the
/// full audio), or **Discarded**. Always shown — never silently auto-handled.
struct RecoveryView: View {
    @EnvironmentObject private var recording: RecordingController
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                Text(recording.pendingRecoveries.count > 1
                     ? "Recover interrupted recordings"
                     : "Recover interrupted recording")
                    .font(.title3.weight(.semibold))
            }
            Text("These were recording when the app last quit. The audio is intact — resume to keep going in the same note, or recover it as a transcript.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(recording.pendingRecoveries) { session in
                        row(session)
                    }
                }
            }

            if recording.isRecovering {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Re-transcribing audio…").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Later") { onClose() }
                    .help("Decide later — these stay available until handled.")
            }
        }
        .padding(20)
        .frame(width: 540, height: 440)
    }

    private func row(_ s: RecoverableSession) -> some View {
        let live = recording.isCallLive(s)
        let busy = recording.isRecording || recording.isRecovering
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.manifest.title.isEmpty ? "Untitled recording" : s.manifest.title)
                        .font(.headline)
                    Text("\(durationText(s.durationSeconds)) · \(dateText(s.manifest.startedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                    if !s.manifest.filing.isEmpty {
                        Text("Filing: \(s.manifest.filing)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if live {
                    Label("Call still live", systemImage: "phone.connection.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await recording.resume(s) }
                } label: {
                    Label("Resume", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(live ? .green : .accentColor)
                .disabled(busy)
                .help("Continue recording into this same note.")

                Menu {
                    Button("Recover from saved text (instant)") { recording.recover(s, reTranscribe: false) }
                    Button("Re-transcribe full audio (complete)") { recording.recover(s, reTranscribe: true) }
                } label: {
                    Label("Recover", systemImage: "doc.text")
                }
                .fixedSize()
                .disabled(busy)
                .help("Finalize as a transcript without resuming.")

                Spacer()

                Button(role: .destructive) {
                    recording.discard(s)
                } label: {
                    Label("Discard", systemImage: "trash")
                }
                .disabled(recording.isRecovering)
                .help("Delete this session and its audio.")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func durationText(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }

    private func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
