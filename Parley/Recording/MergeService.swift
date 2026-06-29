import Foundation

/// Orchestrates the "call merge" feature: combines two or more drop/rejoin recording legs
/// into a single note. Supports two backends:
///
/// - `.transcriptStitch` (C1): text-only — re-times timestamps and concatenates transcripts
///   behind a reconnected-seam marker. Works even after audio deletion. Speaker labels are
///   NOT unified across the seam (noted in the UI).
///
/// - `.audioRepass` (C2): concatenates the raw audio files (with silence-padded gaps) into
///   a new session, seeds a transcript, and enqueues an offline pass for a single coherent
///   diarized note. Requires every leg's mic.caf + system.caf on disk.
///
/// The caller sorts items in any order; MergeService always sorts by meta.date ascending.
/// `backend == nil` selects C2 when every leg's audio is available; otherwise C1.
@MainActor
final class MergeService {

    // MARK: - Dependencies

    private let store: TranscriptStore
    private let vault: VaultDirectory
    private let offline: OfflineProcessingService
    private let settings = AppSettings.shared
    private let fm = FileManager.default

    // MARK: - Init

    init(store: TranscriptStore, vault: VaultDirectory, offline: OfflineProcessingService) {
        self.store = store
        self.vault = vault
        self.offline = offline
    }

    // MARK: - Public API

    /// Merge `items` (sorted by date inside this method) into a single note.
    ///
    /// - Parameters:
    ///   - items: Two or more `TranscriptItem` values to merge. Order does not matter.
    ///   - backend: Explicit backend override; `nil` means auto-select.
    /// - Returns: The URL of the combined/seed note, or `nil` on failure.
    func merge(_ items: [TranscriptItem], backend: MergeBackend?) async -> URL? {
        // Must have at least two legs.
        guard items.count >= 2 else {
            AppLog.log("merge: need >= 2 items, got \(items.count) — aborting", category: "merge")
            return nil
        }

        // Sort chronologically by date (ascending).
        let legs = items.sorted {
            $0.meta.date != $1.meta.date
                ? $0.meta.date < $1.meta.date
                : $0.url.lastPathComponent < $1.url.lastPathComponent
        }

        AppLog.log("merge: \(legs.count) leg(s) — \(legs.map { $0.meta.title }.joined(separator: ", "))", category: "merge")

        // Resolve each leg's session directory and audio file URLs.
        let legSessions = legs.map { item -> (dir: URL?, mic: URL?, system: URL?) in
            guard let dir = MeetingFiles.sessionDir(forAudioPath: item.meta.audio) else {
                return (nil, nil, nil)
            }
            let mic = dir.appendingPathComponent("mic.caf")
            let sys = dir.appendingPathComponent("system.caf")
            return (dir, mic, sys)
        }

        // Compute each leg's duration: audio file length, or fallback to last [HH:MM:SS] stamp.
        let durations: [TimeInterval] = legs.enumerated().map { idx, item in
            if let mic = legSessions[idx].mic,
               fm.fileExists(atPath: mic.path) {
                let d = SessionStore.audioDuration(mic)
                if d > 0 { return d }
            }
            // Fallback: last timestamp in the transcript body.
            let span = TranscriptCoverage.spanFromTranscriptFile(item.url).span
            return max(0, span)
        }

        // Compute silence gaps: gap[0] = 0; gap[k] = max(0, leg[k].date - (leg[k-1].date + leg[k-1].duration)).
        var gaps: [TimeInterval] = [0]
        for k in 1..<legs.count {
            let prev = legs[k - 1]
            let prevEnd = prev.meta.date.addingTimeInterval(durations[k - 1])
            let gap = max(0, legs[k].meta.date.timeIntervalSince(prevEnd))
            gaps.append(gap)
        }

        // Choose backend.
        let resolved: MergeBackend = backend ?? autoBackend(legSessions: legSessions)
        AppLog.log("merge: backend=\(resolved.rawValue)", category: "merge")

        switch resolved {
        case .transcriptStitch:
            return await stitchMerge(legs: legs, durations: durations)
        case .audioRepass:
            return await audioRepassMerge(legs: legs, legSessions: legSessions,
                                          durations: durations, gaps: gaps)
        }
    }

    // MARK: - Backend selection

    /// Auto-select: C2 iff every leg has mic.caf + system.caf on disk; else C1.
    private func autoBackend(legSessions: [(dir: URL?, mic: URL?, system: URL?)]) -> MergeBackend {
        let allAudioPresent = legSessions.allSatisfy { session in
            guard let mic = session.mic, let sys = session.system else { return false }
            return fm.fileExists(atPath: mic.path) && fm.fileExists(atPath: sys.path)
        }
        return allAudioPresent ? .audioRepass : .transcriptStitch
    }

    // MARK: - C1: Transcript stitch

    private func stitchMerge(legs: [TranscriptItem],
                              durations: [TimeInterval]) async -> URL? {
        AppLog.log("merge/stitch: reading \(legs.count) note(s)", category: "merge")

        // Read every leg's text into memory BEFORE moving any files.
        var noteTexts: [String] = []
        for leg in legs {
            guard let text = try? String(contentsOf: leg.url, encoding: .utf8) else {
                AppLog.log("merge/stitch: failed to read \(leg.url.lastPathComponent) — aborting", category: "merge")
                return nil
            }
            noteTexts.append(text)
        }

        // Stitch into one combined note.
        let combined = TranscriptStitcher.stitch(notes: noteTexts, durations: durations)

        // Determine filing folder: use leg-0's Unprocessed location.
        let leg0 = legs[0]
        let unprocessed = AppPaths.unprocessedURL
        AppPaths.ensureDirectory(unprocessed)

        // Move source .md files to Merged/ first (so the seed write doesn't collide with
        // leg-0's filename when they share the same name).
        let mergedDir = AppPaths.mergedURL
        AppPaths.ensureDirectory(mergedDir)
        for leg in legs {
            let dest = uniqueDestination(for: leg.url.lastPathComponent, in: mergedDir)
            do {
                try fm.moveItem(at: leg.url, to: dest)
                AppLog.log("merge/stitch: moved \(leg.url.lastPathComponent) → Merged/", category: "merge")
            } catch {
                AppLog.log("merge/stitch: could not move \(leg.url.lastPathComponent): \(error.localizedDescription)", category: "merge")
                // Non-fatal; continue — the combined note is still produced.
            }
        }

        // Write the combined note.
        let filename = TranscriptWriter.filename(title: leg0.meta.title, date: leg0.meta.date)
        let combinedURL = uniqueDestination(for: filename, in: unprocessed)
        do {
            try combined.write(to: combinedURL, atomically: true, encoding: .utf8)
        } catch {
            AppLog.log("merge/stitch: failed to write combined note: \(error.localizedDescription)", category: "merge")
            return nil
        }

        // Update vault: add people + ensure destination.
        let unionAttendees = unionedAttendees(legs)
        vault.addPeople(unionAttendees)
        if !leg0.meta.filing.isEmpty { vault.ensureDestination(leg0.meta.filing) }

        store.refresh()
        AppLog.log("merge/stitch: wrote \(combinedURL.lastPathComponent)", category: "merge")
        return combinedURL
    }

    // MARK: - C2: Audio re-pass

    private func audioRepassMerge(legs: [TranscriptItem],
                                   legSessions: [(dir: URL?, mic: URL?, system: URL?)],
                                   durations: [TimeInterval],
                                   gaps: [TimeInterval]) async -> URL? {
        AppLog.log("merge/repass: concatenating audio for \(legs.count) leg(s)", category: "merge")

        let leg0 = legs[0]
        let leg0Session = legSessions[0]

        // Build new merged session directory (id = "<leg0id>-merged").
        let leg0DirName = leg0Session.dir?.lastPathComponent
            ?? TranscriptWriter.fileStamp(leg0.meta.date)
        let mergedDirName = "\(leg0DirName)-merged"
        let mergedSessionDir = AppPaths.recordingsDirectory.appendingPathComponent(mergedDirName, isDirectory: true)
        AppPaths.ensureDirectory(mergedSessionDir)

        // Collect mic + system URLs in leg order.
        let micURLs = legSessions.compactMap { $0.mic }
        let sysURLs = legSessions.compactMap { $0.system }

        guard micURLs.count == legs.count, sysURLs.count == legs.count else {
            AppLog.log("merge/repass: audio URL resolution failed — aborting", category: "merge")
            return nil
        }

        // Concatenate audio off the main actor to avoid blocking the UI.
        let mergedMic = mergedSessionDir.appendingPathComponent("mic.caf")
        let mergedSys = mergedSessionDir.appendingPathComponent("system.caf")

        let micOK = await Task.detached(priority: .userInitiated) {
            AudioConcatenator.concatenate(micURLs, gaps: gaps, output: mergedMic)
        }.value

        guard micOK else {
            AppLog.log("merge/repass: mic concatenation failed — aborting (leaving source sessions intact)", category: "merge")
            try? fm.removeItem(at: mergedSessionDir)
            return nil
        }

        let sysOK = await Task.detached(priority: .userInitiated) {
            AudioConcatenator.concatenate(sysURLs, gaps: gaps, output: mergedSys)
        }.value

        guard sysOK else {
            AppLog.log("merge/repass: system concatenation failed — aborting (leaving source sessions intact)", category: "merge")
            try? fm.removeItem(at: mergedSessionDir)
            return nil
        }

        // Union attendees across all legs.
        let allAttendees = unionedAttendees(legs)
        let filing = leg0.meta.filing

        // Write a session.json manifest for the merged session.
        // Status is finalized (not active) so it doesn't surface in the crash-recovery sheet.
        let mergedManifest = SessionManifest(
            id: mergedDirName,
            title: leg0.meta.title,
            attendees: allAttendees.joined(separator: ", "),
            filing: filing,
            model: settings.model.rawValue,
            computeMode: settings.computeMode.rawValue,
            startedAt: leg0.meta.date,
            lastHeartbeat: Date(),
            status: .finalized,
            startedByDetection: false,
            callBundleID: nil,
            callDisplayName: nil,
            manualNotes: "",
            audioTracks: ["mic.caf", "system.caf"]
        )
        SessionStore.write(mergedManifest, to: mergedSessionDir)

        // Write seed transcript into Unprocessed (frontmatter + "## Transcript" header, empty body).
        let unprocessed = AppPaths.unprocessedURL
        AppPaths.ensureDirectory(unprocessed)
        let seedMeta = TranscriptMeta(
            title: leg0.meta.title,
            date: leg0.meta.date,
            attendees: allAttendees,
            filing: filing,
            status: "unprocessed",
            note: nil,
            audio: mergedMic.path,
            type: "recording"
        )
        let seedBody = makeSeedBody(meta: seedMeta)
        let seedFilename = TranscriptWriter.filename(title: leg0.meta.title, date: leg0.meta.date)

        // Move source .md files to Merged/ BEFORE writing the seed (avoids filename collision).
        let mergedDir = AppPaths.mergedURL
        AppPaths.ensureDirectory(mergedDir)
        for leg in legs {
            let dest = uniqueDestination(for: leg.url.lastPathComponent, in: mergedDir)
            do {
                try fm.moveItem(at: leg.url, to: dest)
                AppLog.log("merge/repass: moved \(leg.url.lastPathComponent) → Merged/", category: "merge")
            } catch {
                AppLog.log("merge/repass: could not move \(leg.url.lastPathComponent): \(error.localizedDescription)", category: "merge")
            }
        }

        let seedURL = uniqueDestination(for: seedFilename, in: unprocessed)
        do {
            try seedBody.write(to: seedURL, atomically: true, encoding: .utf8)
        } catch {
            AppLog.log("merge/repass: failed to write seed transcript: \(error.localizedDescription)", category: "merge")
            return nil
        }

        // Stamp offline status on the manifest BEFORE enqueuing (setOfflineStatus does
        // a read-modify-write, so the manifest must be on disk first — done above).
        SessionStore.setOfflineStatus(.pending, attempts: 0,
                                      transcriptPath: seedURL.path,
                                      presentReviewWhenDone: false,
                                      in: mergedSessionDir)

        // Enqueue the offline pass (mirrors finalize() + reprocessSpeakers mechanics).
        offline.enqueue(OfflineJob(
            sessionDir: mergedSessionDir,
            transcriptURL: seedURL,
            title: leg0.meta.title,
            attendees: allAttendees.joined(separator: ", "),
            filing: filing,
            presentReviewWhenDone: false,
            autoSummarize: settings.autoRunClaude))
        offline.runNextIfIdle()

        // Remove source session directories now that audio concat succeeded.
        for session in legSessions {
            guard let dir = session.dir else { continue }
            // Cancel any stale queued offline job first.
            offline.cancel(sessionDir: dir)
            // Prefer trash (recoverable) over hard delete — consistent with the
            // "Merged is recoverable" design intent.
            MeetingFiles.trash(dir)
            AppLog.log("merge/repass: trashed source session dir \(dir.lastPathComponent)", category: "merge")
        }

        // Update vault.
        vault.addPeople(allAttendees)
        if !filing.isEmpty { vault.ensureDestination(filing) }

        store.refresh()
        AppLog.log("merge/repass: seeded \(seedURL.lastPathComponent) — offline pass queued", category: "merge")
        return seedURL
    }

    // MARK: - Helpers

    /// Collects the case-insensitive union of attendee names from all legs,
    /// preserving first-seen order.
    private func unionedAttendees(_ legs: [TranscriptItem]) -> [String] {
        var result: [String] = []
        for leg in legs {
            for name in leg.meta.attendees {
                let lower = name.lowercased()
                if !result.contains(where: { $0.lowercased() == lower }) {
                    result.append(name)
                }
            }
        }
        return result
    }

    /// Builds a seed transcript body: frontmatter + human header + empty "## Transcript".
    /// The offline ASR pass fills in the transcript body.
    private func makeSeedBody(meta: TranscriptMeta) -> String {
        var out: [String] = []
        out.append(TranscriptWriter.renderFrontmatter(meta))

        var headerMeta = ["**Date:** \(TranscriptWriter.isoDate(meta.date))"]
        if !meta.filing.trimmingCharacters(in: .whitespaces).isEmpty {
            headerMeta.append("**Filing:** \(meta.filing)")
        }
        if !meta.attendees.isEmpty {
            headerMeta.append("**Attendees:** \(meta.attendees.joined(separator: ", "))")
        }
        out.append("# \(meta.title)")
        out.append("")
        out.append(headerMeta.joined(separator: "  \n"))
        out.append("")
        out.append("## Transcript")
        out.append("")
        return out.joined(separator: "\n") + "\n"
    }

    /// A dedup-aware destination URL: if `filename` already exists in `folder`, appends (2), (3), etc.
    private func uniqueDestination(for filename: String, in folder: URL) -> URL {
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
}
