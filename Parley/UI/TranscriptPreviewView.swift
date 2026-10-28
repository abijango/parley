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

    var body: some View {
        Group {
            if let content {
                ScrollView {
                    Markdown(content)
                        .markdownTheme(.parley)
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

extension MarkdownUI.Theme {
    /// Rendered notes and summaries: Hanken Grotesk at regular weight with roomy line
    /// spacing and modest semibold headings — the light reading feel of the Claude app,
    /// rather than MarkdownUI's large bold defaults.
    static let parley = MarkdownUI.Theme.basic
        .text {
            FontFamily(.custom(BrandFont.sansFamily))
            FontSize(16.5)
            ForegroundColor(Theme.Palette.textBody)
        }
        .code {
            FontFamily(.custom(BrandFont.monoFamily))
            FontSize(.em(0.88))
        }
        .strong {
            FontWeight(.semibold)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: .rem(0.25), bottom: .rem(0.75))
                .markdownTextStyle {
                    ForegroundColor(Theme.Palette.textPrimary)
                    FontWeight(.semibold)
                    FontSize(.em(1.45))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: .rem(1.25), bottom: .rem(0.5))
                .markdownTextStyle {
                    ForegroundColor(Theme.Palette.textPrimary)
                    FontWeight(.semibold)
                    FontSize(.em(1.2))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: .rem(1), bottom: .rem(0.4))
                .markdownTextStyle {
                    ForegroundColor(Theme.Palette.textPrimary)
                    FontWeight(.semibold)
                    FontSize(.em(1.05))
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.3))
                .markdownMargin(top: .zero, bottom: .em(0.8))
        }
}
