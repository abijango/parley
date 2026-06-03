import SwiftUI

/// The offer-to-run-Claude bar shown above the rendered transcript. Renders the
/// `NotesGenerator` state machine: Generate (with confirm) → running → finished/failed.
struct NotesActionBar: View {
    @ObservedObject var generator: NotesGenerator
    let destination: String
    let attendees: String
    let model: String
    let onGenerate: () -> Void

    @State private var showConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch generator.state {
            case .idle:
                row { idle }
            case .running(let since):
                running(since: since)
            case .finished(let noteURL, _):
                row { finished(noteURL: noteURL) }
            case .failed(let message):
                row { failed(message) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content(); Spacer() }
    }

    // MARK: States

    private var idle: some View {
        Button {
            showConfirm = true
        } label: {
            Label("Generate meeting notes", systemImage: "sparkles")
        }
        .buttonStyle(.borderedProminent)
        .popover(isPresented: $showConfirm, arrowEdge: .bottom) { confirmPopover }
    }

    private func running(since: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("Generating notes… \(elapsed(since, context.date))")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Cancel") { generator.cancel() }.controlSize(.small)
            }
            activityFeed
        }
    }

    private var activityFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(generator.activity.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    Color.clear.frame(height: 1).id(-1)
                }
            }
            .frame(maxHeight: 120)
            .onChange(of: generator.activity.count) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(-1, anchor: .bottom) }
            }
        }
    }

    private func finished(noteURL: URL?) -> some View {
        HStack(spacing: 10) {
            Label("Notes ready", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            if let noteURL {
                Button {
                    generator.openInObsidian(noteURL)
                } label: { Label("Open in Obsidian", systemImage: "arrow.up.forward.app") }
                    .controlSize(.small)
                Button("Reveal") { generator.revealInFinder(noteURL) }
                    .controlSize(.small)
            } else {
                Text("(couldn't locate the note file)").font(.caption).foregroundStyle(.secondary)
            }
            Button("Re-run") { showConfirm = true }
                .controlSize(.small)
                .popover(isPresented: $showConfirm, arrowEdge: .bottom) { confirmPopover }
        }
    }

    private func failed(_ message: String) -> some View {
        HStack(spacing: 10) {
            Label("Notes failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            SettingsLink { Text("Settings") }.controlSize(.small)
            Button("Retry") { onGenerate() }.controlSize(.small)
        }
    }

    // MARK: Confirm popover

    private var confirmPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Generate meeting notes").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                row("Filing", destination.isEmpty ? "— (Claude will choose)" : destination)
                row("Attendees", attendees.isEmpty ? "— none" : attendees)
                row("Model", model)
            }
            Text("Runs the process-meeting-transcript skill and writes the note to your vault.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { showConfirm = false }.keyboardShortcut(.cancelAction)
                Button("Run") { showConfirm = false; onGenerate() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(.caption)
        }
    }

    private func elapsed(_ start: Date, _ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
