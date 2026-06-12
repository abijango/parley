import SwiftUI

/// At-stop "Assign speakers" review panel (FluidAudio). Lists the speakers found in
/// the recording; for each you can play a voice sample and name them (one-tap from
/// this call's attendees, or free text with Rolodex autocomplete). Naming relabels
/// the transcript and enrols the voiceprint; "Done" rewrites the saved note.
struct AssignSpeakersView: View {
    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var vault: VaultDirectory
    @Environment(\.dismiss) private var dismiss
    let review: RecordingController.SpeakerReview

    @State private var player = SamplePlayer()
    @State private var names: [String: String] = [:]   // speakerId → assigned name (local echo)
    @State private var namingId: String?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text("Assign speakers").font(Theme.Typography.sheetTitle)
                Text("Name each speaker to label the transcript and remember their voice for next time. Tap ▶ to hear a sample.")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.large)

            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(review.speakers) { speaker in
                        row(for: speaker)
                        Divider()
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { player.stop(); recording.finishSpeakerReview(); dismiss() }
                    .glassProminentButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.large)
            .chromeSurface()
        }
        .frame(width: 520, height: 440)
        .onDisappear { player.stop() }
    }

    private func displayName(_ s: CallSpeakerSummary) -> String {
        names[s.id] ?? s.resolvedName ?? "Speaker \(s.id)"
    }
    private func isNamed(_ s: CallSpeakerSummary) -> Bool {
        names[s.id] != nil || s.resolvedName != nil
    }

    private func row(for s: CallSpeakerSummary) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Button { playSample(s) } label: { Image(systemName: "play.circle").font(.title2) }
                .buttonStyle(.plain)
                .help("Play a sample of this speaker")

            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(displayName(s)).font(Theme.Typography.controlLabel)
                Text("\(Int(s.talkSeconds))s speaking")
                    .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                if !s.firstLine.isEmpty {
                    Text("“\(s.firstLine)”")
                        .font(Theme.Typography.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()

            Button(isNamed(s) ? "Rename…" : "Name…") {
                draft = names[s.id] ?? s.resolvedName ?? ""
                namingId = s.id
            }
            .glassButton()
            .popover(isPresented: Binding(get: { namingId == s.id }, set: { if !$0 { namingId = nil } })) {
                namer(for: s)
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
    }

    // Mirrors the live-transcript naming popover (LiveTranscriptView) so the
    // affordance reads identically wherever a speaker is named.
    private func namer(for s: CallSpeakerSummary) -> some View {
        let d = draft.trimmingCharacters(in: .whitespaces)
        // The review carries its own attendee snapshot (it may be for a History note,
        // not the live Record session) — use it rather than the live `recording.attendees`.
        let attendees = TranscriptWriter.splitAttendees(review.attendees)
        // Fuzzy suggestions: contacts plausibly matching what the user typed.
        // Returns [] when draft is empty or is already an exact name/alias hit.
        let suggestions: [Contact] = d.isEmpty ? [] :
            recording.vault.suggestMatches(for: d)

        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Name this speaker").font(Theme.Typography.sheetTitle)
            if !attendees.isEmpty {
                Text("In this call")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    ForEach(attendees, id: \.self) { n in
                        Button(n) { assign(s.id, n) }.glassButton()
                    }
                }
                Divider()
            }
            Text("Other name")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
            TextField("Type a name", text: $draft)
                .textFieldStyle(.roundedBorder).frame(width: 240)
                .onSubmit { assign(s.id, draft) }
            if !suggestions.isEmpty {
                // Show as chips: tapping a suggestion names with canonical + records alias.
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text("Rolodex match")
                        .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                    ForEach(suggestions, id: \.name) { contact in
                        Button(action: {
                            assignSuggestion(s.id, suggestion: contact, typedDraft: d)
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
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Save") { assign(s.id, draft) }
                    .glassProminentButton()
                    .keyboardShortcut(.defaultAction).disabled(d.isEmpty)
            }
        }
        .padding(Theme.Spacing.medium).frame(width: 264)
    }

    private func assign(_ id: String, _ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        recording.nameSpeaker(id, as: name)   // relabels transcript + enrols voiceprint + adds attendee
        names[id] = name
        namingId = nil
    }

    /// Assign a Rolodex suggestion. Names the speaker with the canonical contact name,
    /// and -- when the user typed something different -- records that draft as an alias
    /// so future meetings resolve it automatically.
    private func assignSuggestion(_ id: String, suggestion: Contact, typedDraft: String) {
        recording.nameSpeaker(id, as: suggestion.name)
        names[id] = suggestion.name
        // Only record alias when what the user typed differs from the canonical name.
        if suggestion.name.caseInsensitiveCompare(typedDraft) != .orderedSame && !typedDraft.isEmpty {
            recording.linkAttendeeToExisting(detected: typedDraft, canonicalName: suggestion.name)
        }
        namingId = nil
    }

    private func playSample(_ s: CallSpeakerSummary) {
        let files = [review.mixedCaf].compactMap { $0 }
        AppLog.log("Play sample for \(displayName(s)): \(String(format: "%.1f–%.1fs", s.sampleStart, s.sampleEnd)) from \(files.first?.lastPathComponent ?? "no file")", category: "record")
        player.play(files: files, start: s.sampleStart, end: s.sampleEnd)
    }
}
