import SwiftUI

/// Multi-value attendee field — pure SwiftUI (no `NSTokenField`). The `tokens` binding is
/// the SINGLE source of truth: chips render directly from it and every add/remove mutates
/// it, so a programmatic change (a suggestion chip, an auto-identified speaker writing the
/// model) just appears — there's no second copy to reconcile. This is the deliberate
/// replacement for the AppKit bridge, whose objectValue/field-editor/binding tri-state
/// caused repeated clobber / display-desync / stray-commit bugs. Mirrors the proven
/// type-ahead pattern in `DestinationField`.
struct TokenField: View {
    @Binding var tokens: [String]
    var completions: [String]
    var placeholder: String
    /// Called when a genuinely-new (not a known contact, not already added) name is
    /// committed — the caller opens a "new contact" form instead of adding a bare token.
    var onCreateNew: (String) -> Void = { _ in }

    @State private var draft = ""
    @State private var highlighted = 0
    @State private var fieldWidth: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            FlowLayout(maxWidth: fieldWidth,
                       spacing: Theme.Spacing.xSmall, rowSpacing: Theme.Spacing.xSmall) {
                ForEach(tokens, id: \.self) { chip($0) }
                inputField
            }
            // Measure the content width and feed it back to FlowLayout, so its wrapped
            // height always matches placement (no proposal-width guessing → no overflow).
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { fieldWidth = g.size.width }
                    .onChange(of: g.size.width) { fieldWidth = g.size.width }
            })
            .padding(Theme.Spacing.xSmall)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .overlay(Theme.Radius.rect(Theme.Radius.small).strokeBorder(.quaternary))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            if showSuggestions { suggestionList }
        }
    }

    // MARK: Pieces

    private var inputField: some View {
        TextField(tokens.isEmpty ? placeholder : "", text: $draft)
            .textFieldStyle(.plain)
            .font(Theme.Typography.body)
            .frame(minWidth: 120, idealWidth: 160)
            .focused($focused)
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.return) { commitFromKeyboard() }
            .onKeyPress(.escape) { clearDraft() }
            .onKeyPress(.delete) { backspace() }
            .onChange(of: draft) {
                highlighted = 0
                if draft.contains(",") { commitCommaSeparated() }
            }
    }

    private func chip(_ name: String) -> some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Text(name)
                .font(Theme.Typography.caption.weight(.medium))
                .foregroundStyle(Theme.Palette.accent)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 200, alignment: .leading)
            Button { remove(name) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.accent.opacity(0.55))
            .help("Remove")
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.xxSmall + 1)
        .background(Capsule().fill(Theme.Palette.accent.opacity(Theme.Opacity.tintFill)))
        .overlay(Capsule().strokeBorder(Theme.Palette.accent.opacity(0.25)))
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(filtered.enumerated()), id: \.element) { index, name in
                Button { commit(name) } label: {
                    Text(name).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, Theme.Spacing.xSmall).padding(.horizontal, Theme.Spacing.small)
                .background(suggestionHighlight(index))
                // Hover and ↑/↓ share one highlight index — one selection model.
                .onHover { if $0 { highlighted = index } }
            }
        }
        .cardSurface(radius: Theme.Radius.small)
        .frame(maxHeight: 170)
    }

    private func suggestionHighlight(_ index: Int) -> some View {
        Theme.Radius.rect(Theme.Radius.small)
            .fill(highlighted == index
                  ? Theme.Palette.accent.opacity(Theme.Opacity.selection)
                  : Color.clear)
    }

    // MARK: Matching

    /// Known names matching the draft prefix, excluding ones already added.
    private var filtered: [String] {
        let q = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let existing = Set(tokens.map { $0.lowercased() })
        return completions
            .filter { $0.lowercased().hasPrefix(q) && !existing.contains($0.lowercased()) }
            .prefix(8).map { $0 }
    }
    private var showSuggestions: Bool { focused && !filtered.isEmpty }

    // MARK: Keyboard

    private func move(_ delta: Int) -> KeyPress.Result {
        guard showSuggestions else { return .ignored }
        highlighted = max(0, min(highlighted + delta, filtered.count - 1))
        return .handled
    }

    private func commitFromKeyboard() -> KeyPress.Result {
        if showSuggestions, highlighted < filtered.count {
            commit(filtered[highlighted]); return .handled
        }
        let q = draft.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return .ignored }
        commit(q); return .handled
    }

    private func clearDraft() -> KeyPress.Result {
        guard !draft.isEmpty else { return .ignored }
        draft = ""; return .handled
    }

    /// Backspace on an empty input removes the last chip (NSTokenField behavior). While
    /// there's text, let the field delete a character normally (`.ignored`).
    private func backspace() -> KeyPress.Result {
        guard draft.isEmpty, !tokens.isEmpty else { return .ignored }
        tokens.removeLast(); return .handled
    }

    // MARK: Commit / remove

    /// Classify a committed name. Pure + unit-tested; mirrors the old `shouldAdd` rule.
    enum Commit: Equatable { case duplicate, add, createNew }
    static func classify(_ name: String, tokens: [String], completions: [String]) -> Commit {
        let key = name.lowercased()
        if tokens.contains(where: { $0.lowercased() == key }) { return .duplicate }
        if completions.contains(where: { $0.lowercased() == key }) { return .add }
        return .createNew
    }

    private func commit(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        highlighted = 0
        guard !name.isEmpty else { return }
        switch Self.classify(name, tokens: tokens, completions: completions) {
        case .duplicate: break
        case .add: tokens.append(name)
        case .createNew: onCreateNew(name)   // route to the New Person sheet, not a raw token
        }
    }

    private func commitCommaSeparated() {
        let parts = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        draft = ""
        for p in parts where !p.isEmpty { commit(p) }
    }

    private func remove(_ name: String) {
        tokens.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}
