import SwiftUI
import AppKit

// File-management for meetings: rename / refile / delete / combine / merge — the
// `begin…` entry points, their sheets, and the commits.

extension HistoryView {

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
}
