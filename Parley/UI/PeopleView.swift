import SwiftUI

/// Top-level People screen: a master-detail split showing every known person
/// from the joined Rolodex + Voiceprints stores.
struct PeopleView: View {
    @EnvironmentObject private var vault: VaultDirectory
    @ObservedObject var voiceprintStore: VoiceprintStore

    @State private var selection: String?   // Person.id (lowercased displayName)
    @State private var searchQuery = ""
    @State private var isEditing = false

    // MARK: - Derived data

    private var allPeople: [Person] {
        PeopleJoin.build(contacts: vault.contacts, voiceprints: voiceprintStore.voiceprints)
    }

    private var filteredPeople: [Person] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allPeople }
        return allPeople.filter { person in
            person.displayName.lowercased().contains(q)
            || (person.contact?.company?.lowercased().contains(q) ?? false)
            || (person.contact?.title?.lowercased().contains(q) ?? false)
        }
    }

    private var selectedPerson: Person? {
        guard let id = selection else { return nil }
        return allPeople.first { $0.id == id }
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
                .frame(maxHeight: .infinity)
            detailPane
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if filteredPeople.isEmpty {
                emptyListState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredPeople) { person in
                            PersonRow(person: person, isSelected: selection == person.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if selection != person.id { isEditing = false }
                                    selection = person.id
                                }
                        }
                    }
                }
            }
        }
        .chromeSurface()
    }

    private var searchBar: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(Theme.Typography.caption)
            TextField("Search people", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .onChange(of: searchQuery) {
                    // If current selection falls off the filtered list, deselect.
                    if let id = selection,
                       !filteredPeople.contains(where: { $0.id == id }) {
                        selection = nil
                        isEditing = false
                    }
                }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
    }

    @ViewBuilder private var emptyListState: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: searchQuery.isEmpty ? "person.2.slash" : "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(searchQuery.isEmpty ? "No people yet" : "No matches")
                .font(Theme.Typography.secondary)
                .foregroundStyle(.secondary)
            if !searchQuery.isEmpty {
                Text("Try a different name or company")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xLarge)
    }

    // MARK: - Detail pane

    @ViewBuilder private var detailPane: some View {
        if let person = selectedPerson {
            if isEditing {
                PersonEditorView(
                    person: person,
                    onSave: { newDisplayName in
                        // Keep selection stable after a rename.
                        selection = newDisplayName.lowercased()
                        isEditing = false
                    },
                    onCancel: {
                        isEditing = false
                    },
                    voiceprintStore: voiceprintStore
                )
                .id(person.id)
            } else {
                PersonDetailView(person: person, onEdit: { isEditing = true })
                    .id(person.id)
            }
        } else {
            noSelectionPlaceholder
        }
    }

    private var noSelectionPlaceholder: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Select a person")
                .font(Theme.Typography.secondary)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PersonRow

private struct PersonRow: View {
    let person: Person
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(person.displayName)
                    .font(Theme.Typography.controlLabel)
                    .lineLimit(1)
                Text(subtitleText)
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            EngineBadgeRow(engines: person.enrolledEngines, compact: true)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(
            isSelected
            ? Theme.Palette.accent.opacity(Theme.Opacity.selection)
            : Color.clear
        )
        .animation(Theme.Motion.quick, value: isSelected)
    }

    private var subtitleText: String {
        if let company = person.contact?.company { return company }
        if person.contact != nil { return "Other" }
        return "Not in Rolodex"
    }
}

// MARK: - PersonDetailView

private struct PersonDetailView: View {
    let person: Person
    let onEdit: () -> Void
    @State private var player = SamplePlayer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                identitySection
                voiceprintSection
            }
            .padding(Theme.Spacing.xLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { player.stop() }
    }

    // MARK: Identity

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                Text(person.displayName)
                    .font(Theme.Typography.screenTitle)
                sideLabel
                Spacer()
                Button("Edit") { onEdit() }
                    .buttonStyle(.bordered)
                    .font(Theme.Typography.caption)
            }
            if person.contact == nil {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Text("Not in Rolodex")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                    Button("Add to Rolodex") { onEdit() }
                        .buttonStyle(.borderless)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.accent)
                }
            } else {
                contactMetadata
            }
        }
    }

    @ViewBuilder private var sideLabel: some View {
        if let side = person.contact?.side {
            Text(sideText(side))
                .font(Theme.Typography.captionSecondary)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.xxSmall)
                .background(Theme.Radius.rect(Theme.Radius.small).fill(.quaternary))
        }
    }

    @ViewBuilder private var contactMetadata: some View {
        if let contact = person.contact {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                if let title = contact.title {
                    detailRow(label: "Title", value: title)
                }
                if let company = contact.company {
                    detailRow(label: "Company", value: company)
                }
                if let linkedin = contact.linkedin, let linkedinURL = URL(string: linkedin) {
                    HStack(spacing: Theme.Spacing.xSmall) {
                        Text("LinkedIn")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        Link(linkedinDisplayText(linkedin), destination: linkedinURL)
                            .font(Theme.Typography.caption)
                    }
                }
                if !contact.aliases.isEmpty {
                    detailRow(label: "Also known as", value: contact.aliases.joined(separator: ", "))
                }
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(Theme.Typography.caption)
        }
    }

    // MARK: Voiceprint status

    private var voiceprintSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Voiceprint")
                .font(Theme.Typography.sectionHeader)

            engineStatusRow

            if !person.voiceprints.isEmpty {
                voiceprintStats
            }
        }
        .padding(Theme.Spacing.large)
        .background(Theme.Radius.rect(Theme.Radius.medium).fill(.quaternary.opacity(Theme.Opacity.surface)))
    }

    private var engineStatusRow: some View {
        HStack(spacing: Theme.Spacing.medium) {
            engineStatus(label: "FluidAudio", enrolled: person.enrolledEngines.contains("FluidAudio"))
            engineStatus(label: "WhisperKit", enrolled: person.enrolledEngines.contains("WhisperKit"))
            if person.voiceprints.isEmpty {
                Text("Not enrolled")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
    }

    private func engineStatus(label: String, enrolled: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Image(systemName: enrolled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(enrolled ? Color.green : Color.secondary)
                .font(Theme.Typography.caption)
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(enrolled ? .primary : .secondary)
        }
    }

    @ViewBuilder private var voiceprintStats: some View {
        let totalSamples = person.voiceprints.reduce(0) { $0 + $1.sampleCount }
        let hasClip = person.voiceprints.contains { $0.audioSample != nil }
        let clipVP = person.voiceprints.first { $0.audioSample != nil }

        HStack(spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text("\(totalSamples)")
                    .font(Theme.Typography.monoLarge)
                Text(totalSamples == 1 ? "sample" : "samples")
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text("\(person.voiceprints.count)")
                    .font(Theme.Typography.monoLarge)
                Text(person.voiceprints.count == 1 ? "engine" : "engines")
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
            }
            if hasClip {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Button {
                        if let vp = clipVP { playClip(vp) }
                    } label: {
                        Label("Play clip", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.Typography.caption)
                    Text("Clip retained")
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Image(systemName: "waveform.slash")
                        .foregroundStyle(.tertiary)
                        .font(Theme.Typography.caption)
                    Text("No clip")
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func sideText(_ side: Side) -> String {
        switch side {
        case .internalTeam: return "Internal"
        case .customer:     return "Customer"
        case .other:        return "Other"
        }
    }

    private func linkedinDisplayText(_ url: String) -> String {
        // Show just the path part (e.g. "in/johndoe") for a clean display.
        if let parsed = URL(string: url),
           let host = parsed.host, host.contains("linkedin") {
            let path = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return path.isEmpty ? url : path
        }
        return url
    }

    private func playClip(_ vp: Voiceprint) {
        guard let data = vp.audioSample else { return }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        AppLog.log("PeopleView: playing \(vp.name) clip -- \(samples.count) samples", category: "people")
        player.play(samples: samples)
    }
}

// MARK: - EngineBadgeRow

/// Small engine enrollment badges (FluidAudio / WhisperKit tick or cross).
/// `compact` = icon-only; !compact = icon + label.
struct EngineBadgeRow: View {
    let engines: Set<String>
    var compact: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            badge(label: "FA", enrolled: engines.contains("FluidAudio"),
                  help: "FluidAudio")
            badge(label: "WK", enrolled: engines.contains("WhisperKit"),
                  help: "WhisperKit")
        }
    }

    private func badge(label: String, enrolled: Bool, help: String) -> some View {
        let symbol = enrolled ? "checkmark" : "xmark"
        let tint: Color = enrolled ? .green : .secondary
        return Group {
            if compact {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
            } else {
                HStack(spacing: 2) {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(tint)
            }
        }
        .help(help + (enrolled ? " enrolled" : " not enrolled"))
    }
}
