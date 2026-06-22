import SwiftUI

// MARK: - PersonEditorView

/// Editable detail pane for a Person. Replaces the read-only PersonDetailView when
/// the user taps "Edit". Uses an explicit Save / Cancel pair; local @State holds
/// the draft until committed.
///
/// Save policy:
///   - If the name changed: RecordingController.renamePerson(from:to:) first (fans out
///     to both VaultDirectory and VoiceprintStore), then upsertPerson for the other fields.
///   - If only non-name fields changed: vault.upsertPerson(..., side:) directly.
///   - For a voiceprint-only person: Save calls upsertPerson which creates the contact.
///
/// Autocomplete for company: case-insensitive match against vault.contacts company names;
/// snaps to the existing casing on commit to prevent drift.
struct PersonEditorView: View {
    // MARK: - Inputs

    let person: Person
    /// Called when the edit is committed (pass back the new display name so the
    /// parent can keep the selection stable after a rename).
    let onSave: (_ newDisplayName: String) -> Void
    let onCancel: () -> Void

    // MARK: - Environment

    @EnvironmentObject private var vault: VaultDirectory
    @ObservedObject var voiceprintStore: VoiceprintStore

    // MARK: - Edit state

    @State private var draftName: String = ""
    @State private var draftTitle: String = ""
    @State private var draftCompany: String = ""
    @State private var draftSide: Side = .other
    @State private var draftLinkedin: String = ""

    /// Company autocomplete dropdown visible
    @State private var showCompletions = false
    @State private var player = SamplePlayer()

    // MARK: - Voiceprint action state

    @State private var vpActionStatus: String?
    @State private var vpRebuilding = false
    @State private var vpReenrolling = false
    /// ID of the voiceprint pending delete confirmation.
    @State private var pendingDeleteVP: UUID?

    // MARK: - Init helpers

    // Load the current contact fields into draft state. Called once from onAppear
    // and also from onChange(of: person.id) to reset when a different person is selected.
    private func loadDraft() {
        draftName = person.displayName
        if let contact = person.contact {
            // Strip a trailing ", <company>" from the stored title (upsertPerson bakes it in).
            draftTitle = Self.strippedTitle(contact.title, company: contact.company)
            draftCompany = contact.company ?? ""
            draftSide = contact.side
            draftLinkedin = contact.linkedin ?? ""
        } else {
            // Voiceprint-only: pre-fill name only.
            draftTitle = ""
            draftCompany = ""
            draftSide = .other
            draftLinkedin = ""
        }
    }

    /// Strip trailing ", <company>" from a stored title string.
    /// upsertPerson stores title as "Senior Engineer, Vanguard"; the editor should show "Senior Engineer".
    /// Also handles the bare-company case: when title == company (e.g. title = "Acme", company = "Acme"),
    /// which happens when a contact has no title and upsertPerson falls back to storing just the company name.
    static func strippedTitle(_ raw: String?, company: String?) -> String {
        guard let raw = raw, let co = company, !co.isEmpty else { return raw ?? "" }
        // Bare-company case: title IS the company name (no title was set).
        // Must check this before the suffix strip so "Acme" doesn't pass through
        // and get re-baked as "Acme, Acme" on the next save.
        if raw.caseInsensitiveCompare(co) == .orderedSame {
            return ""
        }
        let suffix = ", \(co)"
        if raw.lowercased().hasSuffix(suffix.lowercased()) {
            return String(raw.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return raw
    }

    // MARK: - Derived

    private var isDirty: Bool {
        draftName.trimmingCharacters(in: .whitespaces) != person.displayName
        || draftTitle.trimmingCharacters(in: .whitespaces) != Self.strippedTitle(person.contact?.title, company: person.contact?.company)
        || draftCompany.trimmingCharacters(in: .whitespaces) != (person.contact?.company ?? "")
        || draftSide != (person.contact?.side ?? .other)
        || draftLinkedin.trimmingCharacters(in: .whitespaces) != (person.contact?.linkedin ?? "")
    }

    private var nameIsValid: Bool {
        !draftName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isVoiceprintOnly: Bool { person.contact == nil }

    /// All company names from the vault (internal + customer), sorted, deduped.
    private var allCompanyNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for c in vault.contacts {
            guard let co = c.company else { continue }
            if seen.insert(co.lowercased()).inserted { result.append(co) }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Company completions for the current draftCompany input.
    private var companyCompletions: [String] {
        let q = draftCompany.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allCompanyNames }
        let prefix = allCompanyNames.filter { $0.lowercased().hasPrefix(q) }
        let contains = allCompanyNames.filter { !$0.lowercased().hasPrefix(q) && $0.lowercased().contains(q) }
        return prefix + contains
    }

    // MARK: - Voiceprint action helpers

    /// True when this person has a retained clip but no WhisperKit (pyannote) print.
    /// Used to show the "Rebuild WhisperKit" button.
    private var canRebuildWhisperKit: Bool {
        let name = person.displayName.lowercased()
        let hasPyannote = voiceprintStore.voiceprints.contains {
            $0.name.lowercased() == name &&
            $0.embeddingModel == VoiceprintStore.speakerKitEmbeddingModel
        }
        let hasClip = person.voiceprints.contains { $0.audioSample != nil }
        return !hasPyannote && hasClip
    }

    /// True when this person has a retained clip and a FluidAudio (wespeaker) print
    /// (including stale prints, which appear as "missing" in the engine badge row since
    /// engineLabel returns nil for unknown model strings). Used to show "Re-enroll FluidAudio".
    private var canReenrollFluidAudio: Bool {
        let hasClip = person.voiceprints.contains { $0.audioSample != nil }
        // Any wespeaker-model print OR a stale print (unknown model) are candidates.
        // A stale print has no current engine mapping, so the person shows as missing FluidAudio
        // in the badge row. Regenerating from the clip via FluidAudio restamps it wespeaker_v2.
        let hasFluidOrStalePrint = voiceprintStore.voiceprints.contains {
            $0.name.caseInsensitiveCompare(person.displayName) == .orderedSame
            && ($0.embeddingModel == VoiceprintStore.embeddingModel
                || !VoiceprintStore.currentEmbeddingModels.contains($0.embeddingModel))
        }
        return hasClip && hasFluidOrStalePrint
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                headerRow
                Divider()
                fieldsSection
                if isVoiceprintOnly {
                    rolodexPrompt
                }
                Divider()
                voiceprintSection
                actionBar
            }
            .padding(Theme.Spacing.xLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { loadDraft() }
        .onChange(of: person.id) { loadDraft() }
        .onDisappear { player.stop() }
        .confirmationDialog(
            "Delete voiceprint?",
            isPresented: Binding(
                get: { pendingDeleteVP != nil },
                set: { if !$0 { pendingDeleteVP = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteVP { voiceprintStore.delete(id) }
                pendingDeleteVP = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteVP = nil }
        } message: {
            Text("The voiceprint and any retained clip will be permanently removed. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text(isVoiceprintOnly ? "Add to Rolodex" : "Edit Person")
                .font(Theme.Typography.screenTitle)
            Spacer()
        }
    }

    // MARK: - Fields

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            editorRow(label: "Name") {
                TextField("Full name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
            }

            editorRow(label: "Title") {
                TextField("Job title", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
            }

            editorRow(label: "Company") {
                companyField
            }

            editorRow(label: "Side") {
                Picker("Side", selection: $draftSide) {
                    Text("Internal").tag(Side.internalTeam)
                    Text("Customer").tag(Side.customer)
                    Text("Other").tag(Side.other)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
            }

            editorRow(label: "LinkedIn") {
                TextField("https://linkedin.com/in/...", text: $draftLinkedin)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func editorRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.small) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var companyField: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Company name", text: $draftCompany, onEditingChanged: { editing in
                showCompletions = editing && !companyCompletions.isEmpty
            })
            .textFieldStyle(.roundedBorder)
            .onChange(of: draftCompany) {
                showCompletions = !companyCompletions.isEmpty
                    && !draftCompany.trimmingCharacters(in: .whitespaces).isEmpty
                // Auto-infer side from known company (unless user has already set a non-other side).
                if draftSide == .other || draftSide == (person.contact?.side ?? .other) {
                    if let match = allCompanyNames.first(where: {
                        $0.lowercased() == draftCompany.trimmingCharacters(in: .whitespaces).lowercased()
                    }) {
                        // Known company: inherit its side from the vault.
                        if let knownContact = vault.contacts.first(where: { $0.company?.lowercased() == match.lowercased() }) {
                            draftSide = knownContact.side
                        }
                    }
                }
            }

            if showCompletions {
                completionPopover
            }
        }
    }

    private var completionPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(companyCompletions.prefix(6), id: \.self) { suggestion in
                Text(suggestion)
                    .font(Theme.Typography.caption)
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, Theme.Spacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draftCompany = suggestion
                        showCompletions = false
                    }
                    .background(Color.clear)
                Divider()
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .zIndex(10)
    }

    // MARK: - Rolodex prompt for voiceprint-only people

    private var rolodexPrompt: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "person.badge.plus")
                .foregroundStyle(Theme.Palette.accent)
            Text("Fill in a company or title and Save to add this person to your Rolodex.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Spacing.medium)
        .background(Theme.Radius.rect(Theme.Radius.small).fill(Theme.Palette.accent.opacity(0.07)))
    }

    // MARK: - Voiceprint section (status + actions)

    private var voiceprintSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Voiceprint")
                .font(Theme.Typography.sectionHeader)

            engineStatusRow

            if !person.voiceprints.isEmpty {
                voiceprintStats
                Divider()
                voiceprintRows
            }

            voiceprintActions

            if let status = vpActionStatus {
                Text(status)
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(.secondary)
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

    /// Per-print rows showing engine, sample count, updated date, and a delete button.
    @ViewBuilder private var voiceprintRows: some View {
        VStack(spacing: Theme.Spacing.xSmall) {
            ForEach(person.voiceprints) { vp in
                HStack(spacing: Theme.Spacing.small) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                        Text(engineLabel(for: vp.embeddingModel) ?? vp.embeddingModel)
                            .font(Theme.Typography.caption)
                        Text("\(vp.sampleCount) sample\(vp.sampleCount == 1 ? "" : "s")"
                             + " \u{00B7} updated \(vp.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(Theme.Typography.captionSecondary)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        pendingDeleteVP = vp.id
                    } label: {
                        Image(systemName: "trash")
                            .font(Theme.Typography.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this voiceprint")
                }
                .padding(.vertical, Theme.Spacing.xxSmall)
            }
        }
    }

    /// Rebuild / re-enroll actions shown only when relevant (clip available + missing engine).
    @ViewBuilder private var voiceprintActions: some View {
        if canRebuildWhisperKit || canReenrollFluidAudio {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if canRebuildWhisperKit {
                    HStack(spacing: Theme.Spacing.small) {
                        if vpRebuilding { ProgressView().controlSize(.small).scaleEffect(0.7, anchor: .center) }
                        Button("Rebuild WhisperKit voiceprint") {
                            rebuildWhisperKit()
                        }
                        .disabled(vpRebuilding || vpReenrolling)
                        .font(Theme.Typography.caption)
                    }
                    Text("Generate a WhisperKit voiceprint from the retained clip.")
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                if canReenrollFluidAudio {
                    HStack(spacing: Theme.Spacing.small) {
                        if vpReenrolling { ProgressView().controlSize(.small).scaleEffect(0.7, anchor: .center) }
                        Button("Re-enroll FluidAudio voiceprint") {
                            reenrollFluidAudio()
                        }
                        .disabled(vpRebuilding || vpReenrolling)
                        .font(Theme.Typography.caption)
                    }
                    Text("Regenerate FluidAudio vectors from the retained clip (use after a model upgrade).")
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack {
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.borderless)
            .font(Theme.Typography.body)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(isVoiceprintOnly ? "Add to Rolodex" : "Save") {
                commitSave()
            }
            .buttonStyle(.borderedProminent)
            .font(Theme.Typography.controlLabel)
            .disabled(!isDirty || !nameIsValid)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, Theme.Spacing.small)
    }

    // MARK: - Save logic

    private func commitSave() {
        let newName = draftName.trimmingCharacters(in: .whitespaces)
        let newTitle = draftTitle.trimmingCharacters(in: .whitespaces)
        let newCompany = draftCompany.trimmingCharacters(in: .whitespaces)
        let newLinkedin = draftLinkedin.trimmingCharacters(in: .whitespaces)
        let newSide = draftSide

        // Snap company casing to match the vault's canonical spelling.
        let snappedCompany = snapCompanyCasing(newCompany)
        // Re-derive side for snapped company if unchanged from draft.
        let resolvedSide: Side
        if snappedCompany.isEmpty {
            resolvedSide = .other
        } else {
            resolvedSide = newSide
        }

        let originalName = person.displayName
        let nameChanged = newName.lowercased() != originalName.lowercased()

        showCompletions = false

        if nameChanged {
            // Step 1: fan-out rename across both stores.
            RecordingController.renamePerson(
                from: originalName, to: newName,
                vault: vault, voiceprints: voiceprintStore)
            // Step 2: apply the remaining field edits on the renamed contact.
            vault.upsertPerson(name: newName, title: newTitle,
                               company: snappedCompany, linkedin: newLinkedin,
                               side: resolvedSide, clearLinkedinIfEmpty: true)
        } else {
            vault.upsertPerson(name: originalName, title: newTitle,
                               company: snappedCompany, linkedin: newLinkedin,
                               side: resolvedSide, clearLinkedinIfEmpty: true)
        }

        onSave(newName)
    }

    /// Return `company` with casing snapped to the vault's existing spelling,
    /// if it matches (case-insensitively). Returns the input unchanged otherwise.
    private func snapCompanyCasing(_ company: String) -> String {
        guard !company.isEmpty else { return company }
        let lower = company.lowercased()
        return allCompanyNames.first { $0.lowercased() == lower } ?? company
    }

    // MARK: - Voiceprint rebuild/re-enroll

    /// Rebuild a WhisperKit (pyannote) voiceprint from the retained clip for this person.
    /// Uses the same SpeakerKitDiarizer path as SpeakersSettingsView.rebuildPyannoteFromClips,
    /// scoped to the single voiceprint that has the clip.
    private func rebuildWhisperKit() {
        guard let clipVP = person.voiceprints.first(where: { $0.audioSample != nil }),
              let samples = voiceprintStore.clipSamples(clipVP.id) else {
            vpActionStatus = "No retained clip to rebuild from."
            return
        }
        vpRebuilding = true
        vpActionStatus = "Rebuilding WhisperKit voiceprint from clip..."
        Task {
            let diarizer = SpeakerKitDiarizer()
            defer { Task { await diarizer.unload() } }
            guard let centroid = await diarizer.embedding(forClip: samples) else {
                vpRebuilding = false
                vpActionStatus = "Rebuild failed -- clip too short or low quality."
                return
            }
            _ = voiceprintStore.enroll(name: clipVP.name,
                                       embedding: centroid,
                                       model: VoiceprintStore.speakerKitEmbeddingModel)
            vpRebuilding = false
            vpActionStatus = "WhisperKit voiceprint rebuilt."
            AppLog.log("PersonEditorView: rebuilt WhisperKit voiceprint for \(clipVP.name)", category: "people")
        }
    }

    /// Re-enroll a FluidAudio voiceprint from the retained clip. Handles both the
    /// "stale model" recovery case and a standard re-embed after a FluidAudio upgrade.
    /// Mirrors the per-person portion of SpeakersSettingsView.reEnrollFromClips.
    private func reenrollFluidAudio() {
        // Find a FluidAudio (wespeaker) or stale print that has the clip.
        // Never fall back to a pyannote print: reEnroll re-stamps the model as wespeaker_v2,
        // which would silently destroy WhisperKit identification for that person
        // (same protection as SpeakersSettingsView.reEnrollFromClips).
        let candidate = person.voiceprints.first { vp in
            (vp.embeddingModel == VoiceprintStore.embeddingModel
                || !VoiceprintStore.currentEmbeddingModels.contains(vp.embeddingModel))
            && vp.audioSample != nil
        }

        guard let clipVP = candidate,
              let samples = voiceprintStore.clipSamples(clipVP.id) else {
            vpActionStatus = "No retained clip to re-enroll from."
            return
        }
        vpReenrolling = true
        vpActionStatus = "Re-enrolling FluidAudio voiceprint from clip..."
        Task {
            guard let embs = await FluidAudioEngine.embeddings(forClip: samples, clusterThreshold: 0.6) else {
                vpReenrolling = false
                vpActionStatus = "Re-enroll failed -- clip too short or low quality."
                return
            }
            voiceprintStore.reEnroll(clipVP.id, embeddings: embs)
            vpReenrolling = false
            vpActionStatus = "FluidAudio voiceprint re-enrolled."
            AppLog.log("PersonEditorView: re-enrolled FluidAudio voiceprint for \(clipVP.name)", category: "people")
        }
    }

    // MARK: - Helpers

    private func playClip(_ vp: Voiceprint) {
        guard let data = vp.audioSample else { return }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        AppLog.log("PersonEditorView: playing \(vp.name) clip -- \(samples.count) samples", category: "people")
        player.play(samples: samples)
    }
}
