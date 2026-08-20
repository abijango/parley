import SwiftUI

/// Batched post-call sheet that asks the user to fill in Company (and optionally
/// Title/LinkedIn) for attendees who were auto-added but have no known company in
/// the rolodex. Presented once after a recording stops; both "Skip all" and "Save"
/// call `recording.finishEnrichment(save:)` so the deferred summary always fires.
///
/// Draft rows live in `@State` so typing does not write through
/// `RecordingController.pendingEnrichment` (a `@Published` struct) and invalidate
/// the main window on every keystroke.
struct AttendeeEnrichmentSheet: View {
    @ObservedObject var recording: RecordingController
    @State private var rows: [RecordingController.AttendeeEnrichment.Row] = []
    @State private var destinationDefault = ""
    @State private var suggestionsByName: [String: [Contact]] = [:]
    @State private var dismissedSuggestions: Set<String> = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {

            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text("Add companies for new attendees")
                    .font(Theme.Typography.sheetTitle)
                Text("So the summary knows who represents whom.")
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                VStack(spacing: Theme.Spacing.small) {
                    ForEach(rows.indices, id: \.self) { i in
                        rowView(index: i)
                    }
                }
            }
            .frame(maxHeight: 320)

            Divider()

            HStack {
                Spacer()
                Button("Skip all", role: .cancel) {
                    recording.finishEnrichment(save: false)
                }
                .glassButton()
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    recording.finishEnrichment(save: true, rows: rows)
                }
                .glassProminentButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 420)
        .onAppear(perform: loadDraft)
    }

    @ViewBuilder
    private func rowView(index i: Int) -> some View {
        let name = rows[i].name
        let placeholder = destinationDefault
        let suggestions = suggestionsByName[name] ?? []

        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            Text(name)
                .font(.headline)
                .foregroundStyle(.primary)

            if !suggestions.isEmpty && !dismissedSuggestions.contains(name) {
                suggestionChips(rowName: name, suggestions: suggestions)
            }

            Grid(alignment: .leading,
                 horizontalSpacing: Theme.Spacing.medium,
                 verticalSpacing: Theme.Spacing.xxSmall) {

                GridRow {
                    Text("Title")
                        .gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    TextField("e.g. Head of Architecture",
                              text: titleBinding(index: i))
                }
                GridRow {
                    Text("Company")
                        .foregroundStyle(.secondary)
                    TextField(placeholder.isEmpty ? "e.g. Vanguard" : placeholder,
                              text: companyBinding(index: i))
                }
                GridRow {
                    Text("LinkedIn")
                        .foregroundStyle(.secondary)
                    TextField("https://www.linkedin.com/in/...",
                              text: linkedinBinding(index: i))
                }
            }
            .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, Theme.Spacing.xxSmall)
    }

    @ViewBuilder
    private func suggestionChips(rowName: String, suggestions: [Contact]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            Text("Looks like:")
                .font(Theme.Typography.captionSecondary)
                .foregroundStyle(.secondary)

            HStack(spacing: Theme.Spacing.xxSmall) {
                ForEach(suggestions, id: \.name) { contact in
                    Button(action: {
                        recording.linkAttendeeToExisting(detected: rowName,
                                                         canonicalName: contact.name)
                        dropRow(named: rowName)
                    }) {
                        HStack(spacing: 4) {
                            Text(contact.name)
                                .font(Theme.Typography.secondary)
                            if let company = contact.company {
                                Text("\u{00B7} \(company)")
                                    .font(Theme.Typography.captionSecondary)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.xSmall)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button("Not a match") {
                    dismissedSuggestions.insert(rowName)
                }
                .font(Theme.Typography.captionSecondary)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
    }

    private func loadDraft() {
        guard !loaded, let enrichment = recording.pendingEnrichment else { return }
        rows = enrichment.rows
        destinationDefault = enrichment.destinationDefault
        let contacts = recording.vault.contacts
        var scored: [String: [Contact]] = [:]
        for row in enrichment.rows {
            scored[row.name] = VaultDirectory.suggestMatches(for: row.name, in: contacts)
        }
        suggestionsByName = scored
        loaded = true
    }

    private func dropRow(named name: String) {
        rows.removeAll { $0.name == name }
        if rows.isEmpty {
            recording.finishEnrichment(save: true, rows: rows)
        }
    }

    private func titleBinding(index i: Int) -> Binding<String> {
        Binding(
            get: { rows[safe: i]?.title ?? "" },
            set: { newVal in
                guard rows.indices.contains(i) else { return }
                rows[i].title = newVal
            }
        )
    }

    private func companyBinding(index i: Int) -> Binding<String> {
        Binding(
            get: { rows[safe: i]?.company ?? "" },
            set: { newVal in
                guard rows.indices.contains(i) else { return }
                rows[i].company = newVal
            }
        )
    }

    private func linkedinBinding(index i: Int) -> Binding<String> {
        Binding(
            get: { rows[safe: i]?.linkedin ?? "" },
            set: { newVal in
                guard rows.indices.contains(i) else { return }
                rows[i].linkedin = newVal
            }
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
