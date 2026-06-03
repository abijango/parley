import SwiftUI

/// Type-ahead picker for a filing location (any folder in the scanned vault
/// roots). Filters by substring over friendly paths ("Internal / Customers /
/// Vanguard"), stores the real relative path, and offers to create a new folder
/// when nothing matches.
struct DestinationField: View {
    @Binding var path: String
    let destinations: [VaultDestination]
    var firstRoot: String

    @State private var text: String = ""
    @State private var editing = false
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Filing location — type to filter, or a new path", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onChange(of: text) { editing = true; highlighted = 0 }
                .onChange(of: focused) { if !focused { commit() } }
                .onAppear { text = displayFor(path) }
                .onChange(of: path) { if !focused { text = displayFor(path) } }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.return) { chooseHighlighted() }
                .onKeyPress(.escape) { closeSuggestions() }

            if showSuggestions {
                suggestionList
            }
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, dest in
                Button { select(dest) } label: {
                    Text(dest.display).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(highlighted == index ? Color.accentColor.opacity(0.2) : .clear)
            }
            if showCreate {
                Divider()
                Button { createNew() } label: {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("Create “\(newPath())”")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(highlighted == matches.count ? Color.accentColor.opacity(0.2) : .clear)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .frame(maxHeight: 170)
    }

    // MARK: Keyboard

    private var showSuggestions: Bool { focused && editing && rowCount > 0 }
    private var showCreate: Bool { exactMatch == nil && !trimmed.isEmpty }
    private var rowCount: Int { matches.count + (showCreate ? 1 : 0) }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard showSuggestions else { return .ignored }
        highlighted = max(0, min(highlighted + delta, rowCount - 1))
        return .handled
    }

    private func chooseHighlighted() -> KeyPress.Result {
        guard showSuggestions else { return .ignored }
        if highlighted < matches.count {
            select(matches[highlighted])
        } else if showCreate {
            createNew()
        }
        return .handled
    }

    private func closeSuggestions() -> KeyPress.Result {
        guard editing else { return .ignored }
        editing = false
        focused = false
        return .handled
    }

    // MARK: Matching

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

    private var matches: [VaultDestination] {
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return Array(destinations.prefix(8)) }
        let hits = destinations.filter {
            $0.display.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
        return Array(hits.prefix(8))
    }

    private var exactMatch: VaultDestination? {
        destinations.first {
            $0.display.caseInsensitiveCompare(text) == .orderedSame ||
            $0.path.caseInsensitiveCompare(text) == .orderedSame ||
            $0.leaf.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    // MARK: Actions

    private func select(_ dest: VaultDestination) {
        path = dest.path
        text = dest.display
        editing = false
        focused = false
    }

    private func createNew() {
        path = newPath()
        text = displayFor(path)
        editing = false
        focused = false
    }

    private func commit() {
        if let match = exactMatch {
            path = match.path
            text = match.display
        } else if !trimmed.isEmpty {
            path = newPath()
            text = displayFor(path)
        }
    }

    /// Turns the typed text into a relative path. A bare name is placed under the
    /// first scan root; a slashed/" / "-separated value is used as-is.
    private func newPath() -> String {
        let normalized = trimmed.replacingOccurrences(of: " / ", with: "/")
        let parts = normalized.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count > 1 { return parts.joined(separator: "/") }
        let leaf = parts.first ?? normalized
        return firstRoot.isEmpty ? leaf : "\(firstRoot)/\(leaf)"
    }

    private func displayFor(_ p: String) -> String {
        if let d = destinations.first(where: { $0.path == p }) { return d.display }
        return p.split(separator: "/").joined(separator: " / ")
    }
}
