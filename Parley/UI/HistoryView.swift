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
    /// Add-attendee popover (for someone present who didn't speak / was forgotten).
    @State var addingAttendee = false
    @State var attendeeDraft = ""
    /// Editable destination for the summary currently under review (seeded from meta.filing).
    @State var reviewDestination = ""
    @State var headerTitleDraft = ""
    @State var headerFilingDraft = ""
    @State var headerEditItemID: String?

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

    // MARK: List

    @ViewBuilder var listEmptyState: some View {
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

    /// Per-row context menu — operates on the right-clicked item (selecting it first if it
    /// isn't part of the current selection).
    @ViewBuilder func rowMenu(_ item: TranscriptItem) -> some View {
        let targets = selection.contains(item.id) && selection.count > 1 ? selectedItems : [item]
        if targets.count == 1 {
            queueActions(item)
            Button("Rename…") { beginRename(item) }
            Button("Combine with…") { beginMerge(item) }
        }
        Button("Refile…") { beginRefile(targets) }
        if targets.count > 1 {
            Button("Combine \(targets.count) into one…") { beginCombine(targets) }
        }
        Divider()
        if let note = item.meta.note, !note.isEmpty {
            Button("Open note in Obsidian") {
                Obsidian.open(URL(fileURLWithPath: note))
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

    /// Stage-aware queue actions for a single item (top of the row menu).
    @ViewBuilder func queueActions(_ item: TranscriptItem) -> some View {
        switch stage(item) {
        case .queuedForSummary:
            Button("Summarize now") { summaryService.prioritize(item) }
            if summaryService.isHeld(id: item.id) {
                Button("Release hold") { summaryService.releaseHold(id: item.id) }
            } else {
                Button("Hold") { summaryService.hold(id: item.id) }
            }
            Button("Cancel summary") { summaryService.cancelQueued(item) }
            Divider()
        case .heldForSummary:
            Button("Release hold") { summaryService.releaseHold(id: item.id) }
            Button("Cancel summary") { summaryService.cancelQueued(item) }
            Divider()
        case .queuedForSpeakers, .pausedForSpeakers, .heldForSpeakers, .waitingForTranscription:
            if let sid = sessionID(for: item) {
                Button("Transcribe Now") { offline.transcribeNow(id: sid) }
                Button("Do next") { offline.prioritize(id: sid) }
                if offline.isHeld(id: sid) {
                    Button("Release hold") { offline.releaseHold(id: sid) }
                } else {
                    Button("Hold") { offline.hold(id: sid) }
                }
                Button("Cancel speaker pass") { offline.cancelQueued(id: sid) }
            }
            Divider()
        case .failed(.summary), .failed(.claudeUsageLimited):
            Button("Retry summary") { summarize(item) }
            Divider()
        case .failed(.speakerDetection):
            if audioAvailable(item) { Button("Retry speaker detection") {
                recording.reprocessSpeakers(
                    forAudioPath: item.meta.audio, transcript: item.url,
                    attendees: item.meta.attendees.joined(separator: ", "),
                    title: item.meta.title, filing: item.meta.filing)
            }; Divider() }
        default:
            EmptyView()
        }
    }

    func sessionID(for item: TranscriptItem) -> String? {
        MeetingFiles.sessionDir(forAudioPath: item.meta.audio)?.lastPathComponent
    }

    /// Drag-to-reorder only in the Processing tab. SwiftUI takes a nonisolated closure,
    /// but it calls it on the main thread.
    var moveAction: ((IndexSet, Int) -> Void)? {
        guard filter == .processing else { return nil }
        return { source, destination in
            MainActor.assumeIsolated { moveProcessingItem(from: source, to: destination) }
        }
    }

    func moveProcessingItem(from source: IndexSet, to destination: Int) {
        guard filter == .processing else { return }
        let items = processingOrderedItems
        guard let from = source.first, from < items.count else { return }
        let item = items[from]
        if let sid = sessionID(for: item), offline.queuedIDs.contains(sid) {
            let queued = Set(offline.queuedIDs)
            guard let dest = ProcessingQueueOrder.destinationIndex(
                movingFrom: from, to: destination, in: items,
                belongsToQueue: { row in
                    sessionID(for: row).map(queued.contains) == true
                }) else { return }
            offline.move(id: sid, to: dest)
            return
        }
        guard summaryService.queuedIDs.contains(item.id) else { return }
        let queued = Set(summaryService.queuedIDs)
        guard let dest = ProcessingQueueOrder.destinationIndex(
            movingFrom: from, to: destination, in: items,
            belongsToQueue: { queued.contains($0.id) }) else { return }
        summaryService.move(id: item.id, to: dest)
    }

    /// Banner above the list: the bulk-confirm prompt (highest priority) or a
    /// throttle-paused notice with Resume. Shown in any tab so it's never missed.
    @ViewBuilder var queueBanner: some View {
        if let bulk = summaryService.pendingBulkConfirm {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text("Summarize \(bulk.items.count) notes?")
                    .font(Theme.Typography.controlLabel)
                Text("Several recordings are ready. Run them through Claude now, or leave them for later.")
                    .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Summarize all") { summaryService.confirmPendingBulk() }
                        .glassProminentButton().controlSize(.small)
                    Button("Not now") { summaryService.dismissPendingBulk() }
                        .glassButton().controlSize(.small)
                }
            }
            .padding(Theme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.accent.opacity(Theme.Opacity.tintFill))
            Divider()
        } else if case .paused(let reason, let resumeAt) = summaryService.throttle {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "pause.circle.fill").foregroundStyle(Theme.Severity.warning.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(reason == .usageLimit ? "Summaries paused — usage/rate limit" : "Summaries paused")
                        .font(Theme.Typography.caption)
                    if let resumeAt {
                        Text("Resumes \(Self.timeString(resumeAt))")
                            .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Resume now") { summaryService.resumeQueue() }
                    .buttonStyle(.chip)
            }
            .padding(.horizontal, Theme.Spacing.medium).padding(.vertical, Theme.Spacing.small)
            .background(.quaternary.opacity(Theme.Opacity.surface))
            Divider()
        }
    }

    /// Warning/attention icons in the row; in-flight states render as the mini stage
    /// bar underline instead (see `row`).
    @ViewBuilder func rowIndicator(_ item: TranscriptItem) -> some View {
        switch rowIndex.row(for: item).rowIndicator {
        case .needsSpeakerNames:
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(Theme.Severity.warning.color).font(Theme.Typography.caption)
                .help("Speakers not assigned — needs review")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Severity.warning.color).font(Theme.Typography.caption)
                .help("Needs attention")
        case nil:
            EmptyView()
        }
    }

    /// Status chip mapped from the fused pipeline stage.
    func statusBadge(_ item: TranscriptItem) -> some View {
        let model = rowIndex.row(for: item)
        return StatusBadge(model.statusLabel, severity: model.statusSeverity)
    }

    // MARK: Detail

    @ViewBuilder var detail: some View {
        if selection.count > 1 {
            bulkPanel
        } else if let item = selectedItem {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    detailHeader(item)
                    Divider()
                    if summaryInCenter, let staged = item.summaryReadyURL {
                        summaryReviewCenter(item, staged: staged)
                    } else {
                        TranscriptPreviewView(url: item.url, reloadToken: recording.transcriptRevision)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if notesPanelVisible {
                    notePanel(item)
                        .transition(.move(edge: .trailing))
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
    var bulkPanel: some View {
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
                Button { beginCombine(items) } label: { Label("Combine \(items.count)…", systemImage: "arrow.triangle.merge") }
                    .glassButton()
                    .help("Merge these into one transcript for a single, cohesive summary.")
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
    @ViewBuilder func summaryStatusBar(_ item: TranscriptItem) -> some View {
        switch summaryService.state(for: item) {
        case .pending:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView().controlSize(.small).scaleEffect(0.7, anchor: .center)
                Text(StageBarModel.summarizeStatusLabel())
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
    /// rendered note, with Commit / Discard / Regenerate. When multiple backends have
    /// staged output, a picker lets you flip between them for quality comparison.
    @ViewBuilder func reviewPane(_ item: TranscriptItem, staged: URL) -> some View {
        let inferred = InferredAffiliationParser.parseInferred(markdown: stagedRawMarkdown ?? "")
        let reviewURL = reviewStagedURL ?? staged
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Summary ready — review, set where it's filed, then commit to your vault.")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                if let metrics = classicMetricsLine(for: item) {
                    Text(metrics.text)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .help(metrics.help)
                }
                if item.stagedSummaries.count > 1 {
                    Picker("Compare", selection: Binding(
                        get: { reviewStagedURL ?? staged },
                        set: { reviewStagedURL = $0; stagedRawMarkdown = nil }
                    )) {
                        ForEach(item.stagedSummaries, id: \.url) { entry in
                            Text(entry.backend?.displayName ?? "Legacy").tag(entry.url)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
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
            TranscriptPreviewView(
                url: reviewURL,
                reloadToken: recording.transcriptRevision,
                rawMarkdown: $stagedRawMarkdown
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            if !inferred.isEmpty {
                inferredAffiliationBanner(inferred, staged: reviewURL)
                Divider()
            }
            HStack(spacing: Theme.Spacing.medium) {
                Button(role: .destructive) { summaryService.discard(item) } label: {
                    Label("Discard", systemImage: "trash")
                }
                .glassButton()
                Button { summaryService.regenerate(item) } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .glassButton()
                .help("Re-runs the active backend in Settings (\(settings.summaryBackend.displayName)); other backends' staging files are kept.")
                Button { compareItem = item } label: {
                    Label("Compare models\u{2026}", systemImage: "rectangle.split.3x1")
                }
                .glassButton()
                Spacer()
                Button {
                    let confirmed = inferred.filter { !deselectedAffiliations.contains($0.name) }
                    recording.confirmInferredAffiliations(confirmed)
                    commitAndSelectNext(item, stagedURL: reviewURL)
                } label: {
                    Label("Commit & File", systemImage: "tray.and.arrow.down")
                }
                .glassProminentButton()
            }
            .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.small)
            .chromeSurface()
        }
        .onChange(of: staged) {
            deselectedAffiliations.removeAll()
            inferredAffiliationStagedURL = staged
            stagedRawMarkdown = nil
            reviewStagedURL = nil
        }
    }

    /// Banner listing inferred affiliations, each with a default-ON toggle.
    @ViewBuilder func inferredAffiliationBanner(
        _ items: [InferredAffiliation],
        staged: URL
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Claude inferred \(items.count == 1 ? "1 affiliation" : "\(items.count) affiliations") from the transcript — confirm to save to your rolodex:")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
            ForEach(items, id: \.name) { affiliation in
                let isOn = Binding<Bool>(
                    get: { !deselectedAffiliations.contains(affiliation.name) },
                    set: { checked in
                        if checked {
                            deselectedAffiliations.remove(affiliation.name)
                        } else {
                            deselectedAffiliations.insert(affiliation.name)
                        }
                    }
                )
                Toggle(isOn: isOn) {
                    Text("\(affiliation.name) -> \(affiliation.company)")
                        .font(Theme.Typography.caption)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.small)
        .chromeSurface()
    }

    var selectedItems: [TranscriptItem] {
        store.items.filter { selection.contains($0.id) }
    }
    /// The single selected item, or nil when zero or many are selected.
    var selectedItem: TranscriptItem? {
        selection.count == 1 ? selectedItems.first : nil
    }

    func commitAndSelectNext(_ item: TranscriptItem, stagedURL: URL) {
        let nextID = Self.selectionAfterRemoving(item.id, from: filteredItems.map(\.id))
        guard summaryService.commit(
            item,
            destination: reviewDestination,
            stagedURL: stagedURL
        ) != nil else { return }
        selection = nextID.map { [$0] } ?? []
    }

    /// Keeps keyboard-style list navigation stable when an action removes the current row:
    /// select the row now occupying its position, or the preceding row at the end.
    static func selectionAfterRemoving(
        _ removedID: TranscriptItem.ID,
        from orderedIDs: [TranscriptItem.ID]
    ) -> TranscriptItem.ID? {
        guard let index = orderedIDs.firstIndex(of: removedID), orderedIDs.count > 1 else {
            return nil
        }
        return orderedIDs[index == orderedIDs.index(before: orderedIDs.endIndex) ? index - 1 : index + 1]
    }

    func detailHeader(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    TextField("Meeting title", text: headerTitleBinding(for: item))
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.screenTitle)
                        .onSubmit { persistHeaderTitle(item) }
                        .disabled(summaryService.hasPendingWork(item))
                        .help(summaryService.hasPendingWork(item)
                              ? "Renaming is available once the summary finishes" : "Click to rename")
                    metadataLine(item)
                }
                Spacer()
                statusBadge(item)
            }
            HistorySpeakerStrip(item: item, audioAvailable: audioAvailable(item)) {
                if item.summaryReadyURL != nil { summaryService.regenerate(item) } else { summarize(item) }
            }
            actionRow(item)
            // Live pipeline status for this note: the full segmented stage bar
            // (detecting / queued / summarizing / failed), hidden when idle.
            PipelineStageBar(item: item, style: .full)
        }
        .padding(.horizontal, Theme.Spacing.xLarge)
        .padding(.vertical, Theme.Spacing.large)
        .onAppear { seedHeaderFields(item) }
        .onChange(of: item.id) { seedHeaderFields(item) }
    }

    func seedHeaderFields(_ item: TranscriptItem) {
        headerEditItemID = item.id
        headerTitleDraft = item.meta.title
        headerFilingDraft = item.meta.filing
    }

    func headerTitleBinding(for item: TranscriptItem) -> Binding<String> {
        Binding(
            get: { headerEditItemID == item.id ? headerTitleDraft : item.meta.title },
            set: { headerTitleDraft = $0 }
        )
    }

    func headerFilingBinding(for item: TranscriptItem) -> Binding<String> {
        Binding(
            get: { headerEditItemID == item.id ? headerFilingDraft : item.meta.filing },
            set: { newValue in
                headerFilingDraft = newValue
                let url = store.refile(item, to: newValue)
                selection = [url.path]
            }
        )
    }

    func persistHeaderTitle(_ item: TranscriptItem) {
        let trimmed = headerTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.meta.title,
              !summaryService.hasPendingWork(item) else { return }
        let url = store.rename(item, to: trimmed)
        selection = [url.path]
    }

    /// Editable attendee list for a filed/processed call. Writes straight through to the
    /// transcript's frontmatter + body header via `setAttendees`, so a polluted list (e.g.
    /// speaker-split "Rosen"/"Adam" duplicates) can be cleaned without opening the file.
    /// Persisted immediately on every add/remove — there is no separate "Save".
    @ViewBuilder func attendeesEditor(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text("Attendees").font(Theme.Typography.fieldLabel).foregroundStyle(.secondary)
            TokenField(tokens: attendeesBinding(for: item),
                       completions: vault.people,
                       placeholder: "Add attendees",
                       onCreateNew: { name in
                           recording.setAttendees(on: item.url, to: item.meta.attendees + [name])
                       })
            if !item.meta.attendees.isEmpty {
                Button("Clear all attendees") {
                    // A bulk reset to retype the list — not a claim that nobody spoke.
                    recording.setAttendees(on: item.url, to: [], unassignRemovedSpeakers: false)
                }
                    .buttonStyle(.chip)
                    .help("Remove every attendee from this meeting")
            }
        }
    }

    /// Reads the item's current attendees; every mutation persists through `setAttendees`,
    /// which refreshes the store so the detail re-renders from the freshly-written note.
    func attendeesBinding(for item: TranscriptItem) -> Binding<[String]> {
        Binding(
            get: { item.meta.attendees },
            set: { recording.setAttendees(on: item.url, to: $0) }
        )
    }

    @State var attachmentError: String?
    @State var isDescribingAttachments = false

    @ViewBuilder func historyAttachmentsEditor(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            MeetingAttachmentsView(
                attachments: item.meta.attachments,
                vaultURL: settings.vaultURL,
                onPaste: {
                    if let err = recording.pasteAttachment(on: item.url) { attachmentError = err }
                },
                onPickFiles: { recording.pickAndAddAttachments(on: item.url) },
                onRemove: { recording.removeAttachment(id: $0, on: item.url) },
                onCaptionChange: { id, caption in
                    recording.updateAttachmentCaption(id: id, caption: caption, on: item.url)
                }
            )
            if item.isProcessed {
                Text("Add screenshots here, then Re-summarize to include them in the filed note.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            if !item.meta.attachments.isEmpty,
               settings.attachmentUnderstanding == .vision,
               item.summaryReadyURL != nil {
                Button {
                    describeAttachments(for: item)
                } label: {
                    Label(isDescribingAttachments ? "Describing attachments…" : "Describe attachments",
                          systemImage: "eye")
                }
                .buttonStyle(.chip)
                .disabled(isDescribingAttachments)
            }
        }
        .alert("Attachment", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK", role: .cancel) { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
    }

    func metadataLine(_ item: TranscriptItem) -> some View {
        Text(Self.dateString(item.meta.date))
            .font(Theme.Typography.caption).foregroundStyle(.secondary)
    }

    func actionRow(_ item: TranscriptItem) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            if let notePath = item.meta.note, !notePath.isEmpty {
                Button {
                    Obsidian.open(URL(fileURLWithPath: notePath))
                } label: {
                    Label("Open in Obsidian", systemImage: "arrow.up.right.square")
                }
                .glassButton()
            }

            if audioAvailable(item) {
                if item.hasUnnamedSpeakers {
                    Button { detectSpeakers(item) } label: {
                        Label("Detect speakers", systemImage: "person.2.wave.2")
                    }
                    .glassProminentButton().disabled(isProcessingOffline(item))
                    .help("Diarize this recording and assign names")
                } else {
                    Button { detectSpeakers(item) } label: {
                        Label("Detect speakers", systemImage: "person.2.wave.2")
                    }
                    .glassButton().disabled(isProcessingOffline(item))
                    .help("Re-run diarization + speaker ID on this recording's audio")
                }
            }

            moreMenu(item)

            Spacer()

            // Summarize → background Claude → staged for review. Hidden while a summary is
            // already staged (the review pane handles it) or currently running.
            if item.summaryReadyURL == nil {
                let pending = isPending(item)
                let summarizeLabel = Label(item.isProcessed ? "Re-summarize" : "Summarize", systemImage: "sparkles")
                // A failed run is a retry. Don't route it through the unnamed-speaker
                // prompt — that prompt was what made Summarize look dead next to Retry.
                let promptForSpeakers = item.hasUnnamedSpeakers && audioAvailable(item) && !summaryHasFailed(item)
                if item.hasUnnamedSpeakers && audioAvailable(item) {
                    Button {
                        if promptForSpeakers { pendingProcessItem = item } else { summarize(item) }
                    } label: { summarizeLabel }
                        .glassButton().disabled(busy || pending)
                } else {
                    Button { summarize(item) } label: { summarizeLabel }
                        .glassProminentButton().disabled(busy || pending)
                }
            }
        }
    }

    /// Less-used per-meeting actions, folded into one menu so the row fits beside the
    /// notes panel. (Attendees are added from the panel's Details section.)
    func moreMenu(_ item: TranscriptItem) -> some View {
        Menu {
            Button("Combine with\u{2026}") { beginMerge(item) }
            Button("Compare models\u{2026}") { compareItem = item }
            Divider()
            if let audioPath = item.meta.audio, !audioPath.isEmpty {
                Button("Reveal audio in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: audioPath)])
                }
            }
            Button("Reveal transcript in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Divider()
            Button("Rename\u{2026}") { beginRename(item) }
            Button("Delete\u{2026}", role: .destructive) { beginDelete([item]) }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .glassButton()
        .fixedSize()
        .help("Combine, compare, reveal, rename, or delete")
    }

    /// Add a present-but-non-speaking (or forgotten) attendee to this transcript.
    func addAttendeeButton(_ item: TranscriptItem) -> some View {
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
                    .textFieldStyle(.parley).frame(width: 240)
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

    func attendeeMatches(_ item: TranscriptItem) -> [String] {
        let d = attendeeDraft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !d.isEmpty else { return [] }
        let have = Set(item.meta.attendees.map { $0.lowercased() })
        return vault.people.filter { $0.lowercased().contains(d) && !have.contains($0.lowercased()) }
            .prefix(5).map { $0 }
    }

    func commitAddAttendee(_ item: TranscriptItem) {
        let name = attendeeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        recording.addAttendeeToTranscript(item.url, name: name)
        addingAttendee = false
        attendeeDraft = ""
    }

    /// Note generation is in flight — disable the action buttons.
    var busy: Bool {
        recording.summaryService.runningID != nil
    }

    /// This item's recording already has an offline pass queued or running (so its
    /// "Detect speakers" button is disabled to avoid a duplicate enqueue).
    func isProcessingOffline(_ item: TranscriptItem) -> Bool {
        let s = offline.jobState(forAudioPath: item.meta.audio)
        return s == .queued || s == .running
    }

    func audioAvailable(_ item: TranscriptItem) -> Bool {
        guard let a = item.meta.audio, !a.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: a)
    }

    func detectSpeakers(_ item: TranscriptItem) {
        // Unnamed speakers already in the cache are named in the strip; otherwise re-run.
        recording.assignSpeakers(
            forAudioPath: item.meta.audio, transcript: item.url,
            attendees: item.meta.attendees.joined(separator: ", "),
            title: item.meta.title, filing: item.meta.filing)
    }

    // MARK: Files strip — the visible "meeting record"

    /// Transcript + linked audio + filed note as compact chips, each with size and quick
    /// reveal/open. Surfaces links the data model already carries (`meta.audio`/`meta.note`).
    @ViewBuilder func filesStrip(_ item: TranscriptItem) -> some View {
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
                         open: { Obsidian.open(note) })
            }
            Spacer()
        }
    }

    @ViewBuilder func fileChip(icon: String, label: String, detail: String?,
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

    func beginRename(_ item: TranscriptItem) {
        renameDraft = item.meta.title
        fileOp = .rename(item)
    }

    func beginRefile(_ items: [TranscriptItem]) {
        guard !items.isEmpty else { return }
        refileDraft = items.first?.meta.filing ?? ""
        fileOp = .refile(items)
    }

    func beginDelete(_ items: [TranscriptItem]) {
        guard !items.isEmpty else { return }
        let links = items.map { store.links(for: $0) }
        deleteAudioToo = links.contains { $0.audioSession != nil }
        deleteNoteToo = links.contains { $0.note != nil }
        fileOp = .delete(items)
    }

    func beginCombine(_ items: [TranscriptItem]) {
        guard items.count > 1 else { return }
        // Default the combined title to the earliest meeting's title.
        combineDraft = items.min { $0.meta.date < $1.meta.date }?.meta.title ?? ""
        combineTrashOriginals = false
        fileOp = .combine(items)
    }

    func beginMerge(_ item: TranscriptItem) {
        fileOp = .merge(item)
    }

    /// Present MergeSheet as a sheet body when fileOp == .merge(item).
    func mergeSheetView(_ item: TranscriptItem) -> some View {
        // All other items are candidates; sort by date so the picker is in order.
        let candidates = store.items
            .filter { $0.id != item.id }
            .sorted { $0.meta.date < $1.meta.date }
        // Pre-select the most likely sibling: adjacent item with the same trimmed
        // case-insensitive title within 5 minutes of this item's date.
        let baseTitle = item.meta.title.trimmingCharacters(in: .whitespaces).lowercased()
        let siblingWindow: TimeInterval = 5 * 60
        let preselected: Set<TranscriptItem.ID> = Set(
            candidates.filter { candidate in
                let titleMatches = candidate.meta.title
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased() == baseTitle
                let timeDelta = abs(candidate.meta.date.timeIntervalSince(item.meta.date))
                return titleMatches && timeDelta <= siblingWindow
            }.map(\.id)
        )
        return MergeSheet(
            base: item,
            candidates: candidates,
            initialSelection: preselected,
            recording: recording
        ) { resultURL in
            fileOp = nil
            guard let url = resultURL else { return }
            // Switch to All tab so the newly created unprocessed note is visible.
            if filter != .all { filter = .all }
            selection = [url.path]
        }
    }

    func renameSheet(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Rename meeting").font(Theme.Typography.sheetTitle)
            Text("Updates the title in the transcript and renames the file (its date prefix is kept). A filed note is renamed to match.")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Title", text: $renameDraft)
                .textFieldStyle(.parley).frame(width: 340)
                .onSubmit { commitRename(item) }
            HStack {
                Spacer()
                Button("Cancel") { fileOp = nil }
                    .glassButton()
                Button("Rename") { commitRename(item) }
                    .glassProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || summaryService.hasPendingWork(item))
            }
            if summaryService.hasPendingWork(item) {
                Text("A summary is being generated for this meeting. Rename it once that finishes.")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.large).frame(width: 380)
    }

    func commitRename(_ item: TranscriptItem) {
        guard !summaryService.hasPendingWork(item) else { return }
        let newURL = store.rename(item, to: renameDraft)
        selection = [newURL.path]
        fileOp = nil
    }

    func refileSheet(_ items: [TranscriptItem]) -> some View {
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

    func commitRefile(_ items: [TranscriptItem]) {
        var lastURL: URL?
        for item in items { lastURL = store.refile(item, to: refileDraft) }
        if items.count == 1, let u = lastURL { selection = [u.path] }
        fileOp = nil
    }

    func deleteSheet(_ items: [TranscriptItem]) -> some View {
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

    func commitDelete(_ items: [TranscriptItem]) {
        store.deleteMany(items, alsoAudio: deleteAudioToo, alsoNote: deleteNoteToo)
        selection.subtract(Set(items.map(\.id)))
        fileOp = nil
    }

    /// Merge several meetings into one cohesive transcript (e.g. a call that got
    /// split by a crash or an auto-stop/restart), so it can be summarized as a whole.
    func combineSheet(_ items: [TranscriptItem]) -> some View {
        let ordered = items.sorted { $0.meta.date < $1.meta.date }
        return VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Combine \(ordered.count) meetings").font(Theme.Typography.sheetTitle)
            Text("Stitches these recordings into one transcript, in time order, so a split call can be re-summarized as a single conversation. Attendees are merged; each part keeps its own timeline under a heading. A new unprocessed transcript is created.")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { idx, item in
                    HStack(spacing: Theme.Spacing.small) {
                        Text("\(idx + 1).").font(Theme.Typography.caption).foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(item.meta.title).font(Theme.Typography.caption).lineLimit(1)
                        Spacer()
                        Text(Self.dateString(item.meta.date))
                            .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Theme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(Theme.Opacity.surface), in: RoundedRectangle(cornerRadius: 6))

            TextField("Combined title", text: $combineDraft)
                .textFieldStyle(.parley)
            Toggle("Move the originals to the Trash after combining", isOn: $combineTrashOriginals)
                .help("Off keeps the originals; recorded audio and filed notes are always kept either way.")

            HStack {
                Spacer()
                Button("Cancel") { fileOp = nil }
                    .glassButton()
                Button("Combine") { commitCombine(ordered) }
                    .glassProminentButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.large).frame(width: 460)
    }

    func commitCombine(_ items: [TranscriptItem]) {
        let url = store.combine(items, title: combineDraft, trashOriginals: combineTrashOriginals)
        fileOp = nil
        guard let url else { return }
        // Surface the new note: clear the multi-selection, drop any filter that would
        // hide an unprocessed transcript, and select it.
        if filter != .all { filter = .all }   // a freshly combined note is idle/unprocessed → only under All
        selection = [url.path]
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
