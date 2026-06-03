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
    @State private var selection = Set<TranscriptItem.ID>()
    @State private var filter: HistoryFilter = .needsSpeakers
    /// Search query, matched against title / attendees / filing (and bodies when enabled).
    @State private var searchQuery = ""
    @State private var searchInContents = false
    // File-management sheet (one at a time, enum-driven to avoid stacking modifiers).
    @State private var fileOp: FileOp?
    @State private var renameDraft = ""
    @State private var refileDraft = ""
    @State private var deleteAudioToo = true
    @State private var deleteNoteToo = true

    /// The active file-management sheet and its target(s).
    enum FileOp: Identifiable {
        case rename(TranscriptItem)
        case refile([TranscriptItem])
        case delete([TranscriptItem])
        var id: String {
            switch self {
            case .rename(let i): return "rename:\(i.id)"
            case .refile(let items): return "refile:\(items.map(\.id).joined(separator: "|"))"
            case .delete(let items): return "delete:\(items.map(\.id).joined(separator: "|"))"
            }
        }
    }

    enum HistoryFilter: String, CaseIterable, Identifiable {
        case all = "All", review = "Review", needsSpeakers = "Unassigned", unprocessed = "Unprocessed", processed = "Processed"
        var id: String { rawValue }
    }

    private var filteredItems: [TranscriptItem] {
        let base: [TranscriptItem]
        switch filter {
        case .all: base = store.items
        case .review: base = store.items.filter { $0.summaryReadyURL != nil }
        case .needsSpeakers: base = store.items.filter { $0.hasUnnamedSpeakers }
        case .unprocessed: base = store.items.filter { !$0.isProcessed }
        case .processed: base = store.items.filter { $0.isProcessed }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { matchesSearch($0, query: q) }
    }

    /// Title / attendees / filing match (cheap, in-memory); body match only when content
    /// search is toggled on (reads the file — fine for the small number of meeting notes).
    private func matchesSearch(_ item: TranscriptItem, query q: String) -> Bool {
        if item.meta.title.lowercased().contains(q) { return true }
        if item.meta.filing.lowercased().contains(q) { return true }
        if item.meta.attendees.contains(where: { $0.lowercased().contains(q) }) { return true }
        if searchInContents, let text = try? String(contentsOf: item.url, encoding: .utf8) {
            return text.range(of: q, options: .caseInsensitive) != nil
        }
        return false
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
        .sheet(item: $fileOp) { op in
            switch op {
            case .rename(let item): renameSheet(item)
            case .refile(let items): refileSheet(items)
            case .delete(let items): deleteSheet(items)
            }
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

    private func isPending(_ item: TranscriptItem) -> Bool {
        if case .pending = summaryService.state(for: item) { return true }
        return false
    }

    // MARK: List

    /// The list column is navigation chrome (like the window sidebar): it floats
    /// on material while the selected note — the content — sits at base.
    private var list: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            Picker("", selection: $filter) {
                ForEach(HistoryFilter.allCases) { f in
                    Text(f == .review && reviewCount > 0 ? "Review (\(reviewCount))" : f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Theme.Spacing.small)
            Divider()

            if filteredItems.isEmpty {
                listEmptyState
            } else {
                List(filteredItems, selection: $selection) { item in
                    row(item).tag(item.id)
                        .contextMenu { rowMenu(item) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onDeleteCommand { if !selectedItems.isEmpty { beginDelete(selectedItems) } }
            }
        }
        .chromeSurface()
    }

    @ViewBuilder private var listEmptyState: some View {
        if !searchQuery.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No results",
                detail: "No meetings match “\(searchQuery)”.")
        } else if filter == .all {
            EmptyStateView(
                icon: "clock.arrow.circlepath",
                title: "No transcripts yet",
                detail: "Finish a recording and it will appear here.")
        } else {
            EmptyStateView(
                icon: "clock.arrow.circlepath",
                title: "Nothing here",
                detail: "No \(filter.rawValue.lowercased()) transcripts.")
        }
    }

    private var searchBar: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
            TextField("Search meetings", text: $searchQuery)
                .textFieldStyle(.plain)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Toggle(isOn: $searchInContents) {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .toggleStyle(.button).controlSize(.small)
            .help("Also search inside transcript text (slower)")
        }
        .padding(.horizontal, Theme.Spacing.medium).padding(.vertical, Theme.Spacing.small)
    }

    /// Per-row context menu — operates on the right-clicked item (selecting it first if it
    /// isn't part of the current selection).
    @ViewBuilder private func rowMenu(_ item: TranscriptItem) -> some View {
        let targets = selection.contains(item.id) && selection.count > 1 ? selectedItems : [item]
        if targets.count == 1 {
            Button("Rename…") { beginRename(item) }
        }
        Button("Refile…") { beginRefile(targets) }
        Divider()
        if let note = item.meta.note, !note.isEmpty {
            Button("Open note in Obsidian") {
                recording.notes.openInObsidian(URL(fileURLWithPath: note))
            }
        }
        if let audio = item.meta.audio, !audio.isEmpty, FileManager.default.fileExists(atPath: audio) {
            Button("Reveal audio in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: audio)])
            }
        }
        Button("Reveal transcript in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Divider()
        Button(targets.count > 1 ? "Delete \(targets.count) meetings…" : "Delete…", role: .destructive) {
            beginDelete(targets)
        }
    }

    private func row(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack(spacing: Theme.Spacing.small) {
                Text(item.meta.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if isPending(item) {
                    ProgressView().controlSize(.mini)
                        .help("Summarizing in the background…")
                } else if item.hasUnnamedSpeakers {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(Theme.Severity.warning.color)
                        .font(Theme.Typography.caption)
                        .help("Speakers not assigned — needs review")
                }
                statusBadge(item)
            }
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: item.meta.type == "manual" ? "pencil" : "mic")
                    .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                Text(Self.dateString(item.meta.date))
                    .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
            }
            if !item.meta.attendees.isEmpty {
                Text(item.meta.attendees.joined(separator: ", "))
                    .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, Theme.Spacing.xxSmall)
    }

    /// Review → info (accent), Processed → success, Unprocessed → warning. Folds the
    /// ad-hoc `Color.blue` badge into the one-accent rule.
    private func statusBadge(_ item: TranscriptItem) -> some View {
        let (label, severity): (String, Theme.Severity) =
            item.summaryReadyURL != nil ? ("Review", .info)
            : item.isProcessed ? ("Processed", .success)
            : ("Unprocessed", .warning)
        return StatusBadge(label, severity: severity)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if selection.count > 1 {
            bulkPanel
        } else if let item = selectedItem {
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
            EmptyStateView(
                icon: "doc.text.magnifyingglass",
                title: "Nothing selected",
                detail: "Select a transcript to preview it.")
        }
    }

    /// Shown when several meetings are selected — bulk delete / refile / summarize.
    private var bulkPanel: some View {
        let items = selectedItems
        let bytes = items.reduce(Int64(0)) { $0 + store.links(for: $1).audioBytes }
        return VStack(spacing: Theme.Spacing.large) {
            Image(systemName: "checklist")
                .font(.system(size: 30, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 76, height: 76)
                .background(Theme.Palette.accent.opacity(Theme.Opacity.tintFill), in: Circle())
            Text("\(items.count) meetings selected").font(Theme.Typography.sectionHeader)
            if bytes > 0 {
                Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of linked audio")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.Spacing.medium) {
                Button { beginRefile(items) } label: { Label("Refile \(items.count)…", systemImage: "tray.and.arrow.down") }
                    .glassButton()
                Button { items.forEach { summarize($0) } } label: { Label("Summarize \(items.count)", systemImage: "sparkles") }
                    .glassProminentButton()
                    .disabled(busy)
                Button(role: .destructive) { beginDelete(items) } label: { Label("Delete \(items.count)…", systemImage: "trash") }
                    .glassButton()
            }
            Text("Actions apply to all selected meetings.")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xLarge)
    }

    /// Live "summarizing…/failed" bar for a transcript without a staged summary yet.
    @ViewBuilder private func summaryStatusBar(_ item: TranscriptItem) -> some View {
        switch summaryService.state(for: item) {
        case .pending:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView().controlSize(.small).scaleEffect(0.7, anchor: .center)
                Text("Summarizing in the background…")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.small)
            .background(.quaternary.opacity(Theme.Opacity.surface))
            Divider()
        case .failed(let reason):
            StatusBanner(.warning, reason,
                         actionLabel: "Retry", action: { summarize(item) })
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.xSmall)
            Divider()
        case .none:
            EmptyView()
        }
    }

    /// The review pane shown when a summary is staged: editable destination above the
    /// rendered note, with Commit / Discard / Regenerate.
    @ViewBuilder private func reviewPane(_ item: TranscriptItem, staged: URL) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Summary ready — review, set where it's filed, then commit to your vault.")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                HStack(spacing: Theme.Spacing.small) {
                    Text("Will be filed to:")
                        .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    DestinationField(path: $reviewDestination,
                                     destinations: vault.destinations,
                                     firstRoot: settings.scanRoots.first ?? "Internal")
                }
            }
            .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.small)
            .chromeSurface()
            Divider()
            TranscriptPreviewView(url: staged, reloadToken: recording.transcriptRevision)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: Theme.Spacing.medium) {
                Button(role: .destructive) { summaryService.discard(item) } label: {
                    Label("Discard", systemImage: "trash")
                }
                .glassButton()
                Button { summaryService.regenerate(item) } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .glassButton()
                Spacer()
                Button { summaryService.commit(item, destination: reviewDestination) } label: {
                    Label("Commit & File", systemImage: "tray.and.arrow.down")
                }
                .glassProminentButton()
            }
            .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.small)
            .chromeSurface()
        }
    }

    private var selectedItems: [TranscriptItem] {
        store.items.filter { selection.contains($0.id) }
    }
    /// The single selected item, or nil when zero or many are selected.
    private var selectedItem: TranscriptItem? {
        selection.count == 1 ? selectedItems.first : nil
    }

    private func detailHeader(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    Text(item.meta.title).font(Theme.Typography.screenTitle)
                    metadataLine(item)
                }
                Spacer()
                statusBadge(item)
                Menu {
                    Button("Rename…") { beginRename(item) }
                    Button("Refile…") { beginRefile([item]) }
                    Divider()
                    Button("Reveal transcript in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { beginDelete([item]) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Rename, refile, or delete this meeting")
            }
            filesStrip(item)
            if item.hasUnnamedSpeakers {
                StatusBanner(.warning,
                             audioAvailable(item)
                             ? "Speakers aren't assigned yet. Detect & name them so the summary attributes everything correctly."
                             : "Speakers aren't assigned and the audio is no longer available to detect them.",
                             symbol: "person.crop.circle.badge.exclamationmark")
            }
            actionRow(item)
            if recording.offlinePass == .running {
                HStack(spacing: Theme.Spacing.small) {
                    ProgressView().controlSize(.small).scaleEffect(0.7, anchor: .center)
                    Text("Detecting speakers…")
                        .font(Theme.Typography.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(Theme.Spacing.large)
    }

    private func metadataLine(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            Text(Self.dateString(item.meta.date))
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
            if !item.meta.attendees.isEmpty {
                Text("Attendees: \(item.meta.attendees.joined(separator: ", "))")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
            if !item.meta.filing.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Filing: \(item.meta.filing)")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func actionRow(_ item: TranscriptItem) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            if let notePath = item.meta.note, !notePath.isEmpty {
                Button {
                    recording.notes.openInObsidian(URL(fileURLWithPath: notePath))
                } label: {
                    Label("Open in Obsidian", systemImage: "arrow.up.right.square")
                }
                .glassButton()
            }

            if let audioPath = item.meta.audio, !audioPath.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: audioPath)])
                } label: {
                    Label("Reveal audio", systemImage: "waveform")
                }
                .glassButton()
            }

            addAttendeeButton(item)

            if audioAvailable(item) {
                if item.hasUnnamedSpeakers {
                    Button { detectSpeakers(item) } label: {
                        Label("Detect speakers", systemImage: "person.2.wave.2")
                    }
                    .glassProminentButton().disabled(busy)
                    .help("Diarize this recording and assign names")
                } else {
                    Button { detectSpeakers(item) } label: {
                        Label("Detect speakers", systemImage: "person.2.wave.2")
                    }
                    .glassButton().disabled(busy)
                    .help("Re-run diarization + speaker ID on this recording's audio")
                }
            }

            Spacer()

            // Summarize → background Claude → staged for review. Hidden while a summary is
            // already staged (the review pane handles it) or currently running.
            if item.summaryReadyURL == nil {
                let pending = isPending(item)
                let summarizeLabel = Label(item.isProcessed ? "Re-summarize" : "Summarize", systemImage: "sparkles")
                if item.hasUnnamedSpeakers && audioAvailable(item) {
                    Button { pendingProcessItem = item } label: { summarizeLabel }
                        .glassButton().disabled(busy || pending)
                } else {
                    Button { summarize(item) } label: { summarizeLabel }
                        .glassProminentButton().disabled(busy || pending)
                }
            }
        }
    }

    /// Add a present-but-non-speaking (or forgotten) attendee to this transcript.
    private func addAttendeeButton(_ item: TranscriptItem) -> some View {
        Button { attendeeDraft = ""; addingAttendee = true } label: {
            Label("Add attendee", systemImage: "person.badge.plus")
        }
        .glassButton()
        .disabled(busy)
        .popover(isPresented: $addingAttendee) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Add an attendee").font(Theme.Typography.sheetTitle)
                Text("For someone who was present but didn't speak, or a name missed during the call. No transcript line is attributed to them.")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Name", text: $attendeeDraft)
                    .textFieldStyle(.roundedBorder).frame(width: 240)
                    .onSubmit { commitAddAttendee(item) }
                let matches = attendeeMatches(item)
                if !matches.isEmpty {
                    ForEach(matches, id: \.self) { p in
                        Button(p) { attendeeDraft = p }
                            .buttonStyle(.plain).font(Theme.Typography.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Add") { commitAddAttendee(item) }
                        .glassProminentButton()
                        .keyboardShortcut(.defaultAction)
                        .disabled(attendeeDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(Theme.Spacing.medium).frame(width: 280)
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

    // MARK: Files strip — the visible "meeting record"

    /// Transcript + linked audio + filed note as compact chips, each with size and quick
    /// reveal/open. Surfaces links the data model already carries (`meta.audio`/`meta.note`).
    @ViewBuilder private func filesStrip(_ item: TranscriptItem) -> some View {
        let l = store.links(for: item)
        HStack(spacing: Theme.Spacing.small) {
            fileChip(icon: "doc.text", label: "Transcript",
                     detail: item.url.pathExtension.uppercased(), reveal: item.url)
            if l.audioSession != nil {
                fileChip(icon: "waveform", label: "Audio",
                         detail: ByteCountFormatter.string(fromByteCount: l.audioBytes, countStyle: .file),
                         reveal: item.meta.audio.map { URL(fileURLWithPath: $0) })
            } else {
                fileChip(icon: "waveform.slash", label: "Audio", detail: "none", reveal: nil)
            }
            if let note = l.note {
                fileChip(icon: "tray.full", label: "Filed note", detail: nil, reveal: note,
                         open: { recording.notes.openInObsidian(note) })
            }
            Spacer()
        }
    }

    @ViewBuilder private func fileChip(icon: String, label: String, detail: String?,
                                       reveal: URL?, open: (() -> Void)? = nil) -> some View {
        Button {
            if let open { open() }
            else if let reveal { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
        } label: {
            HStack(spacing: Theme.Spacing.xSmall) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(label)
                if let detail { Text(detail).foregroundStyle(.secondary) }
            }
            .font(Theme.Typography.caption)
        }
        .buttonStyle(.chip)
        .disabled(open == nil && reveal == nil)
        .help(open != nil ? "Open in Obsidian" : (reveal != nil ? "Reveal in Finder" : ""))
    }

    // MARK: File-management actions (rename / refile / delete)

    private func beginRename(_ item: TranscriptItem) {
        renameDraft = item.meta.title
        fileOp = .rename(item)
    }

    private func beginRefile(_ items: [TranscriptItem]) {
        guard !items.isEmpty else { return }
        refileDraft = items.first?.meta.filing ?? ""
        fileOp = .refile(items)
    }

    private func beginDelete(_ items: [TranscriptItem]) {
        guard !items.isEmpty else { return }
        let links = items.map { store.links(for: $0) }
        deleteAudioToo = links.contains { $0.audioSession != nil }
        deleteNoteToo = links.contains { $0.note != nil }
        fileOp = .delete(items)
    }

    private func renameSheet(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Rename meeting").font(Theme.Typography.sheetTitle)
            Text("Updates the title in the transcript and renames the file (its date prefix is kept). A filed note is renamed to match.")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Title", text: $renameDraft)
                .textFieldStyle(.roundedBorder).frame(width: 340)
                .onSubmit { commitRename(item) }
            HStack {
                Spacer()
                Button("Cancel") { fileOp = nil }
                    .glassButton()
                Button("Rename") { commitRename(item) }
                    .glassProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Spacing.large).frame(width: 380)
    }

    private func commitRename(_ item: TranscriptItem) {
        let newURL = store.rename(item, to: renameDraft)
        selection = [newURL.path]
        fileOp = nil
    }

    private func refileSheet(_ items: [TranscriptItem]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(items.count > 1 ? "Refile \(items.count) meetings" : "Refile meeting")
                .font(Theme.Typography.sheetTitle)
            Text("Sets where the meeting is filed. A summary note that's already been committed is moved into the new folder.")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DestinationField(path: $refileDraft, destinations: vault.destinations,
                             firstRoot: settings.scanRoots.first ?? "Internal")
                .frame(width: 380)
            HStack {
                Spacer()
                Button("Cancel") { fileOp = nil }
                    .glassButton()
                Button("Refile") { commitRefile(items) }
                    .glassProminentButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.large).frame(width: 420)
    }

    private func commitRefile(_ items: [TranscriptItem]) {
        var lastURL: URL?
        for item in items { lastURL = store.refile(item, to: refileDraft) }
        if items.count == 1, let u = lastURL { selection = [u.path] }
        fileOp = nil
    }

    private func deleteSheet(_ items: [TranscriptItem]) -> some View {
        let links = items.map { store.links(for: $0) }
        let audioBytes = links.reduce(Int64(0)) { $0 + $1.audioBytes }
        let anyAudio = links.contains { $0.audioSession != nil }
        let anyNote = links.contains { $0.note != nil }
        return VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(items.count > 1 ? "Move \(items.count) meetings to the Trash" : "Move meeting to the Trash")
                .font(Theme.Typography.sheetTitle)
            Text("Recoverable from the Trash. The transcript is always moved; choose what else to include.")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if anyAudio {
                Toggle(isOn: $deleteAudioToo) {
                    Text("Also delete the recorded audio (\(ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file)))")
                }
            }
            if anyNote {
                Toggle(isOn: $deleteNoteToo) {
                    Text("Also delete the filed summary note\(items.count > 1 ? "s" : "")")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { fileOp = nil }
                    .glassButton()
                Button("Move to Trash", role: .destructive) { commitDelete(items) }
                    .glassProminentButton()
                    .tint(Theme.Severity.danger.color)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.large).frame(width: 420)
    }

    private func commitDelete(_ items: [TranscriptItem]) {
        store.deleteMany(items, alsoAudio: deleteAudioToo, alsoNote: deleteNoteToo)
        selection.subtract(Set(items.map(\.id)))
        fileOp = nil
    }

    // MARK: Helpers

    private static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
