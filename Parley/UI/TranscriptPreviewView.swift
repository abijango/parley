import SwiftUI
import MarkdownUI

/// Renders the saved transcript note (`.md`) with full Markdown formatting.
/// Reads the file at `url` off the main thread so large notes don't hitch the UI;
/// reloads when the URL changes and degrades gracefully if the file was moved/processed.
struct TranscriptPreviewView: View {
    let url: URL?
    /// Bump to force a re-read when the file at `url` is rewritten in place (the URL
    /// is unchanged, so `onChange(of: url)` alone wouldn't catch it).
    var reloadToken: Int = 0
    /// When set, receives the full file text (including frontmatter) after each load.
    var rawMarkdown: Binding<String?>? = nil

    @State private var content: String?
    @State private var loadError: String?
    @State private var loadTask: Task<Void, Never>?

    /// Reading / code font families for the rendered note, matched to the active look.
    private var readingFamily: FontProperties.Family {
        ThemeStore.shared.kind == .cursor ? .custom("Geist") : .system(.serif)
    }
    private var codeFamily: FontProperties.Family {
        ThemeStore.shared.kind == .cursor ? .custom("GeistMono") : .system(.monospaced)
    }

    var body: some View {
        Group {
            if let content {
                ScrollView {
                    Markdown(content)
                        .markdownTextStyle(\.text) { FontFamily(readingFamily); FontSize(16) }
                        .markdownTextStyle(\.code) { FontFamily(codeFamily) }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.large)
                }
            } else {
                placeholder
            }
        }
        .onAppear(perform: load)
        .onChange(of: url) { load() }
        .onChange(of: reloadToken) { load() }
        .onDisappear { loadTask?.cancel() }
    }

    @ViewBuilder private var placeholder: some View {
        if let loadError {
            EmptyStateView(
                icon: "doc.text.magnifyingglass",
                title: "Note unavailable",
                detail: loadError)
        } else {
            EmptyStateView(
                icon: "doc.text.magnifyingglass",
                title: "No transcript yet",
                detail: "Finish a recording to preview it here.")
        }
    }

    /// Drops a leading YAML frontmatter block (`---\n…\n---`) so it isn't rendered
    /// as a run-on paragraph. The metadata is shown elsewhere (History header).
    static func strippingFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return text }
        let lines = text.components(separatedBy: "\n")
        if let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            return lines[(closing + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func load() {
        loadTask?.cancel()
        guard let url else {
            content = nil
            loadError = nil
            rawMarkdown?.wrappedValue = nil
            return
        }
        content = nil
        loadError = nil
        loadTask = Task {
            let result = await Task.detached { Self.readFile(at: url) }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .missing:
                content = nil
                loadError = "This note was moved or processed — open it in Obsidian."
                rawMarkdown?.wrappedValue = nil
            case .failed(let message):
                content = nil
                loadError = message
                rawMarkdown?.wrappedValue = nil
            case .loaded(let text):
                rawMarkdown?.wrappedValue = text
                content = Self.strippingFrontmatter(text)
                loadError = nil
            }
        }
    }

    private enum ReadResult: Sendable {
        case missing
        case failed(String)
        case loaded(String)
    }

    nonisolated private static func readFile(at url: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            return .loaded(try String(contentsOf: url, encoding: .utf8))
        } catch {
            return .failed("Couldn't read the note: \(error.localizedDescription)")
        }
    }
}
