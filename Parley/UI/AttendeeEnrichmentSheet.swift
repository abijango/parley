import SwiftUI

/// Batched post-call sheet that asks the user to fill in Company (and optionally
/// Title/LinkedIn) for attendees who were auto-added but have no known company in
/// the rolodex. Presented once after a recording stops; both "Skip all" and "Save"
/// call `recording.finishEnrichment(save:)` so the deferred summary always fires.
struct AttendeeEnrichmentSheet: View {
    @ObservedObject var recording: RecordingController

    /// Row names for which the user tapped "Not a match", hiding the suggestion chips.
    @State private var dismissedSuggestions: Set<String> = []

    var body: some View {
        // Guard: sheet can be presented while pendingEnrichment is still being set;
        // render nothing if it races to nil (sheet will dismiss immediately).
        if let _ = recording.pendingEnrichment {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {

            // Header
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text("Add companies for new attendees")
                    .font(Theme.Typography.sheetTitle)
                Text("So the summary knows who represents whom.")
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Row list
            ScrollView {
                VStack(spacing: Theme.Spacing.small) {
                    if let enrichment = recording.pendingEnrichment {
                        ForEach(enrichment.rows.indices, id: \.self) { i in
                            rowView(index: i)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Skip all", role: .cancel) {
                    recording.finishEnrichment(save: false)
                }
                .glassButton()
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    recording.finishEnrichment(save: true)
                }
                .glassProminentButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 420)
    }

    @ViewBuilder
    private func rowView(index i: Int) -> some View {
        // Safely unwrap to avoid a crash if pendingEnrichment goes nil mid-render.
        if recording.pendingEnrichment != nil {
            let name = recording.pendingEnrichment!.rows[i].name
            let placeholder = recording.pendingEnrichment!.destinationDefault
            let suggestions = recording.vault.suggestMatches(for: name)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                // Suggestion chips: shown when the fuzzy helper finds plausible
                // existing contacts AND the user has not dismissed them.
                // Tapping links the detected name as an alias and removes this row.
                // "Not a match" hides chips so the user can fill fields manually.
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
    }

    /// Compact chip row showing plausible existing contacts for `rowName`.
    /// Tapping a chip records the alias + drops the row (the person is now known).
    /// "Not a match" dismisses the chips so the user can fill fields manually.
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

    // MARK: - Row field bindings

    private func titleBinding(index i: Int) -> Binding<String> {
        Binding(
            get: { recording.pendingEnrichment?.rows[safe: i]?.title ?? "" },
            set: { newVal in
                guard recording.pendingEnrichment != nil,
                      i < (recording.pendingEnrichment?.rows.count ?? 0) else { return }
                recording.pendingEnrichment!.rows[i].title = newVal
            }
        )
    }

    private func companyBinding(index i: Int) -> Binding<String> {
        Binding(
            get: { recording.pendingEnrichment?.rows[safe: i]?.company ?? "" },
            set: { newVal in
                guard recording.pendingEnrichment != nil,
                      i < (recording.pendingEnrichment?.rows.count ?? 0) else { return }
                recording.pendingEnrichment!.rows[i].company = newVal
            }
        )
    }

    private func linkedinBinding(index i: Int) -> Binding<String> {
        Binding(
            get: { recording.pendingEnrichment?.rows[safe: i]?.linkedin ?? "" },
            set: { newVal in
                guard recording.pendingEnrichment != nil,
                      i < (recording.pendingEnrichment?.rows.count ?? 0) else { return }
                recording.pendingEnrichment!.rows[i].linkedin = newVal
            }
        )
    }
}

// MARK: - Safe subscript helper

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
