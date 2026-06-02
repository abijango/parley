import SwiftUI
import AppKit

/// Browses every transcript in the app-owned vault folder. The sidebar lists
/// items newest-first; selecting one renders its note and exposes per-item
/// actions (open in Obsidian, reveal audio, process/re-process).
struct HistoryView: View {
    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var store: TranscriptStore
    @EnvironmentObject private var vault: VaultDirectory
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: TranscriptItem.ID?
    @State private var filter: HistoryFilter = .all
    /// The item currently being processed/re-processed (drives the streaming bar).
    @State private var runningItemID: TranscriptItem.ID?

    enum HistoryFilter: String, CaseIterable, Identifiable {
        case all = "All", needsSpeakers = "Unassigned", unprocessed = "Unprocessed", processed = "Processed"
        var id: String { rawValue }
    }

    private var filteredItems: [TranscriptItem] {
        switch filter {
        case .all: return store.items
        case .needsSpeakers: return store.items.filter { $0.hasUnnamedSpeakers }
        case .unprocessed: return store.items.filter { !$0.isProcessed }
        case .processed: return store.items.filter { $0.isProcessed }
        }
    }
    @State private var diffExisting = ""
    @State private var diffStaged = ""
    @State private var showDiff = false
    /// Item awaiting the "speakers not assigned" confirmation before processing.
    @State private var pendingProcessItem: TranscriptItem?
    /// Add-attendee popover (for someone present who didn't speak / was forgotten).
    @State private var addingAttendee = false
    @State private var attendeeDraft = ""

    var body: some View {
        // A plain HStack (not a nested HSplitView) so this view doesn't add a second
        // splitter inside the window's NavigationSplitView detail — that nesting broke
        // the layout on narrow displays. Fixed-width list, detail fills the rest.
        HStack(spacing: 0) {
            list
                .frame(width: 300)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.refresh() }
        .onChange(of: recording.notes.pendingDiff) { presentDiffIfReady() }
        // Assign-speakers review for an on-demand "Detect speakers" run from History.
        .sheet(isPresented: Binding(
            get: { recording.pendingSpeakerReview != nil },
            set: { if !$0 { recording.pendingSpeakerReview = nil } })) {
            if let review = recording.pendingSpeakerReview {
                AssignSpeakersView(review: review)
            }
        }
        .confirmationDialog(
            "Speakers aren't all named",
            isPresented: Binding(get: { pendingProcessItem != nil },
                                 set: { if !$0 { pendingProcessItem = nil } }),
            presenting: pendingProcessItem
        ) { item in
            Button("Detect speakers first") { detectSpeakers(item); pendingProcessItem = nil }
            Button("Process anyway") { startProcessing(item); pendingProcessItem = nil }
            Button("Cancel", role: .cancel) { pendingProcessItem = nil }
        } message: { _ in
            Text("This transcript still has unnamed speakers (e.g. \"Speaker 1\"). The summary attributes actions and discussion to whoever's labelled, so it may misattribute. Detect/assign speakers first for a higher-quality note.")
        }
        .sheet(isPresented: $showDiff) {
            NoteDiffView(
                existing: diffExisting,
                staged: diffStaged,
                onAccept: {
                    let url = recording.notes.commitReprocess()
                    showDiff = false
                    runningItemID = nil
                    recording.notes.reset()
                    store.refresh()
                    if let url { AppLog.log("History: accepted reprocess for \(url.lastPathComponent)", category: "history") }
                },
                onDiscard: {
                    recording.notes.discardReprocess()
                    showDiff = false
                    runningItemID = nil
                    store.refresh()
                }
            )
        }
    }

    private func presentDiffIfReady() {
        guard let diff = recording.notes.pendingDiff else { return }
        diffExisting = (try? String(contentsOf: diff.existingURL, encoding: .utf8)) ?? ""
        diffStaged = (try? String(contentsOf: diff.stagedURL, encoding: .utf8)) ?? ""
        showDiff = true
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            Picker("", selection: $filter) {
                ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()

            if filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(filter == .all ? "No transcripts yet." : "No \(filter.rawValue.lowercased()) transcripts.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredItems, selection: $selection) { item in
                    row(item).tag(item.id)
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.meta.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if item.hasUnnamedSpeakers {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.orange).font(.caption)
                        .help("Speakers not assigned — needs review")
                }
                statusBadge(item)
            }
            HStack(spacing: 6) {
                Image(systemName: item.meta.type == "manual" ? "pencil" : "mic")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(Self.dateString(item.meta.date))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !item.meta.attendees.isEmpty {
                Text(item.meta.attendees.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ item: TranscriptItem) -> some View {
        Text(item.isProcessed ? "Processed" : "Unprocessed")
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                (item.isProcessed ? Color.green : Color.orange).opacity(0.18),
                in: Capsule()
            )
            .foregroundStyle(item.isProcessed ? Color.green : Color.orange)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let item = selectedItem {
            VStack(spacing: 0) {
                detailHeader(item)
                if runningItemID == item.id {
                    Divider()
                    NotesActionBar(
                        generator: recording.notes,
                        destination: item.meta.filing,
                        attendees: item.meta.attendees.joined(separator: ", "),
                        model: settings.claudeModel,
                        onGenerate: { startProcessing(item) }
                    )
                }
                Divider()
                TranscriptPreviewView(url: item.url, reloadToken: recording.transcriptRevision)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 34)).foregroundStyle(.secondary)
                Text("Select a transcript to preview it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedItem: TranscriptItem? {
        guard let selection else { return nil }
        return store.items.first { $0.id == selection }
    }

    private func detailHeader(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.meta.title).font(.title3).bold()
                    metadataLine(item)
                }
                Spacer()
                statusBadge(item)
            }
            if item.hasUnnamedSpeakers {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                    Text(audioAvailable(item)
                         ? "Speakers aren't assigned yet. Detect & name them so the summary attributes everything correctly."
                         : "Speakers aren't assigned and the audio is no longer available to detect them.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            actionRow(item)
            if recording.offlinePass == .running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7, anchor: .center)
                    Text("Detecting speakers…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    private func metadataLine(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.dateString(item.meta.date))
                .font(.caption).foregroundStyle(.secondary)
            if !item.meta.attendees.isEmpty {
                Text("Attendees: \(item.meta.attendees.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !item.meta.filing.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Filing: \(item.meta.filing)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func actionRow(_ item: TranscriptItem) -> some View {
        HStack(spacing: 10) {
            if let notePath = item.meta.note, !notePath.isEmpty {
                Button {
                    recording.notes.openInObsidian(URL(fileURLWithPath: notePath))
                } label: {
                    Label("Open in Obsidian", systemImage: "arrow.up.right.square")
                }
            }

            if let audioPath = item.meta.audio, !audioPath.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: audioPath)])
                } label: {
                    Label("Reveal audio", systemImage: "waveform")
                }
            }

            addAttendeeButton(item)

            if audioAvailable(item) {
                // When speakers still need assigning, this is the primary action;
                // otherwise it's a secondary "re-run".
                if item.hasUnnamedSpeakers {
                    Button { detectSpeakers(item) } label: {
                        Label("Detect speakers", systemImage: "person.2.wave.2")
                    }
                    .buttonStyle(.borderedProminent).disabled(busy)
                    .help("Diarize this recording and assign names")
                } else {
                    Button { detectSpeakers(item) } label: {
                        Label("Detect speakers", systemImage: "person.2.wave.2")
                    }
                    .disabled(busy)
                    .help("Re-run diarization + speaker ID on this recording's audio")
                }
            }

            Spacer()

            // Warn (but allow) if the transcript still has unnamed speakers — the
            // summary attributes actions/discussion to whoever's labelled.
            let processLabel = Label(item.isProcessed ? "Re-process" : "Process",
                                     systemImage: "arrow.triangle.2.circlepath")
            if item.hasUnnamedSpeakers && audioAvailable(item) {
                Button { pendingProcessItem = item } label: { processLabel }
                    .buttonStyle(.bordered).disabled(busy)
            } else {
                Button {
                    if unattributed(item) { pendingProcessItem = item } else { startProcessing(item) }
                } label: { processLabel }
                .buttonStyle(.borderedProminent).disabled(busy)
            }
        }
    }

    /// Add a present-but-non-speaking (or forgotten) attendee to this transcript.
    private func addAttendeeButton(_ item: TranscriptItem) -> some View {
        Button { attendeeDraft = ""; addingAttendee = true } label: {
            Label("Add attendee", systemImage: "person.badge.plus")
        }
        .disabled(busy)
        .popover(isPresented: $addingAttendee) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add an attendee").font(.headline)
                Text("For someone who was present but didn't speak, or a name missed during the call. No transcript line is attributed to them.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Name", text: $attendeeDraft)
                    .textFieldStyle(.roundedBorder).frame(width: 240)
                    .onSubmit { commitAddAttendee(item) }
                let matches = attendeeMatches(item)
                if !matches.isEmpty {
                    ForEach(matches, id: \.self) { p in
                        Button(p) { attendeeDraft = p }.buttonStyle(.plain).font(.callout)
                    }
                }
                HStack {
                    Spacer()
                    Button("Add") { commitAddAttendee(item) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(attendeeDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12).frame(width: 270)
        }
    }

    private func attendeeMatches(_ item: TranscriptItem) -> [String] {
        let d = attendeeDraft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !d.isEmpty else { return [] }
        let have = Set(item.meta.attendees.map { $0.lowercased() })
        return vault.people.filter { $0.lowercased().contains(d) && !have.contains($0.lowercased()) }
            .prefix(5).map { $0 }
    }

    private func commitAddAttendee(_ item: TranscriptItem) {
        let name = attendeeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        recording.addAttendeeToTranscript(item.url, name: name)
        addingAttendee = false
        attendeeDraft = ""
    }

    /// Detection or note generation is in flight — disable the action buttons.
    private var busy: Bool {
        recording.notes.isRunning || recording.offlinePass == .running
    }

    private func audioAvailable(_ item: TranscriptItem) -> Bool {
        guard let a = item.meta.audio, !a.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: a)
    }

    /// True if the saved transcript still has generic, unnamed speaker labels
    /// ("Speaker N" / "Me" / "Remote") — i.e. speakers haven't been assigned.
    private func unattributed(_ item: TranscriptItem) -> Bool {
        guard audioAvailable(item) else { return false }   // nothing to detect from
        guard let text = try? String(contentsOf: item.url, encoding: .utf8) else { return false }
        return text.contains("] Speaker ") || text.contains("] Me:") || text.contains("] Remote:")
    }

    private func detectSpeakers(_ item: TranscriptItem) {
        recording.reprocessSpeakers(
            forAudioPath: item.meta.audio, transcript: item.url,
            attendees: item.meta.attendees.joined(separator: ", "),
            title: item.meta.title, filing: item.meta.filing)
    }

    /// Runs Claude for the given item. An already-processed item re-processes into
    /// staging (then the diff sheet appears via `pendingDiff`); an unprocessed item
    /// runs a fresh filing run and, on success, moves to `Processed/`.
    private func startProcessing(_ item: TranscriptItem) {
        guard !recording.notes.isRunning else { return }
        runningItemID = item.id
        recording.notes.reset()

        if item.isProcessed, let notePath = item.meta.note, !notePath.isEmpty {
            recording.notes.reprocess(
                transcriptURL: item.url,
                existingNoteURL: URL(fileURLWithPath: notePath),
                destination: item.meta.filing,
                attendees: item.meta.attendees.joined(separator: ", "),
                settings: settings)
        } else {
            recording.notes.generate(
                transcriptURL: item.url,
                destination: item.meta.filing,
                attendees: item.meta.attendees.joined(separator: ", "),
                settings: settings,
                onFreshSuccess: { transcriptURL, notePath in
                    recording.markProcessed(transcriptURL: transcriptURL, notePath: notePath)
                    runningItemID = nil
                    store.refresh()
                })
        }
    }

    // MARK: Helpers

    private static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
