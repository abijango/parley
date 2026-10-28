import SwiftUI
import AppKit

// Sidebar list support for the shell (`HistoryView`): empty states, the per-row
// context menu and queue actions, processing-queue reordering, the queue banner, and
// row status indicators.

extension HistoryView {

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
            .padding(Theme.Spacing.small + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(radius: Theme.Radius.small)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.bottom, Theme.Spacing.xSmall)
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
            .cardSurface(radius: Theme.Radius.small)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.bottom, Theme.Spacing.xSmall)
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
}
