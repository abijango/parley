import SwiftUI
import MarkdownUI

/// Side-by-side summary comparison for one transcript: runs Claude / Apple / Qwen on the
/// SAME shared prompt and renders each result in its own Markdown pane, so the user can
/// judge quality, tweak the prompt, and re-run. "Approve & File" hands the chosen output to
/// the filing step. This is the evaluation harness from the plan.
struct SummaryCompareView: View {
    @StateObject private var comparison: SummaryComparison
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var summarizer: SummarizerManager
    @Environment(\.dismiss) private var dismiss

    private let item: TranscriptItem
    /// Called when the user approves an engine's output for filing (Phase 5).
    private let onApprove: (SummaryEngineKind, String) -> Void

    @State private var showPrompt = false

    init(item: TranscriptItem, summarizer: SummarizerManager,
         onApprove: @escaping (SummaryEngineKind, String) -> Void) {
        self.item = item
        self.onApprove = onApprove
        _summarizer = ObservedObject(wrappedValue: summarizer)
        _comparison = StateObject(wrappedValue: SummaryComparison(settings: .shared, summarizer: summarizer))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showPrompt { promptEditor; Divider() }
            columns
        }
        .frame(minWidth: 1040, minHeight: 640)
        .onAppear {
            comparison.configure(
                transcriptURL: item.url,
                title: item.meta.title,
                attendees: item.meta.attendees.joined(separator: ", "),
                destination: item.meta.filing)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Compare summaries").font(.headline)
                Text(item.meta.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                ForEach(SummaryEngineKind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { settings.isSummaryEngineEnabled(kind) },
                        set: { settings.setSummaryEngine(kind, enabled: $0) }))
                }
            } label: {
                Label("Engines (\(comparison.kinds.count))", systemImage: "square.grid.2x2")
            }
            .help("Choose which models to compare")
            Button { showPrompt.toggle() } label: {
                Label("Prompt", systemImage: showPrompt ? "chevron.up" : "slider.horizontal.3")
            }
            if comparison.isRunning {
                Button(role: .cancel) { comparison.cancel() } label: { Label("Cancel", systemImage: "stop.fill") }
            }
            Button { comparison.runAll() } label: { Label("Run all", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(comparison.isRunning)
            Button("Done") { dismiss() }
        }
        .padding(12)
    }

    // MARK: Prompt editor (shared across engines)

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shared prompt").font(.subheadline.weight(.semibold))
                Text("`{{transcript}}` `{{contacts}}` `{{attendees}}` `{{destination}}`")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { settings.summaryPromptTemplate = AppSettings.defaultSummaryPrompt }
                    .font(.caption)
            }
            TextEditor(text: $settings.summaryPromptTemplate)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack(spacing: 6) {
                Text("Qwen model").font(.caption).foregroundStyle(.secondary)
                TextField("mlx-community/…", text: $settings.localSummaryModelId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: 320)
                if case .downloading(let p) = summarizer.status {
                    ProgressView(value: p).frame(width: 80)
                    Text("\(Int(p * 100))%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                } else if case .loading = summarizer.status {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Columns

    private var columns: some View {
        HStack(spacing: 10) {
            ForEach(comparison.kinds) { kind in
                column(comparison.result(for: kind))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
    }

    private func column(_ result: SummaryComparison.Result) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(result.kind.title).font(.subheadline.weight(.semibold))
                statusChip(result)
                Spacer()
                if let s = result.elapsed, case .done = result.state {
                    Text(String(format: "%.1fs", s)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                Button { comparison.run(result.kind) } label: { Image(systemName: "play") }
                    .buttonStyle(.borderless)
                    .help("Run \(result.kind.title)")
                    .disabled(result.state == .running)
            }
            .padding(8)
            Divider()
            content(result)
            Divider()
            HStack {
                Spacer()
                Button { onApprove(result.kind, result.markdown) } label: {
                    Label("Approve & File", systemImage: "tray.and.arrow.down")
                }
                .disabled(result.state != .done || result.markdown.isEmpty)
            }
            .padding(8)
        }
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary.opacity(0.5)))
    }

    @ViewBuilder private func content(_ result: SummaryComparison.Result) -> some View {
        switch result.state {
        case .done:
            ScrollView { Markdown(result.markdown).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
        case .running:
            placeholder { ProgressView(); Text("Generating…").font(.caption).foregroundStyle(.secondary) }
        case .failed(let reason):
            placeholder {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(reason).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        case .unavailable(let reason):
            placeholder {
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                Text(reason).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        case .idle:
            placeholder {
                Image(systemName: "text.append").foregroundStyle(.tertiary)
                Text("Not run yet").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func placeholder<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
    }

    @ViewBuilder private func statusChip(_ result: SummaryComparison.Result) -> some View {
        switch result.state {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.red)
        case .unavailable: Image(systemName: "minus.circle").font(.caption2).foregroundStyle(.secondary)
        case .idle: EmptyView()
        }
    }
}
