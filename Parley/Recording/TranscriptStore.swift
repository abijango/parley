import Foundation
import Combine
import AppKit

/// One transcript in the app-owned vault folder, surfaced to the History tab.
struct TranscriptItem: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    var meta: TranscriptMeta
    var isProcessed: Bool
    /// The transcript still has generic, unnamed speaker labels ("Speaker N" / "Me" /
    /// "Remote") — i.e. speakers haven't been assigned yet. Drives the History badge.
    var hasUnnamedSpeakers: Bool = false
    /// A background summary has finished and is staged for review (the `.staging` file).
    /// Non-nil ⇒ show the review pane in History. Cleared on commit/discard.
    var summaryReadyURL: URL? = nil

    static func == (lhs: TranscriptItem, rhs: TranscriptItem) -> Bool {
        lhs.url == rhs.url
            && lhs.isProcessed == rhs.isProcessed
            && lhs.hasUnnamedSpeakers == rhs.hasUnnamedSpeakers
            && lhs.summaryReadyURL == rhs.summaryReadyURL
            && lhs.meta.status == rhs.meta.status
            && lhs.meta.note == rhs.meta.note
            && lhs.meta.title == rhs.meta.title
            && lhs.meta.attendees == rhs.meta.attendees
    }
}

/// Scans the app-owned `Unprocessed/` and `Processed/` folders, parses each
/// transcript's frontmatter, and publishes a newest-first list for the History tab.
@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var items: [TranscriptItem] = []

    private var scanTask: Task<Void, Never>?

    /// Rescans both folders and republishes `items`.
    ///
    /// Callers observe the result via the `@Published` property; `refresh()` returns
    /// immediately and does not block the caller. In-flight scans are cancelled and
    /// superseded so bursty vnode events cannot publish out of order.
    func refresh() {
        scanTask?.cancel()
        let vaultURL = AppSettings.shared.vaultURL
        AppPaths.ensureVaultFolders(vault: vaultURL)
        let unprocessed = AppPaths.unprocessedURL(vault: vaultURL)
        let processed = AppPaths.processedURL(vault: vaultURL)
        let staging = AppPaths.stagingURL(vault: vaultURL)
        scanTask = Task { [weak self] in
            let found = await Task.detached {
                Self.buildSnapshot(unprocessed: unprocessed, processed: processed, staging: staging)
            }.value
            guard !Task.isCancelled, let self else { return }
            if found != items { items = found }
        }
    }

    // MARK: Live folder watching

    private var watchers: [DispatchSourceFileSystemObject] = []
    private var refreshTask: Task<Void, Never>?
    private var didStartWatching = false

    /// Keeps the History list in sync with the filesystem via two mechanisms:
    ///   1. `DispatchSource` vnode watchers on `Unprocessed/` + `Processed/` — catch live,
    ///      in-app changes.
    ///   2. An app-became-active observer — catches changes made by other tools (Finder,
    ///      the skill, iCloud sync) that vnode can miss, when the user returns to the app.
    /// Idempotent. Also re-arms watchers if the folders are recreated.
    func startWatching() {
        guard !didStartWatching else { return }
        didStartWatching = true

        // (2) Rescan whenever Parley regains focus — reliable for external/Finder adds.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }

        armWatchers()
    }

    /// (1) (Re)create the vnode watchers on the two folders.
    private func armWatchers() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        AppPaths.ensureVaultFolders()
        AppPaths.ensureDirectory(AppPaths.stagingURL)   // so we can watch it for staged summaries
        for url in [AppPaths.unprocessedURL, AppPaths.processedURL, AppPaths.stagingURL] {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else {
                AppLog.log("History: couldn't watch \(url.lastPathComponent)", category: "history")
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                AppLog.log("History: folder change detected", category: "history")
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
        AppLog.log("History: watching \(watchers.count) folder(s) + app-active refresh — \(AppPaths.unprocessedURL.path)", category: "history")
    }

    func stopWatching() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        refreshTask?.cancel()
    }

    /// Debounced refresh — folder events can arrive in bursts (e.g. a move writes both
    /// directories); coalesce them into one rescan.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Moves a transcript into `Processed/` and stamps its frontmatter.
    @discardableResult
    func moveToProcessed(_ item: TranscriptItem, notePath: String) -> URL {
        let fm = FileManager.default
        let dest = uniqueDestination(for: item.url.lastPathComponent, in: AppPaths.processedURL)
        do {
            AppPaths.ensureVaultFolders()
            if item.url != dest {
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try fm.moveItem(at: item.url, to: dest)
            }
            TranscriptWriter.updateFrontmatter(at: dest) { meta in
                meta.status = "processed"
                meta.note = notePath
            }
        } catch {
            AppLog.log("moveToProcessed failed: \(error.localizedDescription)", category: "history")
        }
        refresh()
        return dest
    }

    /// Writes a standalone manual note (final, no AI) into `Processed/` and returns its URL.
    @discardableResult
    func save(manualBody: String, meta: TranscriptMeta) -> URL {
        AppPaths.ensureVaultFolders()
        let folder = AppPaths.processedURL
        let filename = "\(fileStamp(meta.date)) - \(TranscriptWriter.sanitize(meta.title.isEmpty ? "Manual note" : meta.title)).md"
        let url = uniqueDestination(for: filename, in: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try manualBody.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            AppLog.log("save manual note failed: \(error.localizedDescription)", category: "history")
        }
        refresh()
        return url
    }

    /// Combines several transcripts into one cohesive note (newest-first lists are
    /// reordered chronologically), so a call that got split across recordings —
    /// e.g. a crash mid-meeting, or an auto-stop/restart — can be re-summarized as a
    /// single coherent transcript. Unions attendees, keeps each part's own timeline
    /// under a `### Part N` header, and writes a fresh `unprocessed` note. Audio links
    /// are intentionally dropped (a combined note spans multiple sessions, so a single
    /// `audio:` would mislead "Detect speakers"); the originals keep theirs. Returns
    /// the new transcript's URL, or nil on failure.
    @discardableResult
    func combine(_ items: [TranscriptItem], title rawTitle: String, trashOriginals: Bool) -> URL? {
        let ordered = items.sorted {
            $0.meta.date != $1.meta.date
                ? $0.meta.date < $1.meta.date
                : $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        guard ordered.count >= 2 else { return nil }

        let date = ordered[0].meta.date
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ordered[0].meta.title
            : rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        // Union attendees case-insensitively, preserving first-seen order.
        var attendees: [String] = []
        for it in ordered {
            for a in it.meta.attendees
            where !attendees.contains(where: { $0.caseInsensitiveCompare(a) == .orderedSame }) {
                attendees.append(a)
            }
        }
        let filing = ordered.compactMap {
            let f = $0.meta.filing.trimmingCharacters(in: .whitespaces); return f.isEmpty ? nil : f
        }.first ?? ""

        let parts: [TranscriptWriter.CombinePart] = ordered.map { it in
            let text = (try? String(contentsOf: it.url, encoding: .utf8)) ?? ""
            let (notes, transcript) = TranscriptWriter.extractBodySections(text: text)
            return .init(title: it.meta.title, date: it.meta.date,
                         manualNotes: notes, transcript: transcript)
        }

        let meta = TranscriptMeta(title: title, date: date, attendees: attendees,
                                  filing: filing, status: "unprocessed",
                                  note: nil, audio: nil, type: "recording")
        let body = TranscriptWriter.makeCombinedBody(meta: meta, parts: parts)
        let url = uniqueDestination(for: TranscriptWriter.filename(title: title, date: date),
                                    in: AppPaths.unprocessedURL)
        do {
            AppPaths.ensureVaultFolders()
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            AppLog.log("Combine failed: \(error.localizedDescription)", category: "history")
            return nil
        }
        AppLog.log("Combined \(ordered.count) transcript(s) → \(url.lastPathComponent)", category: "history")

        // Optional cleanup: trash the originals' transcript + any staged summary, but
        // never their audio or filed notes — combining is non-destructive to recorded
        // media by default.
        if trashOriginals {
            for it in ordered {
                if let staged = links(for: it).staging { MeetingFiles.trash(staged) }
                MeetingFiles.trash(it.url)
            }
        }
        refresh()
        return url
    }

    // MARK: File management (delete / rename / refile)

    /// Resolves a meeting's linked artifacts (audio session, filed note, staged summary).
    func links(for item: TranscriptItem) -> MeetingLinks {
        MeetingFiles.links(transcript: item.url, meta: item.meta, staging: item.summaryReadyURL)
    }

    /// Trashes a meeting (recoverable, macOS Trash): always the transcript and any staged
    /// summary, plus — when the flag is set and the link resolves — its recorded audio session
    /// and filed note.
    func delete(_ item: TranscriptItem, alsoAudio: Bool, alsoNote: Bool) {
        trashArtifacts(of: item, alsoAudio: alsoAudio, alsoNote: alsoNote)
        AppLog.log("History: trashed \"\(item.meta.title)\"", category: "history")
        refresh()
    }

    /// Bulk trash — same per-item cascade as `delete`, one refresh at the end.
    func deleteMany(_ items: [TranscriptItem], alsoAudio: Bool, alsoNote: Bool) {
        guard !items.isEmpty else { return }
        for item in items { trashArtifacts(of: item, alsoAudio: alsoAudio, alsoNote: alsoNote) }
        AppLog.log("History: trashed \(items.count) meeting(s)", category: "history")
        refresh()
    }

    private func trashArtifacts(of item: TranscriptItem, alsoAudio: Bool, alsoNote: Bool) {
        let l = links(for: item)
        if alsoAudio, let session = l.audioSession { MeetingFiles.trash(session) }
        if alsoNote, let note = l.note { MeetingFiles.trash(note) }
        if let staged = l.staging { MeetingFiles.trash(staged) }
        MeetingFiles.trash(item.url)
    }

    /// Retitles a meeting: updates the `title:` frontmatter, renames the transcript file
    /// (preserving its `YYYY-MM-DD-HHMM - ` stamp prefix and extension), and — when processed —
    /// renames the filed note to match and relinks `note:`. Returns the transcript's new URL
    /// (the `id` changes, so the caller should re-select it).
    @discardableResult
    func rename(_ item: TranscriptItem, to rawTitle: String) -> URL {
        let newTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty, newTitle != item.meta.title else { return item.url }
        let fm = FileManager.default

        TranscriptWriter.updateFrontmatter(at: item.url) { $0.title = newTitle }

        // Keep the "YYYY-MM-DD-HHMM - " prefix; swap only the title portion.
        let ext = item.url.pathExtension
        let stem = item.url.deletingPathExtension().lastPathComponent
        let prefix = stem.range(of: " - ").map { String(stem[stem.startIndex..<$0.upperBound]) } ?? ""
        let newName = prefix + TranscriptWriter.sanitize(newTitle) + (ext.isEmpty ? "" : ".\(ext)")
        var transcriptURL = item.url
        let dest = uniqueDestination(for: newName, in: item.url.deletingLastPathComponent())
        if dest.standardizedFileURL != item.url.standardizedFileURL {
            do { try fm.moveItem(at: item.url, to: dest); transcriptURL = dest }
            catch { AppLog.log("rename transcript failed: \(error.localizedDescription)", category: "history") }
        }

        // Rename the filed note (leave its contents untouched to avoid reshaping the user's
        // Obsidian frontmatter) and relink the transcript's `note:` path.
        if let notePath = item.meta.note, !notePath.isEmpty {
            let noteURL = URL(fileURLWithPath: notePath)
            if fm.fileExists(atPath: noteURL.path) {
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
                let noteName = "\(df.string(from: item.meta.date)) - \(TranscriptWriter.sanitize(newTitle)).md"
                let noteDest = uniqueDestination(for: noteName, in: noteURL.deletingLastPathComponent())
                if noteDest.standardizedFileURL != noteURL.standardizedFileURL {
                    do {
                        try fm.moveItem(at: noteURL, to: noteDest)
                        TranscriptWriter.updateFrontmatter(at: transcriptURL) { $0.note = noteDest.path }
                    } catch { AppLog.log("rename note failed: \(error.localizedDescription)", category: "history") }
                }
            }
        }
        refresh()
        return transcriptURL
    }

    /// Refiles a meeting: records the new `filing:` destination, and — when processed with a
    /// filed note — moves that note into `<vault>/<destination>/` and relinks `note:`. The
    /// transcript itself stays put (only the polished note is user-filed). Returns its URL.
    @discardableResult
    func refile(_ item: TranscriptItem, to destination: String) -> URL {
        let dest = destination.trimmingCharacters(in: .whitespaces)
        guard dest != item.meta.filing || item.meta.note != nil else { return item.url }
        TranscriptWriter.updateFrontmatter(at: item.url) { $0.filing = dest }

        if let notePath = item.meta.note, !notePath.isEmpty {
            let fm = FileManager.default
            let noteURL = URL(fileURLWithPath: notePath)
            if fm.fileExists(atPath: noteURL.path) {
                let vault = AppSettings.shared.vaultURL
                let folder = dest.isEmpty ? vault : vault.appendingPathComponent(dest, isDirectory: true)
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let noteDest = uniqueDestination(for: noteURL.lastPathComponent, in: folder)
                if noteDest.standardizedFileURL != noteURL.standardizedFileURL {
                    do {
                        try fm.moveItem(at: noteURL, to: noteDest)
                        TranscriptWriter.updateFrontmatter(at: item.url) { $0.note = noteDest.path }
                    } catch { AppLog.log("refile note failed: \(error.localizedDescription)", category: "history") }
                }
            }
        }
        refresh()
        return item.url
    }

    // MARK: Scanning

    /// Directory walk + per-file parse, safe to run off the main actor.
    nonisolated private static func buildSnapshot(
        unprocessed: URL, processed: URL, staging: URL
    ) -> [TranscriptItem] {
        var found: [TranscriptItem] = []
        found.append(contentsOf: scan(unprocessed, processed: false, staging: staging))
        found.append(contentsOf: scan(processed, processed: true, staging: staging))
        found.sort {
            $0.meta.date != $1.meta.date
                ? $0.meta.date > $1.meta.date
                : $0.url.lastPathComponent > $1.url.lastPathComponent
        }
        return found
    }

    nonisolated private static func scan(_ folder: URL, processed: Bool, staging: URL) -> [TranscriptItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [TranscriptItem] = []
        for url in entries {
            // Skip hidden files; accept transcript files (.md written by the app, and
            // .txt transcripts dropped in manually — the skill processes both).
            if url.lastPathComponent.hasPrefix(".") { continue }
            guard ["md", "txt"].contains(url.pathExtension.lowercased()) else { continue }
            let text = try? String(contentsOf: url, encoding: .utf8)
            var meta = (text.flatMap { TranscriptWriter.parseFrontmatter(text: $0) })
                ?? fallbackMeta(url, processed: processed)
            meta.date = resolvedDate(url, meta.date)
            let unnamed = text.map(Self.hasGenericSpeakerLabels) ?? false
            // A staged summary (.staging/<base>.md) means "ready for review".
            let stageURL = staging.appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + ".md")
            let summaryReady = fm.fileExists(atPath: stageURL.path) ? stageURL : nil
            result.append(TranscriptItem(url: url, meta: meta, isProcessed: processed,
                                         hasUnnamedSpeakers: unnamed, summaryReadyURL: summaryReady))
        }
        return result
    }

    /// Best-effort metadata when a file has no frontmatter: title/date from the
    /// filename, status from the folder, type "recording".
    nonisolated private static func fallbackMeta(_ url: URL, processed: Bool) -> TranscriptMeta {
        let stem = url.deletingPathExtension().lastPathComponent
        var title = stem
        var date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

        // Filenames look like "YYYY-MM-DD-HHMM - Title".
        if let dash = stem.range(of: " - ") {
            let prefix = String(stem[stem.startIndex..<dash.lowerBound])
            title = String(stem[dash.upperBound...])
            if let d = parseStampDate(prefix) { date = d }
        } else if let d = parseStampDate(String(stem.prefix(10))) {
            date = d
        }

        return TranscriptMeta(
            title: title.isEmpty ? stem : title,
            date: date, attendees: [], filing: "",
            status: processed ? "processed" : "unprocessed",
            note: nil, audio: nil, type: "recording"
        )
    }

    /// Whether a transcript body still carries generic (unassigned) speaker labels.
    static func hasGenericSpeakerLabels(_ text: String) -> Bool {
        text.contains("] Speaker ") || text.contains("] Me:") || text.contains("] Remote:")
    }

    /// Re-read a transcript file and report whether it still has generic speaker labels.
    /// Used after a speaker review to decide if the note is now fully-named (and thus
    /// summary-ready). Returns true (assume unnamed) if the file can't be read.
    static func bodyHasGenericLabels(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return true }
        return hasGenericSpeakerLabels(text)
    }

    // MARK: Helpers

    private func uniqueDestination(for filename: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(filename)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var n = 2
        repeat {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = folder.appendingPathComponent(name)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: date)
    }

    /// Older transcripts stored a date-only frontmatter `date:` (parsed to midnight),
    /// which makes same-day items tie and sort arbitrarily and shows "00:00" in the
    /// list. When the parsed date has no time component, recover the real recording
    /// time from the filename stamp (`yyyy-MM-dd-HHmm`) or the file's creation date.
    nonisolated private static func resolvedDate(_ url: URL, _ metaDate: Date) -> Date {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .second], from: metaDate)
        guard (c.hour ?? 0) == 0, (c.minute ?? 0) == 0, (c.second ?? 0) == 0 else { return metaDate }

        // Try the filename stamp (recording time, minute precision).
        let stem = url.deletingPathExtension().lastPathComponent
        let prefix = stem.range(of: " - ").map { String(stem[stem.startIndex..<$0.lowerBound]) }
            ?? String(stem.prefix(15))
        if let stamped = parseStampDate(prefix) {
            let sc = cal.dateComponents([.hour, .minute], from: stamped)
            if (sc.hour ?? 0) != 0 || (sc.minute ?? 0) != 0 { return stamped }
        }
        // Fall back to the file's creation date (full precision).
        if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate {
            return created
        }
        return metaDate
    }

    nonisolated private static func parseStampDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd-HHmm", "yyyy-MM-dd-HHmmss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
