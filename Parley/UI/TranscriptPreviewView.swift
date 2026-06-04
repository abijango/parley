import SwiftUI
import MarkdownUI

/// Renders the saved transcript note (`.md`) with full Markdown formatting.
/// Reads the file at `url` so it shows the note exactly as written; reloads when
/// the URL changes and degrades gracefully if the file was moved/processed.
struct TranscriptPreviewView: View {
    let url: URL?
    /// Bump to force a re-read when the file at `url` is rewritten in place (the URL
    /// is unchanged, so `onChange(of: url)` alone wouldn't catch it).
    var reloadToken: Int = 0

    @State private var content: String?
    @State private var loadError: String?

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
                        // Reading font follows the active look (Geist in Cursor, New
                        // York serif in Native) so the rendered note matches the rest
                        // of the UI. Larger base size for comfortable reading; headings
                        // scale relative to it.
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
    private static func strippingFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return text }
        let lines = text.components(separatedBy: "\n")
        // Find the closing delimiter after the first line.
        if let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            return lines[(closing + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func load() {
        guard let url else { content = nil; loadError = nil; return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            content = nil
            loadError = "This note was moved or processed — open it in Obsidian."
            return
        }
        do {
            content = Self.strippingFrontmatter(try String(contentsOf: url, encoding: .utf8))
            loadError = nil
        } catch {
            content = nil
            loadError = "Couldn't read the note: \(error.localizedDescription)"
        }
    }
}
