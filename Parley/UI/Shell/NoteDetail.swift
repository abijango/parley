import SwiftUI
import AppKit

// The selected meeting in the center pane: the bulk panel for a multi-select, the
// note header (title, speaker strip, actions), summary status and review, attendees,
// attachments, and the files strip shown in the notes panel.

extension HistoryView {

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
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 76, height: 76)
                .background(Theme.Palette.selection, in: Circle())
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
                    PillPicker(selection: Binding(
                        get: { reviewStagedURL ?? staged },
                        set: { reviewStagedURL = $0; stagedRawMarkdown = nil }
                    ), options: item.stagedSummaries.map(\.url)) { url in
                        let entry = item.stagedSummaries.first { $0.url == url }
                        Text(entry?.backend?.displayName ?? "Legacy")
                    }
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
}
