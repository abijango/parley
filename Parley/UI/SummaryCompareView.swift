import AppKit
import SwiftUI
import MarkdownUI

/// Side-by-side summary comparison for one transcript. Every `SummaryBackend` can be
/// toggled; Claude may be seeded from a filed note or a staging draft. Approve asks
/// overwrite vs copy.
struct SummaryCompareView: View {
    @StateObject private var comparison = SummaryComparison()
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var summarizer = LocalSummaryRunner.shared
    @Environment(\.dismiss) private var dismiss

    private let item: TranscriptItem
    private let onFiled: (URL) -> Void

    @State private var showPrompt = false
    @State private var pendingApprove: PendingApprove?
    @State private var approveDestination: String = ""

    private struct PendingApprove: Identifiable {
        let id = UUID()
        let backend: SummaryBackend
        let markdown: String
    }

    init(item: TranscriptItem, onFiled: @escaping (URL) -> Void = { _ in }) {
        self.item = item
        self.onFiled = onFiled
    }

    /// Column chrome used when sizing the window to fit enabled models.
    private static let columnWidth: CGFloat = 360
    private static let columnSpacing: CGFloat = 8
    private static let horizontalChrome: CGFloat = 32
    private static let minWindowSize = CGSize(width: 720, height: 480)
    private static let screenInset: CGFloat = 40

    private var enabledColumnCount: Int {
        comparison.results.filter(\.enabled).count
    }

    /// Preferred content size for the current column set, before screen clamping.
    private var preferredSize: CGSize {
        let columns = max(enabledColumnCount, 1)
        let width = Self.horizontalChrome
            + CGFloat(columns) * Self.columnWidth
            + CGFloat(max(0, columns - 1)) * Self.columnSpacing
        return CGSize(width: width, height: 720)
    }

    private var screenMaxSize: CGSize {
        let frame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(
            width: max(Self.minWindowSize.width, frame.width - Self.screenInset * 2),
            height: max(Self.minWindowSize.height, frame.height - Self.screenInset * 2))
    }

    private var clampedPreferredSize: CGSize {
        let maxSize = screenMaxSize
        return CGSize(
            width: min(max(preferredSize.width, Self.minWindowSize.width), maxSize.width),
            height: min(max(preferredSize.height, Self.minWindowSize.height), maxSize.height))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            engineToggles
            Divider()
            if showPrompt { promptEditor; Divider() }
            columns
        }
        .frame(
            minWidth: Self.minWindowSize.width,
            idealWidth: clampedPreferredSize.width,
            maxWidth: screenMaxSize.width,
            minHeight: Self.minWindowSize.height,
            idealHeight: clampedPreferredSize.height,
            maxHeight: screenMaxSize.height)
        .background(
            ResizableCompareWindowSizer(
                minSize: Self.minWindowSize,
                preferredSize: clampedPreferredSize,
                maxSize: screenMaxSize,
                growToken: enabledColumnCount))
        .onAppear {
            approveDestination = item.meta.filing
            comparison.configure(
                transcriptURL: item.url,
                title: item.meta.title,
                attendees: item.meta.attendees.joined(separator: ", "),
                destination: item.meta.filing,
                filedNotePath: item.meta.note)
        }
        .confirmationDialog(
            "File this summary?",
            isPresented: Binding(
                get: { pendingApprove != nil },
                set: { if !$0 { pendingApprove = nil } }),
            titleVisibility: .visible,
            presenting: pendingApprove
        ) { pending in
            if item.meta.note != nil {
                Button("Overwrite existing note") {
                    file(pending, overwrite: true)
                }
                Button("Save as a new copy") {
                    file(pending, overwrite: false)
                }
            } else {
                Button("File to vault") {
                    file(pending, overwrite: false)
                }
            }
            Button("Cancel", role: .cancel) { pendingApprove = nil }
        } message: { pending in
            Text(item.meta.note != nil
                 ? "\(pending.backend.displayName) — overwrite the filed Claude note, or keep both?"
                 : "File the \(pending.backend.displayName) summary to \(approveDestination.isEmpty ? "the vault root" : approveDestination).")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare summaries").font(Theme.Typography.sheetTitle)
                Text(item.meta.title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let source = comparison.claudeSeedSource {
                Text(source == .filedNote
                     ? "Claude seeded from filed note"
                     : "Claude seeded from review draft")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Button { showPrompt.toggle() } label: {
                Label("Prompt", systemImage: showPrompt ? "chevron.up" : "slider.horizontal.3")
            }
            if comparison.isRunning {
                Button(role: .cancel) { comparison.cancelAll() } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
            }
            Button { comparison.runAllEnabled() } label: {
                Label("Run all enabled", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(comparison.isRunning || comparison.enabledBackends.isEmpty)
            Button("Done") { dismiss() }
        }
        .padding(Theme.Spacing.medium)
    }

    // MARK: Engine toggles

    private var engineToggles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.medium) {
                ForEach(SummaryBackend.allCases) { backend in
                    Toggle(isOn: Binding(
                        get: { comparison.result(for: backend).enabled },
                        set: { comparison.setEnabled(backend, $0) }
                    )) {
                        Text(backend.displayName).font(Theme.Typography.caption)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
        }
    }

    // MARK: Prompt

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Text("Shared prompt").font(Theme.Typography.controlLabel)
                Text("`{{transcript}}` `{{contacts}}` `{{attendees}}` `{{destination}}`")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { settings.summaryPromptTemplate = AppSettings.defaultSummaryPrompt }
                    .font(Theme.Typography.caption)
            }
            TextEditor(text: $settings.summaryPromptTemplate)
                .font(Theme.Typography.mono)
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack(spacing: Theme.Spacing.small) {
                Text("Qwen model").font(Theme.Typography.caption).foregroundStyle(.secondary)
                TextField("mlx-community/…", text: $settings.localSummaryModelId)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typography.mono)
                    .frame(maxWidth: 360)
                switch summarizer.manager.status {
                case .downloading(let p):
                    ProgressView(value: p).frame(width: 80)
                case .loading:
                    ProgressView().controlSize(.small)
                case .ready(let id):
                    Text("loaded \(id)").font(Theme.Typography.caption).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
            HStack(spacing: Theme.Spacing.small) {
                Text("File to:").font(Theme.Typography.caption).foregroundStyle(.secondary)
                TextField("destination", text: $approveDestination)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typography.mono)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
    }

    // MARK: Columns

    private var columns: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: Self.columnSpacing) {
                    ForEach(comparison.results.filter(\.enabled)) { result in
                        column(result)
                            .frame(
                                width: Self.columnWidth,
                                height: max(0, geo.size.height - Theme.Spacing.small * 2))
                    }
                }
                .padding(Theme.Spacing.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func column(_ result: SummaryComparison.Result) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(result.backend.displayName)
                    .font(Theme.Typography.controlLabel)
                    .lineLimit(1)
                statusChip(result)
                Spacer(minLength: 0)
                timingLabel(result)
                if result.backend == .claude, case .seeded = result.state {
                    Button("Re-run") { comparison.run(.claude, forceLive: true) }
                        .font(Theme.Typography.caption)
                        .disabled(result.state == .running)
                        .help("Re-run Claude instead of using the filed note")
                }
                Button { comparison.run(result.backend, forceLive: true) } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Run \(result.backend.displayName)")
                .disabled(result.state == .running)
            }
            .padding(8)
            Divider()
            content(result)
            Divider()
            HStack {
                Spacer()
                Button {
                    pendingApprove = PendingApprove(backend: result.backend, markdown: result.markdown)
                } label: {
                    Label("Approve & File", systemImage: "tray.and.arrow.down")
                }
                .disabled(!canApprove(result))
            }
            .padding(8)
        }
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary.opacity(0.5)))
    }

    private func canApprove(_ result: SummaryComparison.Result) -> Bool {
        switch result.state {
        case .done, .seeded: return !result.markdown.isEmpty
        default: return false
        }
    }

    @ViewBuilder private func timingLabel(_ result: SummaryComparison.Result) -> some View {
        switch result.state {
        case .seeded:
            Text(comparison.claudeSeedSource == .stagingDraft ? "from draft" : "from note")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        case .done, .failed:
            if let elapsed = result.elapsed {
                Text(SummaryDurationFormat.string(from: elapsed))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("Wall-clock time to produce this summary")
            }
        case .running:
            Text("…")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func content(_ result: SummaryComparison.Result) -> some View {
        switch result.state {
        case .done, .seeded:
            ScrollView {
                Markdown(result.markdown)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .running:
            placeholder {
                ProgressView()
                Text("Generating…").font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            placeholder {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(reason).font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .unavailable(let reason):
            placeholder {
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                Text(reason).font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .idle:
            placeholder {
                Image(systemName: "text.append").foregroundStyle(.tertiary)
                Text("Not run yet").font(Theme.Typography.caption).foregroundStyle(.tertiary)
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
        case .seeded: Image(systemName: "doc.circle.fill").font(.caption2).foregroundStyle(.blue)
        case .failed: Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.red)
        case .unavailable: Image(systemName: "minus.circle").font(.caption2).foregroundStyle(.secondary)
        case .idle: EmptyView()
        }
    }

    private func file(_ pending: PendingApprove, overwrite: Bool) {
        pendingApprove = nil
        let url = RecordingController.shared.summaryService.commitGeneratedMarkdown(
            item,
            destination: approveDestination,
            body: pending.markdown,
            overwriteExisting: overwrite)
        if let url {
            onFiled(url)
            dismiss()
        }
    }
}

/// Makes the compare sheet's hosting window resizable, grows with column count,
/// and clamps size to the visible screen (never larger than width/height).
private struct ResizableCompareWindowSizer: NSViewRepresentable {
    var minSize: CGSize
    var preferredSize: CGSize
    var maxSize: CGSize
    /// Changes when more/fewer model columns are enabled so we can auto-grow.
    var growToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window, coordinator: context.coordinator) }
    }

    private func apply(to window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        window.styleMask.insert(.resizable)
        window.title = "Compare summaries"
        window.minSize = minSize
        window.maxSize = maxSize

        let content = window.contentLayoutRect.size
        var target = content

        if !coordinator.didSetInitialSize {
            target = preferredSize
            coordinator.didSetInitialSize = true
            coordinator.lastGrowToken = growToken
        } else if growToken > coordinator.lastGrowToken {
            // More columns enabled — widen if the window is still narrower than preferred.
            target.width = max(content.width, preferredSize.width)
            target.height = max(content.height, min(preferredSize.height, maxSize.height))
            coordinator.lastGrowToken = growToken
        } else if growToken != coordinator.lastGrowToken {
            coordinator.lastGrowToken = growToken
        }

        target.width = min(max(target.width, minSize.width), maxSize.width)
        target.height = min(max(target.height, minSize.height), maxSize.height)

        guard abs(target.width - content.width) > 1 || abs(target.height - content.height) > 1 else {
            return
        }

        // Prefer growing from the top-left so the sheet stays on-screen.
        var frame = window.frame
        let deltaW = target.width - content.width
        let deltaH = target.height - content.height
        frame.size.width += deltaW
        frame.size.height += deltaH
        frame.origin.y -= deltaH

        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
            if frame.minX < visible.minX { frame.origin.x = visible.minX }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            frame.size.width = min(frame.size.width, visible.width)
            frame.size.height = min(frame.size.height, visible.height)
        }

        window.setFrame(frame, display: true)
    }

    final class Coordinator {
        var didSetInitialSize = false
        var lastGrowToken = 0
    }
}
