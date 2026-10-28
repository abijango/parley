import SwiftUI
import AppKit

/// The main window's three-pane shell and history browser. The sidebar
/// (`MeetingSidebar.swift`) lists every transcript in the app-owned vault folder,
/// grouped by date; the center shows the live screen, People, or the selected note
/// with its per-item actions (open in Obsidian, reveal audio, process/re-process).
struct HistoryView: View {
    @EnvironmentObject var recording: RecordingController
    @EnvironmentObject var shell: MainShellModel
    @AppStorage("parley.sidebarCollapsed") var sidebarCollapsed = false
    @AppStorage(NotesPanel<EmptyView>.visibleKey) var notesPanelVisible = true
    @AppStorage("parley.noteDetailsExpanded") var noteDetailsExpanded = true
    @AppStorage("parley.noteSummaryExpanded") var noteSummaryExpanded = true
    /// The staged summary's full review (preview / edit / checker) has been opened
    /// into the center, replacing the transcript. Reset when the selection changes.
    @State var summaryInCenter = false
    @EnvironmentObject var store: TranscriptStore
    @EnvironmentObject var vault: VaultDirectory
    @ObservedObject var settings = AppSettings.shared
    /// Observed directly so live job state (pending/failed) republishes the view.
    @ObservedObject var summaryService = RecordingController.shared.summaryService
    /// NOT observed: this view is the always-mounted window shell, and `offline`
    /// publishes fine-grained progress ticks during a speaker pass. Job-state changes
    /// re-render via `.onReceive(offline.$jobs)`; progress only re-renders the small
    /// `PipelineStageBar` subviews that observe it themselves.
    let offline = RecordingController.shared.offlineService
    @State var offlineJobsRevision = 0
    @StateObject var rowIndex = HistoryRowIndex()
    @State var selection = Set<TranscriptItem.ID>()
    @State var filter: HistoryFilter = .all
    /// Search query, matched against title / attendees / filing (and bodies when enabled).
    @State var searchQuery = ""
    @State var searchInContents = false
    // File-management sheet (one at a time, enum-driven to avoid stacking modifiers).
    @State var fileOp: FileOp?
    @State var renameDraft = ""
    @State var refileDraft = ""
    @State var deleteAudioToo = true
    @State var deleteNoteToo = true
    @State var combineDraft = ""
    @State var combineTrashOriginals = false
    // Inferred-affiliation confirm banner (Slice D).
    // Tracks names whose toggle has been turned OFF; empty means all are confirmed (default ON).
    @State var deselectedAffiliations: Set<String> = []
    // The URL of the staged note for which the current inferred set was computed,
    // so we can reset deselections when the user navigates to a different note.
    @State var inferredAffiliationStagedURL: URL?
    @State var stagedRawMarkdown: String?
    /// When multiple backends are staged, which one the review pane is showing.
    @State var reviewStagedURL: URL?
    /// Opens the side-by-side model comparison window for this transcript.
    @State var compareItem: TranscriptItem?

    /// The active file-management sheet and its target(s).
    enum FileOp: Identifiable {
        case rename(TranscriptItem)
        case refile([TranscriptItem])
        case delete([TranscriptItem])
        case combine([TranscriptItem])
        /// New MergeService-backed "Combine with…" for a single base item.
        case merge(TranscriptItem)
        var id: String {
            switch self {
            case .rename(let i): return "rename:\(i.id)"
            case .refile(let items): return "refile:\(items.map(\.id).joined(separator: "|"))"
            case .delete(let items): return "delete:\(items.map(\.id).joined(separator: "|"))"
            case .combine(let items): return "combine:\(items.map(\.id).joined(separator: "|"))"
            case .merge(let i): return "merge:\(i.id)"
            }
        }
    }

    enum HistoryFilter: String, CaseIterable, Identifiable {
        case all = "All", processing = "Processing", needsYou = "Needs you", done = "Done"
        var id: String { rawValue }
    }

    /// The fused pipeline stage for an item (reads the precomputed row index).
    func stage(_ item: TranscriptItem) -> PipelineStage {
        rowIndex.stage(for: item)
    }

    var filteredItems: [TranscriptItem] {
        var base: [TranscriptItem]
        switch filter {
        case .all: base = store.items
        case .processing: base = processingOrderedItems
        case .needsYou: base = store.items.filter { rowIndex.row(for: $0).needsYou }
        case .done: base = store.items.filter { rowIndex.stage(for: $0) == .processed }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { matchesSearch($0, query: q) }
    }

    /// Items in the Processing tab: offline queue order, then summary queue order.
    var processingOrderedItems: [TranscriptItem] {
        var seen = Set<String>()
        var result: [TranscriptItem] = []
        func appendSession(_ sessionID: String?) {
            guard let sessionID else { return }
            guard let item = store.items.first(where: {
                MeetingFiles.sessionDir(forAudioPath: $0.meta.audio)?.lastPathComponent == sessionID
            }) else { return }
            guard !seen.contains(item.id) else { return }
            seen.insert(item.id)
            result.append(item)
        }
        appendSession(offline.runningID)
        offline.orderedQueuedIDs.forEach { appendSession($0) }
        if let running = summaryService.runningID,
           let item = store.items.first(where: { $0.id == running }), !seen.contains(item.id) {
            seen.insert(item.id)
            result.append(item)
        }
        for qid in summaryService.queuedIDs {
            guard let item = store.items.first(where: { $0.id == qid }), !seen.contains(item.id) else { continue }
            seen.insert(item.id)
            result.append(item)
        }
        return result
    }

    /// Title / attendees / filing match synchronously; body match uses the async index.
    func matchesSearch(_ item: TranscriptItem, query q: String) -> Bool {
        if item.meta.title.lowercased().contains(q) { return true }
        if item.meta.filing.lowercased().contains(q) { return true }
        if item.meta.attendees.contains(where: { $0.lowercased().contains(q) }) { return true }
        if searchInContents { return rowIndex.contentMatchIDs.contains(item.id) }
        return false
    }
    /// Count of items needing the user (badge on the "Needs you" tab).
    var needsYouCount: Int { store.items.filter { rowIndex.row(for: $0).needsYou }.count }
    /// Item awaiting the "speakers not assigned" confirmation before summarizing.
    @State var pendingProcessItem: TranscriptItem?
    /// Editable destination for the summary currently under review (seeded from meta.filing).
    @State var reviewDestination = ""
    @State var headerTitleDraft = ""
    @State var headerFilingDraft = ""
    @State var headerEditItemID: String?
    @State var attachmentError: String?
    @State var isDescribingAttachments = false

    var body: some View {
        // A plain HStack (not NavigationSplitView — see MainWindowView): sidebar,
        // hairline, center. The sidebar hides entirely when collapsed.
        HStack(spacing: 0) {
            if !sidebarCollapsed {
                shellSidebar
                    .transition(.move(edge: .leading))
                Divider()
            }
            shellCenter
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            store.refresh()
            store.startWatching()
            rowIndex.observe(store: store, offline: offline, summary: summaryService)
            seedReviewDestination()
            applyHistoryFocus()
        }
        .onChange(of: recording.historyFocusPath) { applyHistoryFocus() }
        .onReceive(offline.$jobs) { _ in offlineJobsRevision &+= 1 }
        .onChange(of: searchQuery) { updateContentSearch() }
        .onChange(of: searchInContents) { updateContentSearch() }
        .onChange(of: selection) {
            seedReviewDestination()
            summaryInCenter = false
            if !selection.isEmpty { shell.route = .notes }
        }
        .onChange(of: selectedItem?.summaryReadyURL) { seedReviewDestination() }
        // The "Detect speakers" review sheet is hosted at the window root
        // (MainWindowView), not here, so it survives switching tabs/notes mid-review.
        .alert(
            "Speakers aren't all named",
            isPresented: Binding(get: { pendingProcessItem != nil },
                                 set: { if !$0 { pendingProcessItem = nil } }),
            presenting: pendingProcessItem
        ) { item in
            Button("Detect speakers first") {
                // The review sheet is hosted on the window. Presenting it in this
                // alert's dismiss turn drops it, so yield once first.
                let target = item
                Task { @MainActor in detectSpeakers(target) }
            }
            Button("Summarize anyway") { summarize(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This transcript still has unnamed speakers. Detect & assign first for higher-quality attribution, or summarize now — Parley will include attendee and speaker hints.")
        }
        .sheet(item: $fileOp) { op in
            switch op {
            case .rename(let item): renameSheet(item)
            case .refile(let items): refileSheet(items)
            case .delete(let items): deleteSheet(items)
            case .combine(let items): combineSheet(items)
            case .merge(let item): mergeSheetView(item)
            }
        }
        .sheet(item: $compareItem) { item in
            SummaryCompareView(item: item) { _ in
                store.refresh()
            }
        }
    }

    func applyHistoryFocus() {
        guard let path = recording.historyFocusPath else { return }
        selection = [path]
        shell.route = .notes
        recording.historyFocusPath = nil
    }

    /// Seed the editable review destination from the selected item's filing.
    func seedReviewDestination() {
        if let item = selectedItem, item.summaryReadyURL != nil {
            reviewDestination = item.meta.filing
        }
    }

    func isV2Review(item _: TranscriptItem, staged: URL) -> Bool {
        // Markup UI is only for Summary v2 staging files. Do not treat classic
        // dual-staging as v2 merely because Settings → Pipeline is set to v2.
        staged.lastPathComponent.hasSuffix(".v2.md")
    }

    func classicMetricsLine(for item: TranscriptItem) -> (text: String, help: String)? {
        guard let run = SummaryRunStore().runs(forTranscriptID: item.url.path)
            .first(where: { $0.pipeline == .classic }) else { return nil }
        return SummaryMetricsFormat.compactLine(metrics: run.writerMetrics)
    }

    func updateContentSearch() {
        rowIndex.updateContentSearch(
            query: searchQuery,
            searchInContents: searchInContents,
            items: store.items
        )
    }

    /// Queue a background Claude summary. An explicit press is user-initiated — it
    /// bypasses the auto-off + bulk-confirm gates (but still respects a usage-limit pause).
    func summarize(_ item: TranscriptItem) {
        recording.summaryService.enqueueIfPolicyAllows(item, trigger: .userInitiated)
    }

    func describeAttachments(for item: TranscriptItem) {
        isDescribingAttachments = true
        switch summaryService.describeAttachments(for: item) {
        case .success(let digest):
            attachmentError = nil
            let documentURL = SummaryService.prospectiveNoteURL(
                item: item, destination: item.meta.filing, vault: settings.vaultURL)
            if let staged = item.summaryReadyURL,
               var body = try? String(contentsOf: staged, encoding: .utf8) {
                body = AttachmentVisionService.mergeDiagrams(
                    into: body, visionDigest: digest, attachments: item.meta.attachments,
                    documentURL: documentURL, vault: settings.vaultURL)
                try? body.write(to: staged, atomically: true, encoding: .utf8)
                store.refresh()
            }
        case .failure(let reason):
            attachmentError = reason
        }
        isDescribingAttachments = false
    }

    func isPending(_ item: TranscriptItem) -> Bool {
        if case .pending = summaryService.state(for: item) { return true }
        return false
    }

    func summaryHasFailed(_ item: TranscriptItem) -> Bool {
        if case .failed = summaryService.state(for: item) { return true }
        return false
    }

    // MARK: Helpers

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = .autoupdatingCurrent
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = .autoupdatingCurrent
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func dateString(_ date: Date) -> String { dateFormatter.string(from: date) }

    static func timeString(_ date: Date) -> String { timeFormatter.string(from: date) }

}
