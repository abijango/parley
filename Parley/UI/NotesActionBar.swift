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
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
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
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
        .chromeSurface()
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Theme.Spacing.medium) { content(); Spacer() }
    }

    // MARK: States

    private var idle: some View {
        Button {
            showConfirm = true
        } label: {
            Label("Generate meeting notes", systemImage: "sparkles")
        }
        .glassProminentButton()
        .popover(isPresented: $showConfirm, arrowEdge: .bottom) { confirmPopover }
    }

    private func running(since: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.medium) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("Generating notes… \(elapsed(since, context.date))")
                        .font(Theme.Typography.secondary).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Cancel") { generator.cancel() }
                    .glassButton().controlSize(.small)
            }
            activityFeed
        }
    }

    private var activityFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    ForEach(Array(generator.activity.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(Theme.Typography.mono)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    Color.clear.frame(height: 1).id(-1)
                }
            }
            .frame(maxHeight: 120)
            .onChange(of: generator.activity.count) {
                withAnimation(Theme.Motion.gentle) { proxy.scrollTo(-1, anchor: .bottom) }
            }
        }
    }

    private func finished(noteURL: URL?) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Label("Notes ready", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Theme.Severity.success.color)
            if let noteURL {
                Button {
                    generator.openInObsidian(noteURL)
                } label: { Label("Open in Obsidian", systemImage: "arrow.up.forward.app") }
                    .glassButton().controlSize(.small)
                Button("Reveal") { generator.revealInFinder(noteURL) }
                    .glassButton().controlSize(.small)
            } else {
                Text("(couldn't locate the note file)")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
            Button("Re-run") { showConfirm = true }
                .glassButton().controlSize(.small)
                .popover(isPresented: $showConfirm, arrowEdge: .bottom) { confirmPopover }
        }
    }

    private func failed(_ message: String) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Label("Notes failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Severity.danger.color)
            Text(message).font(Theme.Typography.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            SettingsLink { Text("Settings") }.glassButton().controlSize(.small)
            Button("Retry") { onGenerate() }.glassButton().controlSize(.small)
        }
    }

    // MARK: Confirm popover

    private var confirmPopover: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Generate meeting notes").font(Theme.Typography.sheetTitle)
            Grid(alignment: .leading,
                 horizontalSpacing: Theme.Spacing.small,
                 verticalSpacing: Theme.Spacing.xSmall) {
                row("Filing", destination.isEmpty ? "— (Claude will choose)" : destination)
                row("Attendees", attendees.isEmpty ? "— none" : attendees)
                row("Model", model)
            }
            Text("Runs the process-meeting-transcript skill and writes the note to your vault.")
                .font(Theme.Typography.captionSecondary).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { showConfirm = false }
                    .glassButton().keyboardShortcut(.cancelAction)
                Button("Run") { showConfirm = false; onGenerate() }
                    .glassProminentButton().keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 340)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(Theme.Typography.caption).foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value).font(Theme.Typography.caption)
        }
    }

    private func elapsed(_ start: Date, _ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
