import SwiftUI

// MARK: - Settings layout (Claude-app style)
//
// Settings pages are a column of titled sections; each section is a stack of rows with
// the label + description on the left and the control right-aligned, separated by
// hairlines. Rows know how to match a search: the window passes the query down the
// environment, a row that doesn't match renders nothing, and match counts flow back
// up as preferences so sections hide their headers and the sidebar shows counts.

// MARK: Search environment

private struct SettingsQueryKey: EnvironmentKey { static let defaultValue = "" }
private struct SettingsContextKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
    /// The lowercased, trimmed search text; empty when not searching.
    var settingsQuery: String {
        get { self[SettingsQueryKey.self] }
        set { self[SettingsQueryKey.self] = newValue }
    }
    /// Page and section titles above a row, so a search for "summaries" finds every
    /// row on that page.
    var settingsContext: String {
        get { self[SettingsContextKey.self] }
        set { self[SettingsContextKey.self] = newValue }
    }
}

/// Number of rows under a view that match the current search.
struct SettingsMatchCountKey: PreferenceKey {
    static let defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) { value += nextValue() }
}

enum SettingsSearch {
    static func matches(_ query: String, _ texts: String?...) -> Bool {
        guard !query.isEmpty else { return true }
        return texts.compactMap { $0 }.contains { $0.lowercased().contains(query) }
    }

    /// `text` with the query's first occurrence highlighted.
    static func highlighted(_ text: String, _ query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty,
              let range = attributed.range(of: query, options: .caseInsensitive) else { return attributed }
        attributed[range].backgroundColor = Color.yellow.opacity(0.35)
        return attributed
    }
}

// MARK: Section

/// A titled group of settings rows. While searching, the header hides when none of
/// its rows match (the rows hide themselves).
struct SettingsSection<Content: View>: View {
    let title: String
    private let content: Content
    @Environment(\.settingsQuery) private var query
    @Environment(\.settingsContext) private var context
    @State private var matchCount = 1

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if query.isEmpty || matchCount > 0 {
                Text(title)
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.top, Theme.Spacing.xLarge)
                    .padding(.bottom, Theme.Spacing.xSmall)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .environment(\.settingsContext, context + " " + title)
            .onPreferenceChange(SettingsMatchCountKey.self) { matchCount = $0 }
        }
    }
}

// MARK: Row

/// One setting: title and optional description on the left, control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var description: String? = nil
    /// Extra words a search should find this row by (e.g. "cli path").
    var keywords: String? = nil
    @ViewBuilder var control: () -> Control
    @Environment(\.settingsQuery) private var query
    @Environment(\.settingsContext) private var context

    init(_ title: String, description: String? = nil, keywords: String? = nil,
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.description = description
        self.keywords = keywords
        self.control = control
    }

    private var isMatch: Bool {
        SettingsSearch.matches(query, title, description, keywords, context)
    }

    var body: some View {
        if isMatch {
            HStack(alignment: .center, spacing: Theme.Spacing.xLarge) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(SettingsSearch.highlighted(title, query))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if let description, !description.isEmpty {
                        Text(SettingsSearch.highlighted(description, query))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                control()
                    .labelsHidden()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Theme.Spacing.medium)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Palette.divider).frame(height: 0.5)
            }
            .preference(key: SettingsMatchCountKey.self, value: 1)
        }
    }
}

/// Free-form content inside a section (a status list, an explanation, a table). Hidden
/// while searching unless `keywords` match, so results stay a clean list of rows.
struct SettingsBlock<Content: View>: View {
    var keywords: String? = nil
    private let content: Content
    @Environment(\.settingsQuery) private var query
    @Environment(\.settingsContext) private var context

    init(keywords: String? = nil, @ViewBuilder content: () -> Content) {
        self.keywords = keywords
        self.content = content()
    }

    var body: some View {
        if query.isEmpty || (keywords != nil && SettingsSearch.matches(query, keywords, context)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.Spacing.medium)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Palette.divider).frame(height: 0.5)
            }
            .preference(key: SettingsMatchCountKey.self, value: query.isEmpty ? 0 : 1)
        }
    }
}

/// A short explanatory line under a section's rows.
struct SettingsNote: View {
    let text: String
    @Environment(\.settingsQuery) private var query

    init(_ text: String) { self.text = text }

    var body: some View {
        if query.isEmpty {
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Spacing.small)
        }
    }
}

// MARK: Editor sheet

/// A long text setting (a prompt, a list) edited in a sheet rather than inline.
struct SettingsEditorSheet: View {
    let title: String
    var detail: String? = nil
    @Binding var text: String
    var resetValue: String? = nil
    var monospaced = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(title).font(Theme.Typography.sheetTitle)
            if let detail {
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $text)
                .font(monospaced ? Theme.Typography.mono : Theme.Typography.body)
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.small)
                .background(Theme.Radius.rect(Theme.Radius.small).fill(Theme.Palette.panelBg))
                .overlay(Theme.Radius.rect(Theme.Radius.small)
                    .strokeBorder(Theme.Palette.divider, lineWidth: 0.5))
                .frame(minHeight: 320)
            HStack {
                if let resetValue {
                    Button("Reset to default") { text = resetValue }.glassButton()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .glassProminentButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: 640)
    }
}
