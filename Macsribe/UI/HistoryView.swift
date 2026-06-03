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
    /// Observed directly so live job state (pending/failed) republishes the view.
    @ObservedObject private var summaryService = RecordingController.shared.summaryService
    @State private var selection: TranscriptItem.ID?
    @State private var filter: HistoryFilter = .needsSpeakers

    enum HistoryFilter: String, CaseIterable, Identifiable {
        case all = "All", review = "Review", needsSpeakers = "Unassigned", unprocessed = "Unprocessed", processed = "Processed"
        var id: String { rawValue }
    }

    private var filteredItems: [TranscriptItem] {
        switch filter {
        case .all: return store.items
        case .review: return store.items.filter { $0.summaryReadyURL != nil }
        case .needsSpeakers: return store.items.filter { $0.hasUnnamedSpeakers }
        case .unprocessed: return store.items.filter { !$0.isProcessed }
        case .processed: return store.items.filter { $0.isProcessed }
        }
    }
    /// Count of summaries staged and waiting for review (drives discoverability).
    private var reviewCount: Int { store.items.filter { $0.summaryReadyURL != nil }.count }
    /// Item awaiting the "speakers not assigned" confirmation before summarizing.
    @State private var pendingProcessItem: TranscriptItem?
    /// Add-attendee popover (for someone present who didn't speak / was forgotten).
    @State private var addingAttendee = false
    @State private var attendeeDraft = ""
    /// Editable destination for the summary currently under review (seeded from meta.filing).
    @State private var reviewDestination = ""

    var body: some View {
        // Resizable list/detail split (the window sidebar is a plain HStack, not a
        // NavigationSplitView, so a single HSplitView here is safe and gives a draggable
        // divider). The list has a sensible min/ideal/max; the detail fills the rest.
        HSplitView {
            list
                .frame(minWidth: 220, idealWidth: 300, maxWidth: 480)
                .frame(maxHeight: .infinity)
            detail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.refresh(); store.startWatching(); seedReviewDestination() }
        .onChange(of: selection) { seedReviewDestination() }
        .onChange(of: selectedItem?.summaryReadyURL) { seedReviewDestination() }
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
            Button("Summarize anyway") { summarize(item); pendingProcessItem = nil }
            Button("Cancel", role: .cancel) { pendingProcessItem = nil }
        } message: { _ in
            Text("This transcript still has unnamed speakers (e.g. \"Speaker 1\"). The summary attributes actions and discussion to whoever's labelled, so it may misattribute. Detect/assign speakers first for a higher-quality note.")
        }
    }

    /// Seed the editable review destination from the selected item's filing.
    private func seedReviewDestination() {
        if let item = selectedItem, item.summaryReadyURL != nil {
            reviewDestination = item.meta.filing
        }
    }

    /// Queue a background Claude summary; switch to the Review filter so it's visible when ready.
    private func summarize(_ item: TranscriptItem) {
        recording.summaryService.summarize(item)
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            Picker("", selection: $filter) {
                ForEach(HistoryFilter.allCases) { f in
                    Text(f == .review && reviewCount > 0 ? "Review (\(reviewCount))" : f.rawValue).tag(f)
                }
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
        let (label, color): (String, Color) =
            item.summaryReadyURL != nil ? ("Review", .blue)
            : item.isProcessed ? ("Processed", .green)
            : ("Unprocessed", .orange)
        return Text(label)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let item = selectedItem {
            VStack(spacing: 0) {
                detailHeader(item)
                Divider()
                if let staged = item.summaryReadyURL {
                    reviewPane(item, staged: staged)
                } else {
                    summaryStatusBar(item)
                    TranscriptPreviewView(url: item.url, reloadToken: recording.transcriptRevision)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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

    /// Live "summarizing…/failed" bar for a transcript without a staged summary yet.
    @ViewBuilder private func summaryStatusBar(_ item: TranscriptItem) -> some View {
        switch summaryService.state(for: item) {
        case .pending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.7, anchor: .center)
                Text("Summarizing in the background…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(.quaternary.opacity(0.35))
            Divider()
        case .failed(let reason):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Retry") { summarize(item) }.font(.caption)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(.orange.opacity(0.10))
            Divider()
        case .none:
            EmptyView()
        }
    }

    /// The review pane shown when a summary is staged: editable destination above the
    /// rendered note, with Commit / Discard / Regenerate.
    @ViewBuilder private func reviewPane(_ item: TranscriptItem, staged: URL) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Summary ready — review, set where it's filed, then commit to your vault.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("Will be filed to:").font(.caption).foregroundStyle(.secondary)
                    DestinationField(path: $reviewDestination,
                                     destinations: vault.destinations,
                                     firstRoot: settings.scanRoots.first ?? "Internal")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            TranscriptPreviewView(url: staged, reloadToken: recording.transcriptRevision)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Button(role: .destructive) { summaryService.discard(item) } label: {
                    Label("Discard", systemImage: "trash")
                }
                Button { summaryService.regenerate(item) } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                Spacer()
                Button { summaryService.commit(item, destination: reviewDestination) } label: {
                    Label("Commit & File", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
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

            // Summarize → background Claude → staged for review. Hidden while a summary is
            // already staged (the review pane handles it) or currently running.
            if item.summaryReadyURL == nil {
                let pending = summaryService.state(for: item).map { if case .pending = $0 { return true } else { return false } } ?? false
                let summarizeLabel = Label(item.isProcessed ? "Re-summarize" : "Summarize", systemImage: "sparkles")
                if item.hasUnnamedSpeakers && audioAvailable(item) {
                    Button { pendingProcessItem = item } label: { summarizeLabel }
                        .buttonStyle(.bordered).disabled(busy || pending)
                } else {
                    Button { summarize(item) } label: { summarizeLabel }
                        .buttonStyle(.borderedProminent).disabled(busy || pending)
                }
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

    private func detectSpeakers(_ item: TranscriptItem) {
        recording.reprocessSpeakers(
            forAudioPath: item.meta.audio, transcript: item.url,
            attendees: item.meta.attendees.joined(separator: ", "),
            title: item.meta.title, filing: item.meta.filing)
    }

    // MARK: Helpers

    private static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
