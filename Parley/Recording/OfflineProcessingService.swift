import Foundation
import Combine

/// Runs the heavy offline pass (batch ASR re-transcription + diarization + speaker ID +
/// audio compaction) for finalized recordings — strictly serialized and ONLY while the
/// app is idle (no live recording). This is the decoupling that makes live recording
/// always-win: a freshly-stopped call is enqueued and processed when nothing is being
/// recorded, draining oldest-first until the queue empties. Each job is a self-contained
/// `OfflineJob` snapshot, so a new recording mutating the controller can never redirect a
/// running job (the data-loss bug). Persistence rides on the session manifest
/// (`offlineStatus`), so the queue is rebuilt from disk after a crash/restart.
///
/// Shaped after `SummaryService`: a `jobs` map for UI, a FIFO `queue`, a single
/// `isRunning` gate. The summary STAGE is delegated to `SummaryService` (not rebuilt).
@MainActor
final class OfflineProcessingService: ObservableObject {
    enum JobUIState: Equatable { case queued, running, failed(String) }

    /// Live per-session state, keyed by session id (= session dir name). Drives the
    /// Record-screen "processing" strip and History's per-item busy indicator.
    @Published private(set) var jobs: [String: JobUIState] = [:]

    /// Fine-grained pipeline progress, keyed by session id. Kept in a SEPARATE
    /// published property so high-rate fraction updates (≤5 Hz via JobProgressRelay)
    /// do not invalidate queue-membership observers on `jobs`.
    ///
    /// Lifecycle: populated when a job starts; cleared on success alongside `jobs`;
    /// frozen (not cleared) on failure so the UI can paint the failed segment red.
    /// Cleared again at re-enqueue and in `cancelQueued(id:)`.
    @Published private(set) var progress: [String: JobProgress] = [:]

    /// Session id of the currently-executing job. Set in `run(_:)`, cleared in
    /// `finishAndPump()`. Nil when idle or when re-deferred due to a new recording.
    private(set) var runningJobID: String?

    private var queue: [OfflineJob] = []
    private var isRunning = false

    private let models: ModelManager
    private let voiceprints: VoiceprintStore
    private let store: TranscriptStore
    private let vault: VaultDirectory
    private let summaryService: SummaryService
    private let settings = AppSettings.shared

    /// Injected by the controller so the worker never holds it: "is it safe to run now?"
    /// (true only when no recording is active). The pump and the runner both gate on this.
    var isIdle: () -> Bool = { true }
    /// Injected: hand a finished review (History "Detect speakers") to the controller,
    /// which hosts the assign-speakers sheet.
    var presentReview: (RecordingController.SpeakerReview) -> Void = { _ in }

    private static let maxAttempts = 3

    init(models: ModelManager, voiceprints: VoiceprintStore,
         store: TranscriptStore, vault: VaultDirectory, summaryService: SummaryService) {
        self.models = models
        self.voiceprints = voiceprints
        self.store = store
        self.vault = vault
        self.summaryService = summaryService
    }

    // MARK: Public surface

    /// True while any job is queued or running — used to hold off idle model-unload.
    var hasWork: Bool { isRunning || !queue.isEmpty }

    /// Progress snapshot for the job covering a transcript's audio session. Uses the same
    /// session-dir keying as `jobState(forAudioPath:)`.
    func progress(forAudioPath path: String?) -> JobProgress? {
        guard let dir = MeetingFiles.sessionDir(forAudioPath: path) else { return nil }
        return self.progress[dir.lastPathComponent]
    }

    /// Progress snapshot for the currently-running job (convenience for the Record strip).
    var runningProgress: JobProgress? {
        guard let id = runningJobID else { return nil }
        return progress[id]
    }

    /// Number of jobs waiting to run (not counting the currently-running job).
    var queuedCount: Int { queue.count }

    /// UI state for the job covering a transcript's audio session (nil = none).
    func jobState(forAudioPath path: String?) -> JobUIState? {
        guard let dir = MeetingFiles.sessionDir(forAudioPath: path) else { return nil }
        return jobs[dir.lastPathComponent]
    }

    /// Add a job (dedup by session id) and mark the manifest `.pending`. Does NOT pump —
    /// callers invoke `runNextIfIdle()` once they're ready (so a batch enqueue pumps once).
    /// Any frozen failure progress for this id is cleared so a re-enqueue starts fresh.
    func enqueue(_ job: OfflineJob) {
        guard jobs[job.id] == nil, !queue.contains(where: { $0.id == job.id }) else { return }
        // Clear any frozen failure progress from a previous attempt so the bar resets.
        progress[job.id] = nil
        SessionStore.setOfflineStatus(.pending, transcriptPath: job.transcriptURL.path,
                                      presentReviewWhenDone: job.presentReviewWhenDone, in: job.sessionDir)
        jobs[job.id] = .queued
        queue.append(job)
    }

    /// Rebuild the queue from disk at launch: every finalized session still `.pending`/
    /// `.running` (crashed mid-pass). Re-running is safe (idempotent + coverage-guarded).
    func enqueuePendingFromDisk() {
        for (dir, m) in SessionStore.pendingOfflineSessions() {
            guard let job = OfflineJob(dir: dir, manifest: m, autoSummarize: settings.autoRunClaude) else { continue }
            enqueue(job)
        }
        if !queue.isEmpty {
            AppLog.log("Offline queue: \(queue.count) pending session(s) discovered at launch", category: "offline")
        }
        runNextIfIdle()
    }

    /// Drop a queued job (e.g. its audio was deleted when a summary was filed). A job
    /// already running is left to finish; it'll no-op gracefully if its audio is gone.
    func cancel(sessionDir: URL) {
        let id = sessionDir.lastPathComponent
        queue.removeAll { $0.id == id }
        if jobs[id] == .queued { jobs[id] = nil }
    }

    /// Start the next job IFF idle and not already running. Safe to call from any idle
    /// re-entry point — it no-ops while recording, so the queue simply waits.
    func runNextIfIdle() {
        guard !isRunning, !queue.isEmpty, isIdle() else { return }
        isRunning = true
        let job = queue.removeFirst()
        jobs[job.id] = .running
        runningJobID = job.id
        Task { await self.run(job) }
    }

    // MARK: Worker

    private func run(_ job: OfflineJob) async {
        // A recording may have started between the pump and this Task — re-defer.
        guard isIdle() else {
            queue.insert(job, at: 0)
            jobs[job.id] = .queued
            runningJobID = nil
            isRunning = false
            return
        }
        // Audio gone (e.g. filed + deleted) → permanent failure, surfaced in History.
        // Freeze progress at its last value (the UI paints that stage's segment red).
        guard FileManager.default.fileExists(atPath: job.micArchiveURL.path) else {
            SessionStore.setOfflineStatus(.failed, in: job.sessionDir)
            jobs[job.id] = .failed("Audio for this recording is no longer available.")
            AppLog.log("Offline job \(job.id): audio missing — marked failed", category: "offline")
            finishAndPump()
            return
        }
        // Attempt accounting + crashed-job cap.
        let prior = SessionStore.read(job.sessionDir)?.offlineAttempts ?? 0
        if prior >= Self.maxAttempts {
            SessionStore.setOfflineStatus(.failed, in: job.sessionDir)
            jobs[job.id] = .failed("Speaker detection failed repeatedly.")
            AppLog.log("Offline job \(job.id): exceeded \(Self.maxAttempts) attempts — marked failed", category: "offline")
            finishAndPump()
            return
        }
        SessionStore.setOfflineStatus(.running, attempts: prior + 1, in: job.sessionDir)
        jobs[job.id] = .running
        AppLog.log("Offline job started: \(job.id) (attempt \(prior + 1))", category: "offline")

        // Create a relay that publishes fraction updates directly into `progress`.
        // The relay is Sendable and lock-guarded; it's safe to capture in the detached
        // compact task below without any additional synchronization.
        let jobID = job.id
        let relay = JobProgressRelay(jobID: jobID) { [weak self] id, snap in
            self?.progress[id] = snap
        }
        // Seed the mix stage so the UI shows something immediately.
        relay.set(stage: .mix, fraction: nil, sublabel: nil)
        progress[jobID] = JobProgress(stage: .mix, fraction: nil, sublabel: nil, startedAt: Date())

        // Mid-call resume writes mic.2.caf / system.2.caf; concat legs so offline
        // diarization covers the full meeting, not just the pre-resume segment.
        let archives = await Self.resolveArchives(for: job)

        // Transient engine bound to THIS job's audio; collect auto-identified names.
        var identified: [String] = []
        let eng = makeOfflineEngine(for: job, archives: archives) { name in
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty, !identified.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) else { return }
            identified.append(n)
        }

        // Wire the relay into the engine BEFORE runOfflinePass(); cleared after.
        // Stage transitions are driven by engine events (mixStarted → mix, mixDone →
        // transcribeAndDiarize, attributeStarted → attribute) so the bar tracks the real
        // work, not an estimate. compact is service-driven (below).
        eng.onOfflineProgress = { event in relay.report(event) }
        _ = await eng.runOfflinePass()
        eng.onOfflineProgress = nil  // prevent leaking a reference past this job

        // GUARDED rewrite: never let a thin offline pass shrink a fuller transcript.
        let segs = eng.finalTimeline()
        let audioDuration = SessionStore.audioDuration(archives.mic)
        let mergedAttendees = Self.merge(job.attendees, with: identified)
        if TranscriptCoverage.isSafeReplacement(offline: segs, existingFile: job.transcriptURL,
                                                audioDuration: audioDuration) {
            TranscriptWriter.rewriteTranscriptFile(at: job.transcriptURL, segments: segs,
                                                   title: job.title, filing: job.filing, attendees: mergedAttendees)
            AppLog.log("Offline job \(job.id): rewrote transcript \(job.transcriptURL.lastPathComponent)", category: "offline")
        } else {
            // Keep the existing (longer) transcript, but still record any newly
            // auto-identified attendees in its frontmatter (non-destructive).
            if !identified.isEmpty {
                TranscriptWriter.updateFrontmatter(at: job.transcriptURL) { m in
                    for n in identified where !m.attendees.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) {
                        m.attendees.append(n)
                    }
                }
            }
            // Diagnostic numbers so rejection log lines are actionable (seconds covered,
            // % of recording, segment count vs existing line count).
            let offlineSpan = TranscriptCoverage.span(segs)
            let (existingSpan, existingLines) = TranscriptCoverage.spanFromTranscriptFile(job.transcriptURL)
            let reference = max(audioDuration, existingSpan)
            let pct = reference > 0 ? Int((offlineSpan / reference * 100).rounded()) : 0
            AppLog.log("Offline job \(job.id): kept existing transcript — offline span \(Int(offlineSpan))s of \(Int(reference))s reference (\(pct)%), \(segs.count) offline segments vs \(existingLines) existing lines", category: "offline")

            // Fallback attribution: when diarization succeeded but the ASR coverage gate
            // rejected the rewrite, apply the diarized turns directly to the kept body.
            // This is the fix for the incident where 888 lines were all labeled "Remote:"
            // because the live pipeline used a single mixed stream — diarization had 2
            // speakers at 0.90/0.96 confidence but only the frontmatter got them.
            let turns = eng.diarizedTurns()
            if !turns.isEmpty,
               let fileText = try? String(contentsOf: job.transcriptURL, encoding: .utf8) {
                let (rewritten, changedLines) = TranscriptFallbackAttribution.relabel(
                    body: fileText,
                    turns: turns,
                    resolvedName: { eng.resolvedName(for: $0) }
                )
                if changedLines > 0 {
                    try? rewritten.write(to: job.transcriptURL, atomically: true, encoding: .utf8)
                    AppLog.log("Offline job \(job.id): fallback attribution — relabeled \(changedLines) lines from diarized turns", category: "offline")
                }
            }
        }
        vault.addPeople(TranscriptWriter.splitAttendees(mergedAttendees))

        // Compaction is always the correct, finalized session (AudioCompactor also
        // independently refuses any `.active` session). The relay is Sendable, so
        // capturing it in the detached task is safe — set() uses the same lock+Task-hop
        // as report() and can be called from any thread.
        relay.set(stage: .compact, fraction: nil, sublabel: nil)
        let dir = job.sessionDir
        await Task.detached(priority: .utility) {
            AudioCompactor.compactSession(dir) { f in relay.set(stage: .compact, fraction: f, sublabel: nil) }
        }.value

        SessionStore.setOfflineStatus(.done, in: job.sessionDir)

        // Speaker review (History on-demand) or auto-summary chaining.
        let speakers = eng.speakerSummaries()

        // Persist a review cache so the user can later name these speakers from History
        // INSTANTLY — no re-running this whole pass. Keeps each speaker's summary, sample
        // offsets, and centroid (for voiceprint enrolment); relabeling is then a text edit.
        if !speakers.isEmpty {
            let centroids = eng.centroidsByID()
            let cache = SpeakerCache(
                embeddingModelID: eng.embeddingModelId,
                mixedCafName: job.mixedURL.lastPathComponent,
                speakers: speakers.map { s in
                    SpeakerCache.Speaker(id: s.id, resolvedName: s.resolvedName,
                                         talkSeconds: s.talkSeconds, sampleStart: s.sampleStart,
                                         sampleEnd: s.sampleEnd, firstLine: s.firstLine,
                                         centroid: centroids[s.id] ?? [])
                })
            cache.write(to: job.sessionDir)
        }

        if job.presentReviewWhenDone, !speakers.isEmpty {
            presentReview(RecordingController.SpeakerReview(
                speakers: speakers, mixedCaf: job.mixedURL, engine: eng,
                transcriptURL: job.transcriptURL, title: job.title,
                filing: job.filing, attendees: mergedAttendees, autoSummarize: job.autoSummarize))
        } else {
            // Only auto-summarize a fully-attributed transcript: every speaker resolved
            // AND the names actually landed in the body. If the coverage guard kept a
            // shorter existing transcript (body still has generic Me/Remote/Speaker N
            // labels), leave it as "needs speakers" rather than summarizing mislabeled
            // text. Routed through the policy so a bulk wave asks for one confirmation.
            let hasUnnamed = speakers.contains { $0.resolvedName == nil }
            let bodyAttributed = !TranscriptStore.bodyHasGenericLabels(at: job.transcriptURL)
            if (speakers.isEmpty || !hasUnnamed), bodyAttributed {
                store.refresh()
                if let item = transcriptItem(for: job.transcriptURL) {
                    summaryService.enqueueIfPolicyAllows(item, trigger: .offlinePassCompleted)
                }
            } else {
                AppLog.log("Offline job \(job.id): summary not enqueued — hasUnnamed=\(hasUnnamed) bodyAttributed=\(bodyAttributed)", category: "offline")
            }
        }

        // Success: clear both the job state and its progress (no frozen red segment).
        jobs[job.id] = nil
        progress[job.id] = nil
        store.refresh()
        finishAndPump()
    }

    private func finishAndPump() {
        isRunning = false
        runningJobID = nil
        runNextIfIdle()
    }

    // MARK: Helpers

    /// Mic / system / mixed paths for one offline pass. Multi-leg sessions use
    /// concatenated `*.full.caf` archives so coverage spans the whole recording.
    struct ResolvedArchives: Sendable {
        let mic: URL
        let system: URL
        let mixed: URL
    }

    /// Resolve archives for offline: single-leg uses the job's standard paths; multi-leg
    /// (resume mid-call) concatenates `mic.caf`+`mic.2.caf`… into `mic.full.caf` (and same
    /// for system), then offline rebuilds `mixed.caf` from those full tracks.
    nonisolated static func resolveArchives(for job: OfflineJob) async -> ResolvedArchives {
        let dir = job.sessionDir
        let micLegs = MeetingFiles.audioSegmentURLs(in: dir, base: "mic")
        let sysLegs = MeetingFiles.audioSegmentURLs(in: dir, base: "system")
        guard micLegs.count > 1 else {
            return ResolvedArchives(mic: job.micArchiveURL, system: job.systemArchiveURL, mixed: job.mixedURL)
        }

        // Pair as many legs as both tracks share (asymmetric rare; take the min).
        let n = min(micLegs.count, max(sysLegs.count, 1))
        let micUse = Array(micLegs.prefix(n))
        let sysUse: [URL] = {
            if sysLegs.count >= n { return Array(sysLegs.prefix(n)) }
            // System missing later legs: fall back to first system only + zero-fill is wrong;
            // use whatever system legs exist and pad with the last one for length match? Safer:
            // concat available system legs only; if shorter, still better than first-leg-only.
            return sysLegs.isEmpty ? [job.systemArchiveURL] : sysLegs
        }()

        let micFull = dir.appendingPathComponent("mic.full.caf")
        let sysFull = dir.appendingPathComponent("system.full.caf")
        let gapsMic = Array(repeating: TimeInterval(0), count: micUse.count)
        let gapsSys = Array(repeating: TimeInterval(0), count: sysUse.count)

        let needMic = !Self.fullArchiveIsCurrent(legs: micUse, full: micFull)
        let needSys = !Self.fullArchiveIsCurrent(legs: sysUse, full: sysFull)

        if needMic {
            let ok = await Task.detached(priority: .userInitiated) {
                AudioConcatenator.concatenate(micUse, gaps: gapsMic, output: micFull)
            }.value
            if !ok {
                AppLog.log("Offline job \(job.id): multi-leg mic concat failed — falling back to first leg", category: "offline")
                return ResolvedArchives(mic: job.micArchiveURL, system: job.systemArchiveURL, mixed: job.mixedURL)
            }
        }
        if needSys {
            let ok = await Task.detached(priority: .userInitiated) {
                AudioConcatenator.concatenate(sysUse, gaps: gapsSys, output: sysFull)
            }.value
            if !ok {
                AppLog.log("Offline job \(job.id): multi-leg system concat failed — falling back to first leg", category: "offline")
                return ResolvedArchives(mic: job.micArchiveURL, system: job.systemArchiveURL, mixed: job.mixedURL)
            }
        }

        let total = Int(SessionStore.audioDuration(micFull))
        AppLog.log("Offline job \(job.id): multi-leg archives ready — \(micUse.count) mic leg(s), \(sysUse.count) system leg(s), ~\(total)s", category: "offline")
        // Always rebuild mixed.caf from the full tracks (stale short mix is common after resume).
        return ResolvedArchives(mic: micFull, system: sysFull, mixed: job.mixedURL)
    }

    /// True when `full` already exists and its duration matches the sum of leg durations.
    nonisolated private static func fullArchiveIsCurrent(legs: [URL], full: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: full.path) else { return false }
        let sum = legs.map(SessionStore.audioDuration).reduce(0, +)
        let have = SessionStore.audioDuration(full)
        return abs(have - sum) < 1.5
    }

    private func makeOfflineEngine(for job: OfflineJob,
                                   archives: ResolvedArchives,
                                   onIdentified: @escaping (String) -> Void) -> SpeakerCapableEngine {
        let eng: SpeakerCapableEngine
        switch settings.transcriptionEngine {
        case .whisperKit:
            eng = WhisperKitSpeakerKitEngine(models: models, settings: settings, voiceprints: voiceprints,
                                             identificationThreshold: settings.identificationThreshold)
        case .fluidAudio:
            eng = FluidAudioEngine(settings: settings, voiceprints: voiceprints,
                                   identificationThreshold: settings.identificationThreshold)
        }
        eng.onSpeakerIdentified = onIdentified
        eng.mixedAudioURL = archives.mixed
        eng.micArchiveURL = archives.mic
        eng.systemArchiveURL = archives.system
        eng.forceOfflineAsr = true   // no live streaming units for a saved call
        // Clustering hint from user-accepted meeting metadata: tell the diarizer how many
        // distinct speakers to expect so it doesn't merge two people into one cluster or
        // split one person across several. Only meaningful with ≥ 2 attendees.
        let attendeeCount = TranscriptWriter.splitAttendees(job.attendees).count
        eng.speakerCountHint = attendeeCount >= 2 ? attendeeCount : nil
        return eng
    }

    private func transcriptItem(for url: URL) -> TranscriptItem? {
        store.items.first { $0.url == url }
            ?? store.items.first { $0.url.lastPathComponent == url.lastPathComponent }
    }

    /// Union a comma-joined attendee string with extra names (case-insensitive, order-preserving).
    nonisolated static func merge(_ base: String, with extra: [String]) -> String {
        var names = TranscriptWriter.splitAttendees(base)
        for n in extra where !names.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) {
            names.append(n)
        }
        return names.joined(separator: ", ")
    }
}

extension OfflineProcessingService: ProcessingQueue {
    /// Queued (not-yet-running) offline jobs in run order.
    var queuedIDs: [String] { queue.map(\.id) }

    func prioritize(id: String) {
        guard let i = queue.firstIndex(where: { $0.id == id }), i > 0 else { return }
        let e = queue.remove(at: i); queue.insert(e, at: 0)
        objectWillChange.send()
    }

    func cancelQueued(id: String) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        let job = queue.remove(at: i)
        jobs[job.id] = nil
        progress[job.id] = nil   // clear any frozen failure progress
        // Mark resolved so it isn't re-discovered at launch (no further offline wanted).
        SessionStore.setOfflineStatus(.done, in: job.sessionDir)
        objectWillChange.send()
    }
}
