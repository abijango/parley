import Foundation
import AVFoundation
import Combine

/// High-level recording state.
enum RecordingState: Equatable {
    case idle
    case preparing
    case recording
    case stopping
    case error(String)
}

/// Owns a recording session end-to-end: permissions, the two capture sources,
/// their ring buffers, the model, the two transcription
/// pipelines, and the merged live timeline.
@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    private init() {
        // Re-evaluate the auto-clear arming whenever a "busy" gate clears: the
        // countdown is suppressed (and cancelled) while a summary is running or the
        // speaker-review sheet is open, so when either settles we may now be free to
        // start (or restart) a full-delay countdown. `dropFirst` skips the initial
        // publish at construction; `armClearIfReady` is self-gating, so a no-op is cheap.
        summaryService.$runningID.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.armClearIfReady() }
            .store(in: &cancellables)
        $pendingSpeakerReview.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.armClearIfReady() }
            .store(in: &cancellables)
        offlineService.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAppActivity() }
            .store(in: &cancellables)
        summaryService.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAppActivity() }
            .store(in: &cancellables)
        live.$state.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAppActivity() }
            .store(in: &cancellables)
    }

    /// Live capture UI state (segments, meters, recording status).
    let live = RecordingLiveState()
    /// Per-meeting metadata (title, filing, attendees, notes, discovery).
    let meeting = MeetingSessionState()
    /// Chosen app for per-app capture (when capture mode is `.perApp`).
    @Published var selectedAppPID: pid_t?
    /// Status of the last finalize (transcript write / Claude run), for the UI.
    @Published private(set) var lastResult: String?

    /// URL of the most recently written transcript (for "Reveal in Finder").
    @Published private(set) var lastTranscriptURL: URL?
    /// Derived status for menu bar + Record badge.
    @Published private(set) var appActivity: AppActivity = .idle
    /// Seconds left in the post-idle debounce before background queues drain.
    @Published private(set) var idleDrainRemaining: Int?
    /// Silent-mic heuristic thresholds (on the 0…1 smoothed meter scale).
    private static let micSilenceFloor: Float = 0.03    // at/under this the mic is effectively silent
    private static let remoteActiveFloor: Float = 0.06  // over this the call track has real audio
    private static let silenceGrace: TimeInterval = 12   // how long the mic may stay silent before warning
    private static let meterPublishThreshold: Float = 0.02
    private static let meterInterval: TimeInterval = 0.2   // 5 Hz

    /// Permission state surfaced after launch warmup, so the UI can show a
    /// persistent "fix this" banner instead of only failing at record time.
    /// `nil` = not yet determined.
    @Published private(set) var micDenied = false
    @Published private(set) var systemAudioAvailable: Bool?

    /// Crashed sessions found at launch, offered in the Recovery sheet.
    @Published private(set) var pendingRecoveries: [RecoverableSession] = []
    /// True while a recover-by-re-transcribe is running (UI feedback).
    @Published private(set) var isRecovering = false

    /// After a FluidAudio recording stops, the discovered speakers offered for naming
    /// in the "Assign speakers" sheet (nil when there's nothing to review).
    @Published var pendingSpeakerReview: SpeakerReview?

    /// `true` when the pending review should auto-present itself (the History
    /// "Detect speakers" flow), as opposed to the live at-stop flow, which is
    /// opt-in via a footer button. Hosted at the always-mounted window root so the
    /// review survives switching tabs / notes instead of being torn down with the
    /// History view (which used to silently discard it, forcing a full re-run).
    @Published var autoPresentSpeakerReview = false

    /// Set when the user opens the "speakers ready" notification. History selects the row.
    /// The speaker sheet stays closed.
    @Published var historyFocusPath: String?

    // MARK: - Post-call batch enrichment (Slice B)

    /// Snapshot of attendees with no known company, offered to the user once
    /// after a recording stops so they can add Title/Company/LinkedIn before the
    /// rolodex entry is filed under "Other".
    struct AttendeeEnrichment: Identifiable {
        let id = UUID()
        var rows: [Row]
        /// URL of the transcript that triggered this sheet (used by the deferred
        /// summary on the non-speaker path).
        let transcriptURL: URL?
        /// Leaf of destinationPath, used as a Company placeholder hint.
        let destinationDefault: String
        /// True only on the non-speaker auto-summarize path: the summary was
        /// intentionally deferred so it runs after company data is captured.
        var runSummaryOnFinish: Bool

        struct Row: Identifiable {
            let id = UUID()
            let name: String
            var title = ""
            var company = ""
            var linkedin = ""
        }
    }

    /// Non-nil while the enrichment sheet is waiting for the user.
    @Published var pendingEnrichment: AttendeeEnrichment?
    /// True when the enrichment sheet should auto-present (set alongside
    /// pendingEnrichment; cleared by finishEnrichment).
    @Published var autoPresentEnrichment = false

    /// A pending auto-clear of the Record view back to a blank slate. Surfaced as
    /// a footer chip ("Clearing in Ns — Keep") that counts down once the
    /// post-meeting pipeline has settled; any user edit cancels it (implicit Keep).
    struct PendingClear: Equatable { var remaining: Int }   // seconds left, drives the footer chip
    @Published private(set) var pendingClear: PendingClear?
    private var clearTimer: Timer?
    private var clearToken = 0        // a new session invalidates a stale timer
    private var clearArmable = false  // true only after a live recording finishes
    private var idleDrainTimer: Timer?
    /// Captured at record start so a mid-call settings flip does not change this session.
    var sessionBatchMode = false
    private var queueDrainUnlocked = false
    private var cancellables = Set<AnyCancellable>()

    /// The post-meeting work that should defer (and later re-arm) the auto-clear
    /// countdown: an open speaker-review sheet. Summaries and offline passes no longer
    /// gate clearing — they run on background queues.
    private var clearIsBusy: Bool {
        pendingSpeakerReview != nil || pendingEnrichment != nil
    }

    /// Bumped whenever a saved transcript's body is rewritten (offline pass, speaker
    /// review, add-attendee). The History/preview pane watches this to re-read the
    /// file — the URL is unchanged on a rewrite, so it wouldn't reload otherwise.
    @Published private(set) var transcriptRevision = 0

    let fluidModels = FluidModelManager()
    let voiceprints = VoiceprintStore()
    let vault = VaultDirectory()
    let store = TranscriptStore()
    /// Drives the background summary → review → commit flow (Claude / Grok / Cursor).
    private(set) lazy var summaryService = SummaryService(store: store)
    /// Background offline pass (ASR + speaker detect + compaction) for finalized
    /// recordings — serialized and idle-gated so it never competes with live recording.
    private(set) lazy var offlineService = OfflineProcessingService(
        voiceprints: voiceprints, store: store, vault: vault, summaryService: summaryService)
    /// Merge-service: combines drop/rejoin recording legs into a single note (C1 stitch / C2 re-pass).
    lazy var mergeService = MergeService(store: store, vault: vault, offline: offlineService)
    let callDetector = CallDetector()
    let metadataResolver = MeetingMetadataResolver()
    private(set) lazy var admission = MeetingAdmission(meeting: meeting)

    private let settings = AppSettings.shared
    /// Speaker-strip voice clips (live and History).
    private let clipPlayer = SamplePlayer()

    // Capture
    private let micRing = AudioRingBuffer(capacity: 16_000 * 30)
    private let systemRing = AudioRingBuffer(capacity: 16_000 * 30)
    private var micCapture: MicCapture?
    private var systemCapture: SystemAudioCapture?
    /// Capture teardown still running from the last `stop()`. `stop()` clears the two
    /// properties above immediately, so without this handle the quit path would find
    /// nothing to wait on and let the process exit mid-flush.
    private var captureTeardown: Task<Void, Never>?
    private var sessionDirectory: URL?
    private var recordingStartDate: Date?
    private var meterTimer: Timer?
    /// Last time (wall clock) the mic / remote meters exceeded their activity floor,
    /// for the silent-mic heuristic. Nil until the meter timer starts.
    private var micLastActive: Date?
    private var remoteLastActive: Date?
    private var partialAppender: PartialTranscriptAppender?
    /// Fires after a stretch of inactivity to unload the model and reclaim RAM.
    private var idleUnloadTimer: Timer?
    /// The active session's durable manifest + its heartbeat (crash recovery).
    private var manifest: SessionManifest?
    private var heartbeatTimer: Timer?
    /// Append-only confirmed-segment journal for the active meeting.
    private var journal: SegmentJournal?
    private var segmentRelay: SegmentPublishRelay?
    private var journaledSegmentIDs = Set<UUID>()
    private var wordCountBySegmentID: [UUID: Int] = [:]
    private var lastPublishedMicLevel: Float = 0
    private var lastPublishedRemoteLevel: Float = 0
    /// True when the current recording was auto-started by call detection (so it
    /// may be auto-stopped on call end; user-started recordings are not).
    private var startedByDetection = false

    private var engine: FluidAudioEngine?

    var isRecording: Bool { live.isRecording }

    /// The session currently being recorded (nil when idle) — so the Storage
    /// manager can refuse to delete the in-progress recording's audio.
    var currentSessionID: String? { isRecording ? manifest?.id : nil }

    /// Build the transcription engine for this session from settings (gated to
    /// the next recording — no mid-session switch) and wire segment publishing +
    /// the confirmed-segment journal.
    private static func offlineBinding(
        batchMode: Bool,
        language: String,
        storedProfile: FluidAsrProfile?,
        fallbackProfile: FluidAsrProfile
    ) -> (profile: FluidAsrProfile, accurate: Bool) {
        if batchMode {
            return (BatchModePolicy.pinnedProfile(stored: storedProfile, language: language), true)
        }
        return (FluidAsrBinding.profile(stored: storedProfile, fallback: fallbackProfile), false)
    }

    private func makeEngine() -> FluidAudioEngine {
        let fluid = FluidAudioEngine(settings: settings, voiceprints: voiceprints,
                                     identificationThreshold: settings.identificationThreshold,
                                     modelManager: fluidModels)
        fluid.sessionAttendees = meeting.attendees
        fluid.sessionMeetingTitle = meeting.meetingTitle
        fluid.onSpeakerIdentified = { [weak self] name in self?.admission.addRecognized(name) }
        live.segmentStore.roster.clipAvailable = { [weak fluid] id in fluid?.liveClip(for: id) != nil }
        wireSegmentPublishing(to: fluid)
        return fluid
    }

    /// Throttle UI publishes and journal only newly-confirmed segments (skip the
    /// per-tick `confirmedTimeline()` rebuild).
    private func wireSegmentPublishing(to engine: FluidAudioEngine) {
        segmentRelay?.reset()
        segmentRelay = SegmentPublishRelay { [weak self] merged in
            guard let self else { return }
            self.live.segmentStore.apply(merged)
            self.updateLiveWordCount(from: merged)
        }
        engine.onSegmentsChanged = { [weak self] merged in
            guard let self else { return }
            let newConfirmed = merged.filter { $0.confirmed && !self.journaledSegmentIDs.contains($0.id) }
            if !newConfirmed.isEmpty {
                self.journal?.append(confirmed: newConfirmed)
                self.journaledSegmentIDs.formUnion(newConfirmed.map(\.id))
                self.appendPartialTranscript(confirmed: newConfirmed)
            }
            self.segmentRelay?.submit(merged, immediate: !newConfirmed.isEmpty)
        }
    }

    private static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func updateLiveWordCount(from merged: [Segment]) {
        var byID = wordCountBySegmentID
        var total = live.liveWordCount
        for seg in merged {
            let newCount = Self.wordCount(in: seg.text)
            if let old = byID[seg.id] {
                if old != newCount {
                    byID[seg.id] = newCount
                    total += newCount - old
                }
            } else {
                byID[seg.id] = newCount
                total += newCount
            }
        }
        let currentIDs = Set(merged.map(\.id))
        for id in byID.keys where !currentIDs.contains(id) {
            total -= byID[id] ?? 0
            byID.removeValue(forKey: id)
        }
        wordCountBySegmentID = byID
        if live.liveWordCount != total { live.liveWordCount = total }
    }

    private func resetSegmentPublishState() {
        segmentRelay?.reset()
        journaledSegmentIDs.removeAll()
        wordCountBySegmentID.removeAll()
        live.liveWordCount = 0
        live.segmentStore.reset()
    }

    private func appendPartialTranscript(confirmed: [Segment]) {
        guard let partialAppender else { return }
        let title = meeting.meetingTitle
        let date = recordingStartDate ?? Date()
        let attendees = meeting.attendees
        let destination = meeting.destinationPath
        partialAppender.append(confirmed: confirmed) {
            var header = TranscriptWriter.makeBody(
                title: title.isEmpty ? "Recovered recording" : title,
                date: date, attendees: attendees, destination: destination, segments: [])
            if !header.hasSuffix("\n") { header += "\n" }
            return header
        }
    }

    // MARK: Speaker naming / enrollment (FluidAudio engine)

    /// Name a diarized speaker: relabel their transcript lines, enroll or refine their
    /// voiceprint (so future sessions recognise them), and add them to attendees.
    func nameSpeaker(_ speakerId: String, as rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        // Cache-backed review (no live engine): enrol the voiceprint from the persisted
        // centroid and record the assignment — the transcript is relabeled on Done.
        if let review = pendingSpeakerReview, review.cache != nil {
            let previousAuto = review.cache?.speakers.first(where: { $0.id == speakerId })?.resolvedName
            if let c = review.cache?.speakers.first(where: { $0.id == speakerId })?.centroid, !c.isEmpty,
               let model = review.cache?.embeddingModelID {
                enrollVoiceprint(name: name, centroid: c, model: model, overridingAutoName: previousAuto)
            } else {
                AppLog.log("Named speaker \(speakerId) as \(name) (cache) — no centroid, labeled only", category: "record")
            }
            pendingSpeakerReview?.assignments[speakerId] = name
            pendingSpeakerReview?.attendees = OfflineProcessingService.merge(review.attendees, with: [name])
            // Persist immediately so reopening Assign Speakers shows the name.
            if var cache = pendingSpeakerReview?.cache {
                cache.applyAssignments([speakerId: name])
                pendingSpeakerReview?.cache = cache
                if let dir = review.sessionDir { cache.write(to: dir) }
            }
            return
        }

        // Prefer the review's own engine (History "Detect speakers" runs on a transient
        // engine via the offline queue); fall back to the live engine for any other path.
        guard let eng = pendingSpeakerReview?.engine ?? engine else { return }
        let model = VoiceprintStore.embeddingModel
        if let centroid = eng.setSpeakerName(speakerId, as: name) {
            let vpId = enrollVoiceprint(name: name, centroid: centroid, model: model)
            Task { [weak self] in
                guard let self, let audio = await eng.repAudioSample(for: speakerId) else { return }
                self.voiceprints.attachAudioSample(to: vpId, samples: audio)
            }
        } else {
            AppLog.log("Named speaker \(speakerId) as \(name) but not enough clean audio — labeled, not enrolled", category: "record")
        }
        // Add to the right attendee target: the review's own snapshot (queued/History
        // flow), or the live Record field when naming during a live meeting.
        if pendingSpeakerReview != nil {
            pendingSpeakerReview?.assignments[speakerId] = name
            pendingSpeakerReview?.attendees = OfflineProcessingService.merge(
                pendingSpeakerReview?.attendees ?? "", with: [name])
        } else {
            admission.addRecognized(name)
        }
    }

    /// Live strip: play the best clip heard so far for a speaker. Returns its length
    /// (0 when there's no clean clip yet).
    @discardableResult
    func playLiveClip(_ speakerId: String) -> TimeInterval {
        guard let clip = engine?.liveClip(for: speakerId), !clip.isEmpty else { return 0 }
        let length = Double(clip.count) / 16_000
        // Laptop speakers bleed into the mic, which has no echo cancellation: mute it
        // for the clip (plus a tail) so the clip isn't transcribed or diarized again.
        micCapture?.silence(for: length + 0.4)
        clipPlayer.play(samples: clip)
        return length
    }

    /// History strip: play a cached speaker's sample from the call's `mixed.caf`.
    @discardableResult
    func playCachedClip(sessionDir: URL, speakerId: String) -> TimeInterval {
        guard let cache = SpeakerCache.read(sessionDir),
              let s = cache.speakers.first(where: { $0.id == speakerId }), s.sampleEnd > s.sampleStart
        else { return 0 }
        let end = min(s.sampleEnd, s.sampleStart + FluidAudioEngine.liveClipSeconds + 2)
        clipPlayer.play(files: [sessionDir.appendingPathComponent(cache.mixedCafName)],
                        start: s.sampleStart, end: end)
        return end - s.sampleStart
    }

    func stopClip() { clipPlayer.stop() }

    /// History "same person as…" into a speaker who has no name yet: their lines take the
    /// target's `Speaker N` label and the two cache entries become one. (Into a named
    /// speaker, the strip names instead — `confirmSpeakerGuess`.)
    func mergeCachedSpeaker(on transcript: URL, speakerId: String, into target: String) {
        guard speakerId != target else { return }
        let dir = MeetingFiles.sessionDir(forAudioPath: store.items.first(where: { $0.url == transcript })?.meta.audio)
            ?? transcript.deletingLastPathComponent()
        guard var cache = SpeakerCache.read(dir),
              let body = try? String(contentsOf: transcript, encoding: .utf8) else { return }
        let before = cache
        let relabeled = SpeakerCache.merge(speakerId, into: target, in: &cache, body: body)
        guard cache != before else { return }
        if relabeled != body { try? relabeled.write(to: transcript, atomically: true, encoding: .utf8) }
        cache.write(to: dir)
        store.refresh()
        transcriptRevision += 1
        AppLog.log("Merged Speaker \(speakerId) into Speaker \(target): \(transcript.lastPathComponent)", category: "record")
    }

    /// Live "same person as…": merge one diarized speaker into another. If the target
    /// is already named, this is naming (which also refines their voiceprint).
    func mergeSpeaker(_ speakerId: String, into target: String) {
        guard let eng = pendingSpeakerReview?.engine ?? engine else { return }
        if let name = eng.resolvedName(for: eng.canonicalSpeaker(target)) {
            nameSpeaker(speakerId, as: name)
        } else {
            eng.mergeSpeaker(speakerId, into: target)
        }
    }

    /// Enrol (or refine) a voiceprint for `name` from a centroid embedding, keyed by the
    /// embedding model. Returns the voiceprint id. Shared by the live-engine and
    /// cache-backed naming paths.
    @discardableResult
    private func enrollVoiceprint(name: String, centroid: [Float], model: String,
                                  overridingAutoName: String? = nil) -> UUID {
        if let prev = overridingAutoName?.trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty,
           prev.caseInsensitiveCompare(name) != .orderedSame,
           let wrong = voiceprints.voiceprint(named: prev) {
            voiceprints.recordCorrection(printId: wrong.id, embedding: centroid)
        }
        // Match an existing print of the SAME name AND embedding model (different engines
        // use non-comparable embedding spaces, so keep them separate).
        if let existing = voiceprints.voiceprints.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.embeddingModel == model
        }) {
            voiceprints.addSample(to: existing.id, embedding: centroid)
            return existing.id
        }
        return voiceprints.enroll(name: name, embedding: centroid, model: model).id
    }

    /// Enrol `name` into the OTHER engine's embedding space from the same rep clip,
    /// so a person named under one engine is also recognised by the other. Idempotent:
    /// skips if a print for (name, targetModel) already exists. Best-effort and
    /// off-main — a failure or a missing extractor never affects the user's naming.
    // MARK: - People: coordinated rename

    /// Rename a person across both the Rolodex (VaultDirectory) and all matching
    /// voiceprints (VoiceprintStore) in a single, coordinated operation.
    ///
    /// This is the ONLY place that touches both stores on a rename. The UI must call
    /// this for name changes; never rename one store in isolation.
    ///
    /// Transcript-frontmatter propagation is out of scope (eventual consistency).
    func renamePerson(from oldName: String, to newName: String) {
        Self.renamePerson(from: oldName, to: newName, vault: vault, voiceprints: voiceprints)
    }

    /// Testable static core: takes explicit store references so tests can inject
    /// temp instances without touching RecordingController.shared.
    @MainActor
    static func renamePerson(from oldName: String, to newName: String,
                             vault: VaultDirectory, voiceprints: VoiceprintStore) {
        let old = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty, old.lowercased() != new.lowercased() else { return }

        // 1. Rename in Rolodex (no-op if contact not found).
        vault.renameContact(from: old, to: new)

        // 2. Rename every matching voiceprint (name match, case-insensitive).
        //    Voiceprints have no alias field; match on name only.
        let oldLower = old.lowercased()
        let matching = voiceprints.voiceprints.filter { $0.name.lowercased() == oldLower }
        for vp in matching {
            voiceprints.rename(vp.id, to: new)
        }
        let vpCount = matching.count
        AppLog.log("renamePerson: \"\(old)\" -> \"\(new)\" -- contact renamed; \(vpCount) voiceprint(s) renamed",
                   category: "people")
    }


    /// Append a name to the comma-separated attendees list if not already present.
    private func addAttendeeIfAbsent(_ rawName: String) {
        admission.addRecognized(rawName)
    }

    // MARK: Meeting-metadata discovery (title/attendee suggestions)

    func userEditedTitle() {
        meeting.titleWasUserEdited = true
        meeting.titleSource = "user"
    }

    /// The title accept-chip action (shown when discovery found a title after
    /// the user had already edited the field).
    func acceptDiscoveredTitle() {
        guard let title = meeting.discoveredTitle else { return }
        meeting.meetingTitle = title
        meeting.titleSource = meeting.discoveredTitleSource
        scheduleMetadataSync()
    }

    func acceptSuggestion(_ name: String) {
        admission.admitUncertain(name)
        scheduleMetadataSync()
    }

    func acceptAllSuggestions() {
        for s in meeting.suggestedAttendees where !s.accepted && !s.dismissed {
            admission.admitUncertain(s.name)
        }
        scheduleMetadataSync()
    }

    func dismissSuggestion(_ name: String) {
        admission.dismissUncertain(name)
    }

    private var didWarmup = false

    /// One-time launch warmup. Called from `AppDelegate.applicationDidFinishLaunching`
    /// so menu-bar Start and call detection do not wait on the Record tab appearing.
    func launchWarmup() {
        guard !didWarmup else { return }
        didWarmup = true
        if AppInfo.isXCTestHost {
            FluidModelManager.markCompiledLoadFinished()
            return
        }
        AppLog.log("Launch warmup — FluidAudio (Parakeet \(settings.parakeetVersion.rawValue)), \(MemoryGuard.snapshot()), logs at \(AppLog.fileURL.path)", category: "app")
        VaultMigration.runIfNeeded(vault: settings.vaultURL)
        SystemAudioCapture.cleanupLeakedAggregates()    // destroy any aggregate device a crash left behind
        FluidModelManager.recoverFromCrashedLoadIfNeeded()
        wireBackgroundQueues()    // offline + summary services gate on idle, host reviews
        preloadModel()
        scheduleIdleUnload()   // if nothing happens for a while, free the model's RAM
        startCallDetection()
        AppSettings.shared.seedWebexKnownAppIfNeeded()
        Task {
            let micGranted = await PermissionManager.requestMicrophone()          // mic prompt
            micDenied = !micGranted
            let audioOK = await Task.detached { SystemAudioCapture.primeAudioCapturePermission() }.value
            systemAudioAvailable = audioOK
            if !audioOK {
                AppLog.log("System-audio capture unavailable after prime — remote-track capture and call detection by mic-signal may not work until the audio-recording permission is granted", category: "audio")
            }
        }
        // Deferred hydration: vault/transcript scans and recovery can wait until after first paint.
        Task {
            gatherRecoveries()
            recoverOrphanedPartials()
            vault.refresh()
            store.refresh()
            offlineService.enqueuePendingFromDisk()
            summaryService.enqueuePendingFromDisk()
            armIdleDrain()
        }
    }

    /// Wire the offline + summary queues to the controller: both gate on "idle" (no
    /// live recording) so live recording always wins, and the offline queue hands any
    /// History "Detect speakers" review back to the controller to host the sheet.
    private func wireBackgroundQueues() {
        let idle: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.live.state == .idle && !self.isRecording
        }
        // Batch mode keeps the offline pass running through the next recording,
        // including the gap while that recording is still preparing. Summaries
        // still wait until the recording has ended and the idle drain has elapsed.
        let offlineIdle: () -> Bool = { [weak self] in
            guard let self else { return false }
            if self.sessionBatchMode { return true }
            return self.live.state == .idle && !self.isRecording
        }
        let summaryCanDrain: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.queueDrainUnlocked || self.settings.idleDrainSeconds <= 0
        }
        let offlineCanDrain: () -> Bool = { [weak self] in
            guard let self else { return false }
            if !BatchModePolicy.waitsForIdleDrain(batchMode: self.sessionBatchMode) { return true }
            return summaryCanDrain()
        }
        offlineService.isIdle = offlineIdle
        summaryService.isIdle = idle
        offlineService.canDrain = offlineCanDrain
        summaryService.canDrain = summaryCanDrain
        let pump: () -> Void = { [weak self] in self?.pumpBackgroundQueues() }
        offlineService.requestPump = pump
        summaryService.requestPump = pump
        offlineService.presentReview = { [weak self] review in self?.presentQueuedReview(review) }
        summaryService.onSessionAudioDeleted = { [weak self] dir in self?.offlineService.cancel(sessionDir: dir) }
    }

    /// Start or restart the idle debounce before summaries (and non-batch speaker
    /// passes) may run. Batch transcription does not use this wait: it is pumped
    /// here as soon as the audio has been queued.
    func armIdleDrain() {
        if sessionBatchMode {
            offlineService.runNextIfIdle()
        }
        cancelIdleDrainTimerOnly()
        guard live.state == .idle || (isRecording && sessionBatchMode) else { return }
        let seconds = Int(settings.idleDrainSeconds)
        if seconds <= 0 {
            queueDrainUnlocked = true
            idleDrainRemaining = nil
            pumpBackgroundQueues()
            refreshAppActivity()
            return
        }
        queueDrainUnlocked = false
        idleDrainRemaining = seconds
        refreshAppActivity()
        idleDrainTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.live.state == .idle || (self.isRecording && self.sessionBatchMode) else {
                    self.cancelIdleDrain()
                    return
                }
                guard var remaining = self.idleDrainRemaining else { return }
                remaining -= 1
                if remaining <= 0 {
                    self.queueDrainUnlocked = true
                    self.idleDrainRemaining = nil
                    self.idleDrainTimer?.invalidate()
                    self.idleDrainTimer = nil
                    self.refreshAppActivity()
                    self.pumpBackgroundQueues()
                } else {
                    self.idleDrainRemaining = remaining
                    self.refreshAppActivity()
                }
            }
        }
    }

    func cancelIdleDrain() {
        cancelIdleDrainTimerOnly()
        idleDrainRemaining = nil
        queueDrainUnlocked = false
        refreshAppActivity()
    }

    private func cancelIdleDrainTimerOnly() {
        idleDrainTimer?.invalidate()
        idleDrainTimer = nil
    }

    func pumpBackgroundQueues() {
        let idle = live.state == .idle
        let drainReady = queueDrainUnlocked || settings.idleDrainSeconds <= 0
        let batch = sessionBatchMode
        if (drainReady || !BatchModePolicy.waitsForIdleDrain(batchMode: batch)) && (idle || batch) {
            offlineService.runNextIfIdle()
        }
        guard idle, drainReady else { return }
        summaryService.runNextIfIdle()
    }

    func refreshAppActivity() {
        if live.state == .recording || live.state == .preparing || live.state == .stopping {
            appActivity = .recording
            return
        }
        if case .error = live.state {
            appActivity = .idle
            return
        }
        if let running = summaryService.runningID,
           let item = store.items.first(where: { $0.id == running })
            ?? store.items.first(where: { $0.url.path == running }) {
            appActivity = .processing(kind: .summary, detail: item.meta.title)
            return
        }
        if let running = offlineService.runningID,
           let item = store.items.first(where: { $0.meta.audio?.contains(running) == true }) {
            appActivity = .processing(kind: .speakerPass, detail: item.meta.title)
            return
        }
        if let remaining = idleDrainRemaining, remaining > 0,
           offlineService.hasWork || summaryService.hasQueuedWork {
            appActivity = .settling(remaining: remaining)
            return
        }
        if offlineService.hasWork || summaryService.hasQueuedWork {
            if let remaining = idleDrainRemaining, remaining > 0 {
                appActivity = .settling(remaining: remaining)
            } else {
                appActivity = .idle
            }
            return
        }
        appActivity = .idle
    }

    /// A History "Detect speakers" pass finished: it already rewrote the transcript and
    /// wrote `speakers.json`, which History's speaker strip reads — no sheet.
    private func presentQueuedReview(_ review: SpeakerReview) {
        store.refresh()
        transcriptRevision += 1
        AppLog.log("Speakers detected — naming in History strip (\(review.speakers.count))", category: "record")
    }

    /// Starts background call detection. This increment is detection + logging
    /// only: the callbacks log the decision the next increment will act on
    /// (auto-record / notify). No recording is started/stopped yet.
    private func startCallDetection() {
        guard settings.callDetectionEnabled else {
            AppLog.log("Call detection disabled in settings", category: "detect")
            return
        }
        metadataResolver.onUpdate = { [weak self] reading in
            guard let self else { return }
            if let title = reading.title {
                self.meeting.offerTitle(title)
                AppLog.log("Discovered title (\(title.provenance)): \(title.title)", category: "detect")
                self.scheduleMetadataSync()
            }
            self.admission.ingest(reading)
            self.scheduleMetadataSync()
        }
        callDetector.onCallStart = { [weak self] call in
            guard let self else { return }
            guard !self.isRecording else {
                AppLog.log("Call on \(call.displayName) but already recording — ignoring", category: "detect")
                return
            }
            // A call is happening — warm the model NOW on the earliest signal,
            // whether we auto-record or just notify. By the time the user taps
            // "Start" (notify path) or the auto-start fires, the model is already
            // loading/loaded, so transcription begins with little or no catch-up.
            self.cancelIdleUnload()
            if !self.settings.batchMode { self.preloadModel() }
            // New call context: reset the last call's discoveries, start fresh.
            self.meeting.resetDiscovery()
            self.admission.reset()
            self.metadataResolver.start(for: call)
            // If the app crashed mid-call and that same call is the one now live,
            // resume INTO that note rather than starting a competing new recording
            // (which would fragment one meeting across two notes and grey out the
            // recovery sheet's Resume). The recovery is removed inside resume(),
            // which auto-dismisses the recovery sheet.
            if let recovery = self.matchingLiveRecovery(for: call) {
                if self.settings.autoRecordEnabled {
                    AppLog.log("AUTO-RESUME — continuing crashed session \(recovery.id) for live call \(call.displayName)", category: "detect")
                    Task { await self.resume(recovery) }
                } else {
                    // Auto-record off: don't start anything, just surface the call.
                    // The recovery sheet is already up for a manual Resume.
                    AppLog.log("Crashed session \(recovery.id) matches live \(call.displayName); leaving Recovery sheet for manual resume", category: "detect")
                    CallNotifier.shared.notifyCallDetected(call)
                }
            } else if call.known && self.settings.autoRecordEnabled {
                AppLog.log("AUTO-RECORD starting for \(call.displayName)", category: "detect")
                self.meeting.meetingTitle = "\(call.displayName) call"   // sensible default; user can edit
                Task { await self.start(detectionInitiated: true) }
            } else {
                AppLog.log("Notifying — \(call.displayName) (known=\(call.known), autoRecord=\(self.settings.autoRecordEnabled))", category: "detect")
                CallNotifier.shared.notifyCallDetected(call)
            }
        }
        callDetector.onCallEnd = { [weak self] call in
            guard let self else { return }
            // Freeze (don't clear) discovery — suggestion chips stay usable
            // after the call for title/attendee/speaker matching.
            self.metadataResolver.enterPreviewMode()
            if self.startedByDetection && self.isRecording {
                AppLog.log("AUTO-STOP — call on \(call.displayName) ended", category: "detect")
                self.stop()
            }
        }
        callDetector.start()
    }

    func preloadModel() {
        guard !settings.batchMode else { return }
        Task { _ = await fluidModels.prepare() }
    }

    // MARK: Start / stop

    /// Updates the session mic gain mode and forwards to live capture when recording.
    func setMicInputMode(_ mode: MicInputMode) {
        live.micInputMode = mode
        micCapture?.micInputMode = mode
        AppLog.log("mic input mode → \(mode.rawValue)", category: "audio")
    }

    func start(detectionInitiated: Bool = false) async {
        guard live.state == .idle || isErrorState else { return }
        cancelIdleUnload()
        startedByDetection = detectionInitiated
        if detectionInitiated, meeting.meetingTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            meeting.meetingTitle = "Recorded call"   // fallback for the notification-Start path
        }
        sessionBatchMode = settings.batchMode
        live.state = .preparing
        // Keep the user's Regular/Room selection across Start — do not reset here.
        cancelPendingClear(); clearArmable = false   // a new recording supersedes any pending auto-clear
        resetSegmentPublishState()
        lastResult = nil
        lastTranscriptURL = nil
        meeting.manualNotes = ""
        meeting.attachments = []
        // Discovery context: a detected call already reset + started the
        // resolver in onCallStart, and its pre-record findings (title, early
        // roster) belong to this session — keep them. Only a pure manual start
        // clears leftovers from the previous meeting.
        if let call = callDetector.activeCall {
            if !metadataResolver.isPolling { metadataResolver.start(for: call) }
        } else {
            meeting.resetDiscovery()
            admission.reset()
            metadataResolver.stop()
        }
        engine = makeEngine()

        guard await PermissionManager.requestMicrophone() else {
            micDenied = true
            live.state = .error("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
            startedByDetection = false
            return
        }
        micDenied = false

        // Capture-first: start capturing immediately and load the model in
        // PARALLEL (transcription catches up when it's ready) so a detected call
        // loses no audio waiting on a cold model.

        // Per-session archive folder.
        let sessionDir = AppPaths.recordingsDirectory
            .appendingPathComponent(Self.sessionStamp(), isDirectory: true)
        AppPaths.ensureDirectory(sessionDir)
        sessionDirectory = sessionDir
        journal = SegmentJournal(url: sessionDir.appendingPathComponent("segments.jsonl"))
        partialAppender = PartialTranscriptAppender(
            url: sessionDir.appendingPathComponent("transcript.partial.md"))

        launchCapture(sessionDir: sessionDir,
                      micArchive: sessionDir.appendingPathComponent("mic.caf"),
                      systemArchive: sessionDir.appendingPathComponent("system.caf"),
                      startOffset: 0, reactivate: false)
    }

    /// Continue a crashed session into the SAME note: restore its metadata, reload
    /// the journaled segments, mark the interruption, and capture fresh audio
    /// timed after the prior recording. Finalizes into one combined transcript.
    func resume(_ session: RecoverableSession) async {
        guard live.state == .idle || isErrorState else { return }
        cancelIdleUnload()
        let m = session.manifest
        // Preserve detection origin so call-end can still auto-stop (AUTO-RESUME and
        // Recovery-sheet resume of an auto-started meeting both land here).
        startedByDetection = m.startedByDetection
        sessionBatchMode = settings.batchMode
        live.state = .preparing
        // Keep the user's Regular/Room selection across Resume — do not reset here.
        cancelPendingClear(); clearArmable = false   // a resumed recording supersedes any pending auto-clear
        meeting.meetingTitle = m.title
        meeting.attendees = m.attendees
        meeting.destinationPath = m.filing
        meeting.manualNotes = m.manualNotes
        meeting.attachments = m.attachments ?? []
        admission.restoreSuggestions(m.suggestedAttendees)
        lastResult = nil
        lastTranscriptURL = nil
        engine = makeEngine()

        guard await PermissionManager.requestMicrophone() else {
            micDenied = true
            live.state = .error("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
            return
        }
        micDenied = false

        let dir = session.dir
        sessionDirectory = dir
        let partialURL = dir.appendingPathComponent("transcript.partial.md")

        // Reload prior confirmed segments; seed them (shown + finalized) and mark
        // the gap. New audio is timed to start where the prior recording ended.
        let journalURL = dir.appendingPathComponent("segments.jsonl")
        let prior = SegmentJournal.read(journalURL)
        let offset = max(session.durationSeconds, prior.map(\.end).max() ?? 0)
        let marker = Segment(track: .me, start: offset, end: offset,
                             text: "— recording resumed after interruption —", confirmed: true)
        engine?.seed(prior + [marker])
        journaledSegmentIDs = Set(prior.map(\.id))
        journal = SegmentJournal(url: journalURL, alreadyWritten: journaledSegmentIDs)
        journal?.append(confirmed: [marker])
        journaledSegmentIDs.insert(marker.id)
        partialAppender = PartialTranscriptAppender(
            url: partialURL, alreadyWritten: journaledSegmentIDs, headerExists: true)

        // Can't append to a closed .caf → write a new audio segment in the dir.
        let idx = nextAudioIndex(in: dir)
        pendingRecoveries.removeAll { $0.id == session.id }
        AppLog.log("Resuming session \(session.id) at offset \(Int(offset))s with \(prior.count) prior segments", category: "record")
        launchCapture(sessionDir: dir,
                      micArchive: dir.appendingPathComponent("mic.\(idx).caf"),
                      systemArchive: dir.appendingPathComponent("system.\(idx).caf"),
                      startOffset: offset, reactivate: true)
    }

    /// Shared capture + pipeline launch for both a fresh start and a resume.
    /// Capture-first: begins immediately and loads the model in parallel.
    private func launchCapture(sessionDir: URL, micArchive: URL, systemArchive: URL,
                               startOffset: TimeInterval, reactivate: Bool) {
        let mic = MicCapture(ringBuffer: micRing, archiveURL: micArchive)
        mic.micInputMode = live.micInputMode
        let system = SystemAudioCapture(ringBuffer: systemRing, archiveURL: systemArchive)
        recordingStartDate = Date()
        live.recordingStarted = recordingStartDate

        do {
            try mic.start()
            try system.start(target: captureTarget())
            micCapture = mic
            systemCapture = system
            AppLog.log(
                "Capture started (model loads in parallel) — capture=\(settings.captureMode.rawValue), mic=\(live.micInputMode.rawValue), offset=\(Int(startOffset))s",
                category: "record"
            )
        } catch {
            // Off the main actor for the same reason as `stop()`: a start that failed
            // because CoreAudio is wedged would otherwise block here too. Whichever of
            // the two never came up ignores this (their `stop()` no-ops when not
            // running), and `SystemAudioCapture.start()` already self-cleans on throw.
            Task.detached {
                await mic.stop()
                await system.stop()
            }
            AppLog.log("Capture failed to start: \(error.localizedDescription)", category: "record")
            live.state = .error(error.localizedDescription)
            startedByDetection = false
            return
        }

        // Hand the capture rings to the active engine, anchored to the shared
        // timeline (0 for a fresh start, or the prior duration when resuming). The
        // engine loads its model in the background and holds audio until ready.
        // Speaker-capable engines build a clean mixed file from the archived tracks at
        // stop (for the offline diarization + play-sample + retained clips).
        if let eng = engine {
            eng.mixedAudioURL = sessionDir.appendingPathComponent("mixed.caf")
            eng.micArchiveURL = micArchive
            eng.systemArchiveURL = systemArchive
        }
        summaryService.yieldToLiveRecording()
        if sessionBatchMode {
            AppLog.log("Batch mode — capturing audio; transcription stays on the offline queue", category: "record")
            offlineService.runNextIfIdle()
        } else {
            offlineService.yieldToLiveRecording()
            cancelIdleDrain()
            engine?.start(micRing: micRing, systemRing: systemRing, startElapsed: startOffset)
        }

        startMeterTimer()
        // Session-scoped freeze detector: captures main-thread stacks if the main
        // actor wedges mid-recording (see docs/RECORDING_FREEZE_INVESTIGATION.md).
        MainActorWatchdog.shared.start()
        if reactivate { reactivateSessionManifest(dir: sessionDir) }
        else { beginSessionManifest(dir: sessionDir) }
        live.state = .recording
    }

    /// Next free audio-segment index in a session dir (resume writes mic.2.caf, …).
    private func nextAudioIndex(in dir: URL) -> Int {
        var idx = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.\(idx).caf").path) { idx += 1 }
        return idx
    }

    // MARK: Meters + crash-recovery autosave

    private func startMeterTimer() {
        micLastActive = Date(); remoteLastActive = nil; live.meters.micSeemsSilent = false
        lastPublishedMicLevel = 0; lastPublishedRemoteLevel = 0
        meterTimer = Timer.scheduledTimer(withTimeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let mic = self.micCapture?.level ?? 0
                let remote = self.systemCapture?.level ?? 0
                if abs(mic - self.lastPublishedMicLevel) > Self.meterPublishThreshold {
                    self.live.meters.micLevel = mic
                    self.lastPublishedMicLevel = mic
                }
                if abs(remote - self.lastPublishedRemoteLevel) > Self.meterPublishThreshold {
                    self.live.meters.remoteLevel = remote
                    self.lastPublishedRemoteLevel = remote
                }
                self.evaluateMicSilence(mic: mic, remote: remote)
            }
        }
    }

    /// Warn when the call track has audio but the mic has produced essentially
    /// nothing for `silenceGrace` seconds — a dead/muted mic or the wrong input
    /// device selected. Self-clearing: any real mic level resets the timer and the
    /// warning. Suppressed when the mic is outright denied (a separate banner
    /// already covers that).
    private func evaluateMicSilence(mic: Float, remote: Float) {
        let now = Date()
        if mic >= Self.micSilenceFloor { micLastActive = now }
        if remote >= Self.remoteActiveFloor { remoteLastActive = now }
        let remoteActiveRecently = remoteLastActive.map { now.timeIntervalSince($0) < 4 } ?? false
        let micSilentFor = micLastActive.map { now.timeIntervalSince($0) } ?? 0
        // Assign only on change: `@Published` doesn't dedupe.
        let silent = !micDenied && remoteActiveRecently && micSilentFor >= Self.silenceGrace
        if live.meters.micSeemsSilent != silent { live.meters.micSeemsSilent = silent }
    }

    private func stopTimers() {
        meterTimer?.invalidate(); meterTimer = nil
        if live.meters.micLevel != 0 { live.meters.micLevel = 0 }
        if live.meters.remoteLevel != 0 { live.meters.remoteLevel = 0 }
        lastPublishedMicLevel = 0; lastPublishedRemoteLevel = 0
        if live.meters.micSeemsSilent { live.meters.micSeemsSilent = false }
        micLastActive = nil; remoteLastActive = nil
    }

    /// On launch, salvage any `.partial` left by a crashed or orphaned session into
    /// the vault inbox. Two cases are handled:
    ///
    /// 1. **No manifest** — the classic partial: the app crashed before even writing
    ///    a manifest, or the manifest was deleted externally.
    /// 2. **Finalized-but-unlanded** — the app was force-quit AFTER the manifest was
    ///    stamped `.finalized` (synchronously) but BEFORE the async Task completed the
    ///    transcript write. The manifest shows `status: .finalized` with both
    ///    `offlineStatus` and `summaryStatus` nil, meaning the durable path never ran.
    ///    These sessions fall through all other recovery nets at launch.
    ///
    /// Sessions with an `.active` manifest are NOT touched here — they belong to the
    /// Recovery sheet (crash-recovery), which offers re-transcribe. Salvaging them here
    /// too would double-handle them and discard the re-transcribe option.
    private func recoverOrphanedPartials() {
        let recordings = AppPaths.recordingsDirectory
        guard let sessions = try? FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil) else { return }
        for session in sessions {
            let existingManifest = SessionStore.read(session)
            // Skip sessions whose manifest is `.active` — the Recovery sheet handles those.
            if let m = existingManifest, SessionStore.isCrashed(m) { continue }
            // Salvage: no manifest OR manifest is finalized-but-unlanded (durable Task never ran).
            let isOrphanedFinalized = existingManifest.map { SessionStore.isFinalizedButUnlanded($0) } ?? false
            guard existingManifest == nil || isOrphanedFinalized else { continue }
            let partial = session.appendingPathComponent("transcript.partial.md")
            guard FileManager.default.fileExists(atPath: partial.path) else { continue }
            do {
                let inbox = AppPaths.unprocessedURL
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                // Name the recovered note from its OWN frontmatter title (the
                // partial already carries title/date/attendees), matching a
                // normally-written transcript — not the raw session timestamp.
                let meta = TranscriptWriter.parseFrontmatter(partial)
                let title = meta?.title.isEmpty == false ? meta!.title : "Recovered recording"
                let date = meta?.date ?? Date()
                let dest = inbox.appendingPathComponent(TranscriptWriter.filename(title: title, date: date))
                if !FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.copyItem(at: partial, to: dest)
                }
                try? FileManager.default.removeItem(at: partial)
                AppLog.log("Recovered crashed transcript “\(title)” → \(dest.lastPathComponent)", category: "record")
                lastResult = "Recovered “\(title)” from an interrupted recording."
            } catch {
                AppLog.log("Partial recovery failed: \(error.localizedDescription)", category: "record")
            }
        }
    }

    func stop() {
        guard live.state == .recording else { return }
        live.state = .stopping
        live.recordingStarted = nil
        partialAppender = nil
        startedByDetection = false
        if let merged = engine?.finalTimeline() {
            segmentRelay?.submit(merged, immediate: true)
        }
        stopTimers()
        // Freeze discovery; suggestions stay for the preview/speaker-assignment UI.
        metadataResolver.enterPreviewMode()

        // Capture teardown runs off the main actor. Both `MicCapture.stop()` and
        // `SystemAudioCapture.stop()` block inside CoreAudio while the audio device
        // reconfigures — which is exactly what a call ending triggers — and on
        // 2026-08-12 that parked the main thread for 57 seconds mid-stop.
        let mic = micCapture
        let system = systemCapture
        micCapture = nil
        systemCapture = nil
        // Detached on purpose. A main-actor `Task` would resume on the main actor
        // between the two awaits, and `teardownForQuit()` blocks the main thread while
        // draining this — the two together would deadlock until the timeout.
        let captureTeardown = Task.detached {
            await mic?.stop()
            await system?.stop()
        }
        self.captureTeardown = captureTeardown
        // Safe to disarm here: the watchdog was guarding the `rebuildQueue.sync` that
        // used to run on this thread, and that block is gone. Disarming now rather than
        // after the teardown above also means a recording the user starts while the old
        // one is still tearing down keeps its own watchdog.
        MainActorWatchdog.shared.stop()

        // Tear down the engine off the main actor; finalize() reads the
        // already-populated timeline synchronously, so it needn't wait on this. The
        // offline pass (ASR re-pass + speaker detect + compaction) is NOT run here
        // anymore — finalize() enqueues it on the idle-gated offline queue, so a new
        // recording starting immediately can never be blocked by, or corrupted by, the
        // previous call's offline work.
        let engine = self.engine
        Task { await engine?.stop() }

        // finalize() still runs NOW, synchronously. It snapshots session identity from
        // live properties, so deferring it behind the teardown would let a recording
        // started in the meantime redirect this session's output — the data-loss bug the
        // snapshot comment inside it guards against. Only the offline enqueue waits.
        finalize(captureTeardown: captureTeardown)
    }

    /// Snapshots session identity, writes the transcript off the main actor, then
    /// presents enrichment / stamps the manifest on the main actor. Never blocks quit.
    ///
    /// - Parameter captureTeardown: in-flight audio teardown, awaited before the
    ///   offline pass is enqueued. That pass reads `mic.caf`, and the archive is not
    ///   flushed until `MicCapture.stop()` completes.
    private func finalize(captureTeardown: Task<Void, Never>? = nil) {
        // Include the trailing unconfirmed tail — on stop it's final.
        let segments = engine?.finalTimeline() ?? []
        AppLog.log("Recording stopped — \(segments.count) segments (confirmed + tail)", category: "record")
        // Always save (even with no speech) so a recorded call is never lost and
        // its audio stays linked in History — rather than silently discarded.

        // Write new destination/attendees back to the vault so they're indexed next time.
        if !meeting.destinationPath.isEmpty { vault.ensureDestination(meeting.destinationPath) }
        let attendeeNames = meeting.attendees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        vault.addPeopleInBackground(attendeeNames)

        let date = recordingStartDate ?? Date()
        let folder = AppPaths.unprocessedURL
        let title = meeting.meetingTitle
        let destination = meeting.destinationPath
        let attendees = meeting.attendees
        let manual = meeting.manualNotes
        let attachments = meeting.attachments
        let vaultURL = settings.vaultURL
        // Snapshot session identity into LOCALS before the async Task, so a new recording
        // starting immediately (which reassigns `sessionDirectory`/`engine`) can never
        // redirect this session's offline job — the root cause of the data-loss bug.
        let sessionDir = sessionDirectory
        let sessionManifest = manifest
        let isSpeakerEngine = engine != nil
        let autoSummarize = settings.autoRunClaude
        let batchMode = sessionBatchMode
        let batchLanguage = settings.liveStreamingLanguage
        let batchTiming = BatchModePolicy.pinnedSchedule(
            batchMode: batchMode,
            stored: sessionManifest?.transcriptionTiming,
            live: settings.transcriptionTiming)
        let batchWindowStart = sessionManifest?.transcriptionWindowStartHour ?? settings.transcriptionWindowStartHour
        let batchWindowEnd = sessionManifest?.transcriptionWindowEndHour ?? settings.transcriptionWindowEndHour
        let partialPath = sessionDir.map { $0.appendingPathComponent("transcript.partial.md") }
        // Link to the session audio (mic track) if it was archived.
        let audioPath = sessionDir.map { $0.appendingPathComponent("mic.caf").path }

        // DURABILITY: stop the heartbeat timer NOW so no further `.active` stamps can
        // land after the user stopped. The actual `.finalized` stamp is written inside
        // the Task's SUCCESS path (below) — so a crash between here and the transcript
        // write leaves the manifest `.active`, which the Recovery sheet catches.
        stopHeartbeat()

        let enrichRows = enrichmentRows(forAttendees: attendeeNames)
        let destinationLeaf = destination.split(separator: "/").last.map(String.init) ?? ""

        Task {
            do {
                let result = try await Task.detached {
                    let written = try TranscriptWriter.write(
                        title: title, date: date, attendees: attendees, destination: destination,
                        segments: segments,
                        manualNotes: manual.isEmpty ? nil : manual,
                        attachments: attachments,
                        audioPath: audioPath,
                        folderURL: folder,
                        vaultURL: vaultURL
                    )
                    if let p = partialPath { try? FileManager.default.removeItem(at: p) }
                    if let dir = sessionDir {
                        try? FileManager.default.removeItem(at: dir.appendingPathComponent("segments.jsonl"))
                    }
                    return written
                }.value
                AppLog.log("Transcript written: \(result.url.path)\(segments.isEmpty ? " (no speech transcribed)" : "")", category: "record")
                lastTranscriptURL = result.url
                lastResult = segments.isEmpty
                    ? (batchMode
                        ? "Recording saved. Transcription queued."
                        : "Saved (no speech transcribed): \(result.url.lastPathComponent)")
                    : "Transcript saved: \(result.url.lastPathComponent)"
                store.refresh()
                if !enrichRows.isEmpty {
                    let runSummary = autoSummarize && !segments.isEmpty && !isSpeakerEngine
                    pendingEnrichment = AttendeeEnrichment(
                        rows: enrichRows,
                        transcriptURL: result.url,
                        destinationDefault: destinationLeaf,
                        runSummaryOnFinish: runSummary)
                    autoPresentEnrichment = true
                } else if autoSummarize && !segments.isEmpty && !isSpeakerEngine {
                    maybeAutoRunClaude(forTranscriptURL: result.url)
                }
                stampFinalizedManifest(
                    directory: sessionDir,
                    manifest: sessionManifest,
                    title: title,
                    attendees: attendees,
                    filing: destination,
                    manualNotes: manual,
                    attachments: attachments)
                if BatchModePolicy.shouldQueue(batchMode: batchMode, isSpeakerEngine: isSpeakerEngine,
                                               segmentCount: segments.count),
                   let dir = sessionDir {
                    let binding = Self.offlineBinding(
                        batchMode: batchMode, language: batchLanguage,
                        storedProfile: sessionManifest?.fluidAsrProfile,
                        fallbackProfile: FluidAsrBinding.profile(from: settings))
                    SessionStore.setOfflineStatus(.pending, attempts: 0, transcriptPath: result.url.path,
                                                  presentReviewWhenDone: false, in: dir)
                    await captureTeardown?.value
                    let mic = dir.appendingPathComponent("mic.caf")
                    let micBytes = (try? mic.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if micBytes > 0 {
                        offlineService.enqueue(OfflineJob(
                            sessionDir: dir, transcriptURL: result.url, title: title,
                            attendees: attendees, filing: destination,
                            presentReviewWhenDone: false, autoSummarize: autoSummarize,
                            fluidAsrProfile: binding.profile,
                            schedule: batchTiming, windowStartHour: batchWindowStart,
                            windowEndHour: batchWindowEnd, accurateBatch: binding.accurate))
                    } else {
                        SessionStore.setOfflineStatus(.cancelled, in: dir)
                    }
                    armIdleDrain()
                }
                clearArmable = true
                armClearIfReady()
            } catch {
                AppLog.log("Finalize failed: \(error.localizedDescription)", category: "record")
                lastResult = "Finalize failed: \(error.localizedDescription)"
            }
        }

        live.state = .idle
        armIdleDrain()
        scheduleIdleUnload()   // free the model's RAM if we sit idle after this
    }

    // MARK: At-stop speaker review (FluidAudio)

    /// Discovered speakers offered for naming. Produced by the offline queue (History
    /// "Detect speakers"), so it carries its OWN context — the transient engine that
    /// found these speakers, the transcript to rewrite, and the metadata snapshot — and
    /// never depends on the controller's live `engine`/`lastTranscriptURL`/`attendees`,
    /// which may already belong to a newer recording.
    struct SpeakerReview: Identifiable {
        let id = UUID()
        var speakers: [CallSpeakerSummary]
        let mixedCaf: URL?
        /// The transient engine that produced these speakers (used to enroll voiceprints
        /// + relabel on naming). Optional only for resilience; the queue always sets it.
        let engine: FluidAudioEngine?
        /// The transcript file to (guardedly) rewrite when the review is finished.
        let transcriptURL: URL?
        let title: String
        let filing: String
        /// Attendees accumulated for this review (job snapshot + names assigned in-sheet).
        var attendees: String
        /// Chain a Claude summary after the review is committed.
        var autoSummarize: Bool
        /// Cache-backed review (opened from a persisted pass — no live engine). When set,
        /// naming enrols from the cached centroid and finishing relabels the transcript by
        /// text substitution, so assignment needs no re-run of the offline pass.
        /// Mutable so naming can update `resolvedName` and write `speakers.json` immediately.
        var cache: SpeakerCache?
        let sessionDir: URL?
        /// speakerId → assigned name, accumulated during a cache-backed review.
        /// Seeded from cache auto-ids when the sheet opens so Done always applies them.
        var assignments: [String: String] = [:]

        init(speakers: [CallSpeakerSummary], mixedCaf: URL?,
             engine: FluidAudioEngine? = nil, transcriptURL: URL? = nil,
             title: String = "", filing: String = "", attendees: String = "", autoSummarize: Bool = false,
             cache: SpeakerCache? = nil, sessionDir: URL? = nil,
             assignments: [String: String] = [:]) {
            self.speakers = speakers
            self.mixedCaf = mixedCaf
            self.engine = engine
            self.transcriptURL = transcriptURL
            self.title = title
            self.filing = filing
            self.attendees = attendees
            self.autoSummarize = autoSummarize
            self.cache = cache
            self.sessionDir = sessionDir
            self.assignments = assignments
        }
    }

    /// History "Detect speakers". When the persisted speaker cache still has unnamed
    /// speakers, History's strip already offers them (with clips) — nothing to run.
    /// Otherwise re-run the offline pass, which rewrites the transcript and the cache.
    func assignSpeakers(forAudioPath audioPath: String?, transcript: URL,
                        attendees: String, title: String, filing: String) {
        guard let audioPath, !audioPath.isEmpty else {
            lastResult = "No saved audio for this recording — can't detect speakers."; return
        }
        let dir = URL(fileURLWithPath: audioPath).deletingLastPathComponent()
        if let cache = SpeakerCache.read(dir),
           cache.speakers.contains(where: { $0.resolvedName?.isEmpty != false }) {
            transcriptRevision += 1
            AppLog.log("Detect speakers: cache has unnamed speakers — naming in History strip", category: "record")
            return
        }
        reprocessSpeakers(forAudioPath: audioPath, transcript: transcript,
                          attendees: attendees, title: title, filing: filing)
    }

    /// On-demand speaker detection for an already-recorded call (from History).
    /// Enqueues an on-demand offline pass for an already-recorded call (History "Detect
    /// speakers"). Routes through the same idle-gated queue as the automatic post-stop
    /// pass — so it can't interfere with a live recording (it defers until idle) and
    /// can't corrupt anything (self-contained job). When done it opens the assign-speakers
    /// review (`presentReviewWhenDone`).
    func reprocessSpeakers(forAudioPath audioPath: String?, transcript: URL,
                           attendees: String, title: String, filing: String) {
        guard let audioPath, !audioPath.isEmpty else {
            lastResult = "No saved audio for this recording — can't detect speakers."; return
        }
        let micURL = URL(fileURLWithPath: audioPath)
        let dir = micURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: micURL.path) else {
            lastResult = "The audio for this recording was deleted — can't detect speakers."; return
        }
        let stored = SessionStore.read(dir)
        SessionStore.setOfflineStatus(.pending, attempts: 0, transcriptPath: transcript.path,
                                      presentReviewWhenDone: true, in: dir)
        offlineService.enqueue(OfflineJob(
            sessionDir: dir, transcriptURL: transcript, title: title,
            attendees: attendees, filing: filing,
            presentReviewWhenDone: true, autoSummarize: false,
            fluidAsrProfile: FluidAsrBinding.resolved(
                stored: stored?.fluidAsrProfile, settings: settings)))
        armIdleDrain()
        lastResult = isRecording
            ? "Speaker detection queued — runs when the current recording stops."
            : "Detecting speakers…"
    }

    /// Combine two or more drop/rejoin recording legs into a single note.
    ///
    /// Thin wrapper over `mergeService.merge`; mirrors the pattern of `reprocessSpeakers`.
    /// The caller is responsible for presenting the result to the user (the returned URL is
    /// the combined/seed note, or nil on failure).
    ///
    /// - Parameters:
    ///   - items: The recording legs to combine (any order; sorted internally by date).
    ///   - backend: Override the merge strategy; nil = auto (C2 when all audio is present, else C1).
    /// - Returns: The URL of the combined or seed note, or nil on failure.
    func combineRecordings(_ items: [TranscriptItem], backend: MergeBackend?) async -> URL? {
        await mergeService.merge(items, backend: backend)
    }

    /// Add an attendee to an already-saved transcript — e.g. someone present who
    /// didn't speak, or a name forgotten during the call. Updates the frontmatter
    /// AND the body "**Attendees:**" header so it shows in History, flows into the
    /// AI summary, and is remembered in the vault. (Speaking attendees are named via
    /// the speaker review; this is for non-speaking / forgotten ones.)
    func addAttendeeToTranscript(_ url: URL, name rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var names: [String] = []
        TranscriptWriter.updateFrontmatter(at: url) { meta in
            if !meta.attendees.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                meta.attendees.append(name)
            }
            names = meta.attendees
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let updated = Self.replaceAttendeeHeader(in: text, with: names)
            if updated != text { try? updated.write(to: url, atomically: true, encoding: .utf8) }
        }
        vault.addPeople([name])
        store.refresh()
        transcriptRevision += 1
        AppLog.log("Added attendee \(name) to \(url.lastPathComponent)", category: "history")
    }

    /// Overwrite a transcript's whole attendee list (frontmatter + body header), used by
    /// the History attendees editor. Mirrors `addAttendeeToTranscript` but REPLACES rather
    /// than appends; an empty list clears the field in both places. Trims/dedupes so a
    /// stray blank or duplicate never lands in the note.
    func setAttendees(on url: URL, to names: [String], unassignRemovedSpeakers: Bool = true) {
        var clean: [String] = []
        for n in names.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !n.isEmpty {
            if !clean.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { clean.append(n) }
        }
        let previous = TranscriptWriter.parseFrontmatter(url)
        TranscriptWriter.updateFrontmatter(at: url) { $0.attendees = clean }
        // Removing a chip means "this person wasn't on the call". When the voiceprint pass
        // had pinned that name on a speaker, the body still labels their lines with it and
        // every re-summary would list them again — hand those lines back to "Speaker N".
        let removed = (previous?.attendees ?? []).filter { old in
            !clean.contains { $0.caseInsensitiveCompare(old) == .orderedSame }
        }
        if unassignRemovedSpeakers, !removed.isEmpty,
           let dir = MeetingFiles.sessionDir(forAudioPath: previous?.audio),
           var cache = SpeakerCache.read(dir),
           let body = try? String(contentsOf: url, encoding: .utf8) {
            let before = cache
            let relabeled = SpeakerCache.unassign(removed, in: &cache, body: body)
            if relabeled != body { try? relabeled.write(to: url, atomically: true, encoding: .utf8) }
            if cache != before {
                cache.write(to: dir)
                AppLog.log("Unassigned removed attendee(s) from speakers on \(url.lastPathComponent)", category: "history")
            }
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let updated = Self.replaceAttendeeHeader(in: text, with: clean)
            if updated != text { try? updated.write(to: url, atomically: true, encoding: .utf8) }
        }
        vault.addPeople(clean)
        store.refresh()
        transcriptRevision += 1
        AppLog.log("Set attendees on \(url.lastPathComponent): \(clean.count)", category: "history")
    }

    // MARK: Attachments

    /// Seconds elapsed in the current live recording (for attachment timestamps).
    func currentRecordingOffset() -> Double? {
        guard live.isRecording, let started = live.recordingStarted else { return nil }
        return Date().timeIntervalSince(started)
    }

    /// Paste an image into the live session's attachment list.
    @discardableResult
    func pasteLiveAttachment(caption: String = "") -> String? {
        guard let folderID = sessionDirectory?.lastPathComponent else { return "Start recording first." }
        return addAttachment(caption: caption, folderID: folderID, toLive: true)
    }

    /// Add image files to the live session.
    @discardableResult
    func addLiveAttachments(from urls: [URL], caption: String = "") -> String? {
        guard let folderID = sessionDirectory?.lastPathComponent else { return "Start recording first." }
        for url in urls {
            if let err = addAttachmentFile(url, caption: caption, folderID: folderID, toLive: true) { return err }
        }
        return nil
    }

    /// Paste an image onto a saved transcript (History detail).
    @discardableResult
    func pasteAttachment(on transcriptURL: URL, caption: String = "") -> String? {
        let folderID = MeetingAttachmentStore.folderID(forTranscript: transcriptURL)
        return addAttachment(caption: caption, folderID: folderID, transcriptURL: transcriptURL)
    }

    /// Add image files to a saved transcript.
    @discardableResult
    func addAttachments(from urls: [URL], on transcriptURL: URL, caption: String = "") -> String? {
        let folderID = MeetingAttachmentStore.folderID(forTranscript: transcriptURL)
        for url in urls {
            if let err = addAttachmentFile(url, caption: caption, folderID: folderID,
                                           transcriptURL: transcriptURL) { return err }
        }
        return nil
    }

    func removeLiveAttachment(id: UUID) {
        meeting.attachments.removeAll { $0.id == id }
        persistManifest(status: .active)
    }

    func removeAttachment(id: UUID, on transcriptURL: URL) {
        var list = MeetingAttachmentStore.loadAttachments(from: transcriptURL)
        list.removeAll { $0.id == id }
        MeetingAttachmentStore.syncTranscript(transcriptURL, vault: settings.vaultURL, attachments: list)
        store.refresh()
        transcriptRevision += 1
    }

    func updateLiveAttachmentCaption(id: UUID, caption: String) {
        guard let idx = meeting.attachments.firstIndex(where: { $0.id == id }) else { return }
        meeting.attachments[idx].caption = caption
        persistManifest(status: .active)
    }

    func updateAttachmentCaption(id: UUID, caption: String, on transcriptURL: URL) {
        var list = MeetingAttachmentStore.loadAttachments(from: transcriptURL)
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].caption = caption
        MeetingAttachmentStore.syncTranscript(transcriptURL, vault: settings.vaultURL, attachments: list)
        store.refresh()
    }

    func pickAndAddLiveAttachments() {
        let urls = MeetingAttachmentStore.openImagePicker()
        guard !urls.isEmpty else { return }
        _ = addLiveAttachments(from: urls)
    }

    func pickAndAddAttachments(on transcriptURL: URL) {
        let urls = MeetingAttachmentStore.openImagePicker()
        guard !urls.isEmpty else { return }
        _ = addAttachments(from: urls, on: transcriptURL)
    }

    @discardableResult
    private func addAttachment(caption: String, folderID: String,
                               toLive: Bool = false, transcriptURL: URL? = nil) -> String? {
        do {
            let att = try MeetingAttachmentStore.addPasteboardImage(
                vault: settings.vaultURL, folderID: folderID, caption: caption,
                capturedAtOffset: toLive ? currentRecordingOffset() : nil)
            if toLive {
                meeting.attachments.append(att)
                persistManifest(status: .active)
            } else if let transcriptURL {
                var list = MeetingAttachmentStore.loadAttachments(from: transcriptURL)
                list.append(att)
                MeetingAttachmentStore.syncTranscript(transcriptURL, vault: settings.vaultURL, attachments: list)
                store.refresh()
                transcriptRevision += 1
            }
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @discardableResult
    private func addAttachmentFile(_ url: URL, caption: String, folderID: String,
                                   toLive: Bool = false, transcriptURL: URL? = nil) -> String? {
        do {
            let att = try MeetingAttachmentStore.addFile(
                from: url, vault: settings.vaultURL, folderID: folderID, caption: caption,
                capturedAtOffset: toLive ? currentRecordingOffset() : nil)
            if toLive {
                meeting.attachments.append(att)
                persistManifest(status: .active)
            } else if let transcriptURL {
                var list = MeetingAttachmentStore.loadAttachments(from: transcriptURL)
                list.append(att)
                MeetingAttachmentStore.syncTranscript(transcriptURL, vault: settings.vaultURL, attachments: list)
                store.refresh()
                transcriptRevision += 1
            }
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Replace (or insert after the Date line) the body "**Attendees:**" header so it
    /// matches the frontmatter list. An empty list removes the header line entirely.
    private static func replaceAttendeeHeader(in text: String, with names: [String]) -> String {
        var lines = text.components(separatedBy: "\n")
        guard !names.isEmpty else {
            lines.removeAll { $0.hasPrefix("**Attendees:**") }
            return lines.joined(separator: "\n")
        }
        let line = "**Attendees:** \(names.joined(separator: ", "))"
        if let idx = lines.firstIndex(where: { $0.hasPrefix("**Attendees:**") }) {
            lines[idx] = line
        } else if let dateIdx = lines.firstIndex(where: { $0.hasPrefix("**Date:**") }) {
            lines.insert(line, at: dateIdx + 1)
        } else {
            return text
        }
        return lines.joined(separator: "\n")
    }

    /// Finish the review: rewrite the review's transcript with the (possibly newly-named)
    /// speakers + attendees, then clear the sheet. The review carries its OWN engine +
    /// target file (it came from the offline queue / History), so this never touches the
    /// live Record meeting.
    func finishSpeakerReview() {
        let review = pendingSpeakerReview
        pendingSpeakerReview = nil
        autoPresentSpeakerReview = false

        if let review, review.cache != nil, let url = review.transcriptURL {
            // Cache-backed: merge auto-resolved + user assignments, then text-substitute
            // "Speaker N" → name (no engine). Voiceprints enrolled in nameSpeaker.
            let assignments = SpeakerCache.mergedAssignments(cache: review.cache, user: review.assignments)
            if !assignments.isEmpty,
               let body = try? String(contentsOf: url, encoding: .utf8) {
                let relabeled = SpeakerCache.relabel(body, assignments: assignments)
                if relabeled != body { try? relabeled.write(to: url, atomically: true, encoding: .utf8) }
            }
            // Persist resolved names so reopening the sheet keeps them.
            if var cache = review.cache, let dir = review.sessionDir {
                cache.applyAssignments(assignments)
                cache.write(to: dir)
            }
            TranscriptWriter.updateFrontmatter(at: url) {
                $0.attendees = TranscriptWriter.splitAttendees(review.attendees)
            }
            vault.addPeople(TranscriptWriter.splitAttendees(review.attendees))
            store.refresh()
            transcriptRevision += 1
            AppLog.log("Assigned speakers from cache: \(url.lastPathComponent)", category: "record")
            let renames = Self.speakerRepairRenames(
                assignments: assignments,
                originalSpeakers: review.speakers)
            maybeEnqueueRepair(afterRelabel: url, renames: renames)
            enqueueSummaryAfterSpeakerReview(url: url)
        } else if let review, let url = review.transcriptURL, let eng = review.engine {
            let segs = eng.finalTimeline()
            let sessionDir = url.deletingLastPathComponent()
            // Prefer multi-leg full duration when the session was resumed mid-call.
            let micLegs = MeetingFiles.audioSegmentURLs(in: sessionDir, base: "mic")
            let audioDuration = micLegs.map(SessionStore.audioDuration).reduce(0, +)
            if TranscriptCoverage.isSafeReplacement(offline: segs, existingFile: url, audioDuration: audioDuration) {
                TranscriptWriter.rewriteTranscriptFile(at: url, segments: segs, title: review.title,
                                                       filing: review.filing, attendees: review.attendees)
            } else {
                // Keep the existing (longer) transcript; still record the named attendees.
                TranscriptWriter.updateFrontmatter(at: url) { $0.attendees = TranscriptWriter.splitAttendees(review.attendees) }
            }
            vault.addPeople(TranscriptWriter.splitAttendees(review.attendees))
            store.refresh()
            transcriptRevision += 1
            AppLog.log("Rewrote transcript (reviewed speakers): \(url.lastPathComponent)", category: "record")
            let renames = Self.speakerRepairRenames(
                assignments: review.assignments,
                originalSpeakers: review.speakers)
            maybeEnqueueRepair(afterRelabel: url, renames: renames)
            enqueueSummaryAfterSpeakerReview(url: url)
        } else {
            // Fallback (no decoupled context): rewrite the live transcript.
            rewriteLastTranscript(reason: "reviewed speakers")
        }
        // B: best-effort enrichment for speaker-review attendees with no known company.
        // The summary was already enqueued above (independent of the sheet), so
        // runSummaryOnFinish is false here — we're only enriching the rolodex.
        if let review {
            let names = TranscriptWriter.splitAttendees(review.attendees)
            let enrichRows = enrichmentRows(forAttendees: names)
            if !enrichRows.isEmpty {
                let leaf = review.filing.split(separator: "/").last.map(String.init) ?? ""
                pendingEnrichment = AttendeeEnrichment(
                    rows: enrichRows,
                    transcriptURL: review.transcriptURL,
                    destinationDefault: leaf,
                    runSummaryOnFinish: false)
                autoPresentEnrichment = true
            }
        }
        // The review closed — re-arm the Record-view auto-clear (if it was deferred) and
        // pump the offline queue in case a job was waiting behind the open sheet.
        armClearIfReady()
        armIdleDrain()
    }

    /// Immediate reset of the Record view for the next meeting (does not wait on queues).
    func clearForNextMeeting() {
        clearToken += 1
        clearForNextMeeting(token: clearToken)
    }

    // MARK: - Post-call enrichment (Slice B)

    /// Returns rows for attendees that have no known company in the rolodex.
    /// Empty when all attendees are already enriched (the common case after the
    /// first time someone has been met).
    func enrichmentRows(forAttendees names: [String]) -> [AttendeeEnrichment.Row] {
        names
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !vault.isCompanyKnown($0) }
            .map { AttendeeEnrichment.Row(name: $0) }
    }

    /// Called by the enrichment sheet on both Save and Skip paths.
    ///
    /// - Parameter save: when `true`, persists non-empty company rows to the
    ///   rolodex. When `false` (Skip all / Escape dismiss), upserts are skipped
    ///   but the deferred non-speaker summary still fires so it is never lost.
    func finishEnrichment(save: Bool, rows: [AttendeeEnrichment.Row]? = nil) {
        let e = pendingEnrichment
        pendingEnrichment = nil
        autoPresentEnrichment = false
        if save {
            let filled = (rows ?? e?.rows ?? []).filter {
                !$0.company.trimmingCharacters(in: .whitespaces).isEmpty
            }
            vault.upsertPeople(filled.map {
                (name: $0.name, title: $0.title, company: $0.company, linkedin: $0.linkedin)
            })
        }
        if let e, e.runSummaryOnFinish, let url = e.transcriptURL { maybeAutoRunClaude(forTranscriptURL: url) }
        armClearIfReady()
    }

    func linkAttendeeToExisting(detected: String, canonicalName: String) {
        vault.addAlias(detected, toCanonical: canonicalName)
    }

    /// Write confirmed inferred affiliations back to the rolodex (promotes attendees out
    /// of the "Other" section into their inferred company section).
    /// Called from HistoryView at commit time for each toggle that is ON.
    func confirmInferredAffiliations(_ items: [InferredAffiliation]) {
        for i in items {
            vault.upsertPerson(name: i.name, title: "", company: i.company, linkedin: "")
        }
    }

    // MARK: Auto-clear after meeting

    /// Start the auto-clear countdown if the Record view is genuinely settled on a
    /// finished meeting. Called from several anchors (stop / finalize / review end,
    /// and the busy-state sinks), so it is deliberately idempotent and self-gating:
    /// every precondition is re-checked here, and a no-op return is the common case.
    func armClearIfReady() {
        guard pendingClear == nil else { return }            // never restart a live countdown
        guard clearArmable else { return }                   // only after a live recording finished
        guard settings.autoClearSeconds > 0 else { return }  // 0 = feature off
        guard live.state == .idle else { return }
        guard lastTranscriptURL != nil else { return }       // nothing was saved → nothing to clear
        guard !clearIsBusy else { return }                   // a busy gate will re-arm us later
        startClearCountdown(seconds: Int(settings.autoClearSeconds))
    }

    /// Begin (or restart) the 1-second-tick countdown to a full wipe. A fresh
    /// `clearToken` invalidates any in-flight timer's ticks, so overlapping arms
    /// can't double-count.
    private func startClearCountdown(seconds: Int) {
        clearToken += 1
        let token = clearToken
        pendingClear = PendingClear(remaining: seconds)
        clearTimer?.invalidate()
        clearTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A newer session/arm (or an explicit cancel) has superseded us.
                guard token == self.clearToken, var pending = self.pendingClear else { return }
                // A busy gate re-appeared mid-countdown (e.g. the user reopened the
                // review). Stand down — the busy-state sinks will re-arm a full delay.
                if self.clearIsBusy {
                    self.clearTimer?.invalidate(); self.clearTimer = nil
                    self.pendingClear = nil
                    return
                }
                pending.remaining -= 1
                if pending.remaining <= 0 {
                    self.clearForNextMeeting(token: token)
                } else {
                    self.pendingClear = pending
                }
            }
        }
    }

    /// Cancel any pending auto-clear (the explicit "Keep" on the chip, or a
    /// superseding event). Leaves `clearArmable` untouched.
    func cancelPendingClear() {
        clearTimer?.invalidate(); clearTimer = nil
        pendingClear = nil
    }

    /// A metadata-field edit while the countdown is visibly ticking is an implicit
    /// "Keep": stop the countdown AND disarm, so a later busy-clear sink can't
    /// quietly re-arm and wipe data the user just signalled they want to retain.
    /// Gated on a live countdown deliberately — naming speakers in the review sheet
    /// appends to `attendees` programmatically, and without the gate that onChange
    /// would disarm the auto-clear before finishSpeakerReview() ever got to arm it.
    func userInteracted() {
        guard pendingClear != nil else { return }
        cancelPendingClear()
        clearArmable = false
    }

    /// The countdown fired: wipe the Record view back to a blank slate for the next
    /// call. Re-guards the token + idle state so a stale timer or a recording that
    /// started in the meantime can't clobber live state.
    private func clearForNextMeeting(token: Int) {
        guard token == clearToken, live.state == .idle else { return }
        clearTimer?.invalidate(); clearTimer = nil
        pendingClear = nil
        resetSegmentPublishState()
        meeting.meetingTitle = ""
        meeting.attendees = ""
        meeting.destinationPath = ""
        meeting.manualNotes = ""
        meeting.attachments = []
        lastResult = nil
        lastTranscriptURL = nil
        autoPresentSpeakerReview = false
        clearArmable = false
        meeting.resetDiscovery()
        admission.reset()
        modeResetForNextMeeting?()
        AppLog.log("Auto-cleared Record view for the next meeting", category: "record")
    }

    /// Optional hook for Record UI to return to the live idle hero.
    var modeResetForNextMeeting: (() -> Void)?

    /// Queue a background Claude summary for the just-saved recording, if auto-summarize
    /// is on. Reads the current transcript (post-attribution) from the store so the summary
    /// reflects assigned speakers + attendees. The result is staged for review in History.
    /// Callers pass the saved transcript's URL because a new recording may already have
    /// re-pointed `lastTranscriptURL` and `engine` by the time this runs.
    private func maybeAutoRunClaude(forTranscriptURL url: URL) {
        guard settings.autoRunClaude else { return }
        store.refresh()
        guard let item = store.items.first(where: { $0.url == url })
            ?? store.items.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) else { return }
        summaryService.enqueueIfPolicyAllows(item, trigger: .freshRecording)
    }

    /// Record-tab Preview "Generate notes" uses the same queue as History.
    func enqueuePreviewSummary() {
        guard let url = lastTranscriptURL else { return }
        let meta = TranscriptWriter.parseFrontmatter(url)
            ?? TranscriptMeta(title: url.deletingPathExtension().lastPathComponent,
                              date: Date(), attendees: [], filing: meeting.destinationPath,
                              status: "unprocessed", note: nil, audio: nil, type: "recording")
        let item = store.items.first(where: { $0.url == url })
            ?? store.items.first { $0.url.lastPathComponent == url.lastPathComponent }
            ?? TranscriptItem(url: url, meta: meta, isProcessed: false)
        summaryService.enqueueIfPolicyAllows(item, trigger: .userInitiated)
    }

    /// Rewrite the saved transcript from the engine's current (post-offline-pass)
    /// timeline + attendees. Used both after the speaker review and automatically
    /// once the offline diarization + ASR re-pass finishes (so the saved file gets
    /// the corrected labels / higher-accuracy transcript even without a review).
    func rewriteLastTranscript(reason: String) {
        guard let url = lastTranscriptURL, var meta = TranscriptWriter.parseFrontmatter(url) else { return }
        // The record view's Title / Filing / Attendees fields stay editable after stopping —
        // they are the source of truth, so pull the LIVE values (not the saved meta) so a
        // title/destination set or changed post-recording actually reaches disk + History.
        let liveTitle = meeting.meetingTitle.trimmingCharacters(in: .whitespaces)
        if !liveTitle.isEmpty { meta.title = liveTitle }
        let liveDest = meeting.destinationPath.trimmingCharacters(in: .whitespaces)
        if !liveDest.isEmpty { meta.filing = liveDest }
        meta.attendees = TranscriptWriter.splitAttendees(meeting.attendees)

        let segs = engine?.finalTimeline() ?? live.segments
        if segs.isEmpty {
            // No transcript body to regenerate (e.g. metadata-only edit) — just re-stamp.
            TranscriptWriter.updateFrontmatter(at: url) { m in
                m.title = meta.title; m.filing = meta.filing; m.attendees = meta.attendees
            }
        } else {
            let body = TranscriptWriter.makeBody(
                title: meta.title, date: meta.date, attendees: meeting.attendees, destination: meta.filing,
                segments: segs, manualNotes: meeting.manualNotes.isEmpty ? nil : meeting.manualNotes, meta: meta)
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
        vault.addPeople(TranscriptWriter.splitAttendees(meeting.attendees))
        if !liveDest.isEmpty { vault.ensureDestination(liveDest) }
        store.refresh()
        transcriptRevision += 1
        AppLog.log("Rewrote transcript (\(reason)): \(url.lastPathComponent)", category: "record")
    }

    private var metadataSyncTask: Task<Void, Never>?
    /// Debounced re-stamp of the saved transcript from the live Title/Filing/Attendees
    /// fields, for edits made after the recording has stopped (no-op while recording or
    /// before anything is saved).
    func scheduleMetadataSync() {
        guard !isRecording, lastTranscriptURL != nil else { return }
        metadataSyncTask?.cancel()
        metadataSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.syncMetadataToTranscript()
        }
    }

    /// Update frontmatter + header lines only — NEVER regenerates the transcript body.
    /// The on-disk body (written by the offline pass) is always at least as good as the
    /// live engine timeline, so this preserves it verbatim.
    private func syncMetadataToTranscript() {
        guard let url = lastTranscriptURL else { return }
        let liveTitle = meeting.meetingTitle.trimmingCharacters(in: .whitespaces)
        let liveDest = meeting.destinationPath.trimmingCharacters(in: .whitespaces)
        let names = TranscriptWriter.splitAttendees(meeting.attendees)

        TranscriptWriter.updateFrontmatter(at: url) { m in
            if !liveTitle.isEmpty { m.title = liveTitle }
            if !liveDest.isEmpty { m.filing = liveDest }
            m.attendees = names
        }

        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let updated = Self.replaceHeaderLines(in: text, title: liveTitle, filing: liveDest, names: names)
            if updated != text { try? updated.write(to: url, atomically: true, encoding: .utf8) }
        }

        vault.addPeople(names)
        if !liveDest.isEmpty { vault.ensureDestination(liveDest) }
        store.refresh()
        transcriptRevision += 1
        AppLog.log("Synced metadata (header only): \(url.lastPathComponent)", category: "record")
    }

    /// Replace the title heading, Filing line, and Attendees line in the body header
    /// without touching anything from `## Transcript` onward.
    private static func replaceHeaderLines(in text: String, title: String, filing: String, names: [String]) -> String {
        var lines = text.components(separatedBy: "\n")

        // Replace the first `# ` title heading (not `## `)
        if !title.isEmpty,
           let idx = lines.firstIndex(where: { $0.hasPrefix("# ") && !$0.hasPrefix("## ") }) {
            lines[idx] = "# \(title)"
        }

        // Replace the `**Filing:**` line
        if !filing.isEmpty,
           let idx = lines.firstIndex(where: { $0.hasPrefix("**Filing:**") }) {
            lines[idx] = "**Filing:** \(filing)"
        }

        // Replace the `**Attendees:**` line (reuse existing helper)
        return replaceAttendeeHeader(in: lines.joined(separator: "\n"), with: names)
    }

    // MARK: Idle model unload

    /// Schedule unloading the model after the configured idle stretch, freeing
    /// its ~1 GB+ of resident memory. Reset whenever activity resumes. The model
    /// reloads on the next call/record while capture proceeds, so the only cost
    /// is a short catch-up at the start of that meeting.
    private func scheduleIdleUnload() {
        idleUnloadTimer?.invalidate(); idleUnloadTimer = nil
        guard settings.idleUnloadEnabled else { return }
        let interval = max(60, settings.idleUnloadMinutes * 60)
        idleUnloadTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.idleUnloadEnabled,
                      self.live.state == .idle, !self.isRecording else { return }
                if self.offlineService.hasWork {
                    self.scheduleIdleUnload()
                    return
                }
                AppLog.log("Idle \(Int(interval / 60))min — unloading model to free memory", category: "model")
                Task { await self.fluidModels.unload() }
            }
        }
    }

    private func cancelIdleUnload() {
        idleUnloadTimer?.invalidate(); idleUnloadTimer = nil
    }

    // MARK: Session manifest (durable crash-recovery state)

    /// Write the session's manifest as `active` and start the heartbeat. A
    /// manifest that's still `active` at next launch means we crashed.
    private func beginSessionManifest(dir: URL) {
        let call = callDetector.activeCall
        var m = SessionManifest(
            id: dir.lastPathComponent,
            title: meeting.meetingTitle, attendees: meeting.attendees, filing: meeting.destinationPath,
            model: settings.parakeetVersion.rawValue, computeMode: "fluid",
            startedAt: recordingStartDate ?? Date(), lastHeartbeat: Date(),
            status: .active, startedByDetection: startedByDetection,
            callBundleID: call?.bundleID, callDisplayName: call?.displayName,
            manualNotes: meeting.manualNotes, attachments: meeting.attachments.isEmpty ? nil : meeting.attachments,
            audioTracks: ["mic.caf", "system.caf"])
        if sessionBatchMode {
            m.fluidAsrProfile = BatchModePolicy.profile(language: settings.liveStreamingLanguage)
            m.batchMode = true
            m.transcriptionTiming = settings.transcriptionTiming
            m.transcriptionWindowStartHour = settings.transcriptionWindowStartHour
            m.transcriptionWindowEndHour = settings.transcriptionWindowEndHour
        } else {
            m.fluidAsrProfile = FluidAsrBinding.profile(from: settings)
        }
        manifest = m
        SessionStore.write(m, to: dir)
        AppLog.log("Session manifest written (active) — \(dir.lastPathComponent)", category: "record")
        startHeartbeat()
    }

    /// Re-mark an existing (crashed) session's manifest as active on resume.
    private func reactivateSessionManifest(dir: URL) {
        guard var m = SessionStore.read(dir) else {
            beginSessionManifest(dir: dir)   // no manifest (legacy) → write a fresh one
            return
        }
        m.status = .active
        m.lastHeartbeat = Date()
        // Resuming makes this a live recording again — clear any offline-queue state so
        // it isn't picked up while recording or double-enqueued (it'll be re-enqueued
        // when this resumed session finally finalizes).
        m.offlineStatus = nil
        m.offlineAttempts = nil
        m.transcriptPath = nil
        m.presentReviewWhenDone = nil
        manifest = m
        SessionStore.write(m, to: dir)
        offlineService.cancel(sessionDir: dir)
        AppLog.log("Session manifest reactivated (resume) — \(dir.lastPathComponent)", category: "record")
        startHeartbeat()
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistManifest(status: .active) }
        }
    }

    /// Refresh the manifest with the latest user-editable metadata + heartbeat
    /// (so a mid-call title/attendee/notes edit survives a crash), or finalize it.
    private func persistManifest(status: SessionManifest.Status) {
        persistManifest(
            status: status,
            manifest: manifest,
            directory: sessionDirectory,
            title: meeting.meetingTitle,
            attendees: meeting.attendees,
            filing: meeting.destinationPath,
            manualNotes: meeting.manualNotes,
            attachments: meeting.attachments.isEmpty ? nil : meeting.attachments,
            titleSource: meeting.titleSource,
            suggestedAttendees: {
                let rows = meeting.roster.persistedSuggestions()
                return rows.isEmpty ? nil : rows
            }(),
            releaseLivePointers: false)
    }

    private func persistManifest(
        status: SessionManifest.Status,
        manifest snapshot: SessionManifest?,
        directory: URL?,
        title: String,
        attendees: String,
        filing: String,
        manualNotes: String,
        attachments: [MeetingAttachment]?,
        titleSource: String?,
        suggestedAttendees: [SuggestedAttendee]?,
        releaseLivePointers: Bool
    ) {
        guard let snapshot, let directory else { return }
        let m = SessionStore.stamped(
            snapshot,
            status: status,
            title: title,
            attendees: attendees,
            filing: filing,
            manualNotes: manualNotes,
            attachments: attachments,
            titleSource: titleSource,
            suggestedAttendees: suggestedAttendees)
        SessionStore.write(m, to: directory)
        guard sessionDirectory == directory else { return }
        if releaseLivePointers {
            manifest = nil
            journal = nil
        } else {
            manifest = m
        }
    }

    /// Stop the heartbeat timer so no further `.active` stamps can land after the
    /// recording stops. Call this SYNCHRONOUSLY at finalize entry. The actual
    /// `.finalized` manifest stamp is written inside the async Task's success path
    /// (see `finalize()`) so a crash before the transcript write leaves the manifest
    /// `.active` — catchable by the Recovery sheet — rather than orphaned.
    private func stopHeartbeat() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
    }

    /// Stamp the manifest `.finalized` and release the in-memory references.
    /// Called from inside the async Task in `finalize()` AFTER the transcript write
    /// succeeds, so durability is guaranteed before the status advances.
    private func stampFinalizedManifest(
        directory: URL?,
        manifest snapshot: SessionManifest?,
        title: String,
        attendees: String,
        filing: String,
        manualNotes: String,
        attachments: [MeetingAttachment]
    ) {
        persistManifest(
            status: .finalized,
            manifest: snapshot,
            directory: directory,
            title: title,
            attendees: attendees,
            filing: filing,
            manualNotes: manualNotes,
            attachments: attachments.isEmpty ? nil : attachments,
            titleSource: snapshot?.titleSource,
            suggestedAttendees: snapshot?.suggestedAttendees,
            releaseLivePointers: true)
        AppLog.log("Session manifest finalized — \(snapshot?.id ?? "?")", category: "record")
    }

    // MARK: Crash recovery (launch)

    /// Collect crashed sessions (manifest still `.active`) for the Recovery sheet.
    private func gatherRecoveries() {
        pendingRecoveries = SessionStore.crashedSessions().map { entry in
            RecoverableSession(dir: entry.dir, manifest: entry.manifest,
                               durationSeconds: SessionStore.audioDuration(entry.dir.appendingPathComponent("mic.caf")))
        }
        if !pendingRecoveries.isEmpty {
            AppLog.log("Found \(pendingRecoveries.count) crashed session(s) for recovery: \(pendingRecoveries.map(\.manifest.title).joined(separator: ", "))", category: "record")
        }
    }

    /// Finalize a crashed session into a transcript without resuming. Rebuilds from
    /// the segment journal. Idempotent: marks the manifest finalized so it won't reappear.
    func recover(_ session: RecoverableSession) {
        guard live.state == .idle || isErrorState else { return }
        let dir = session.dir
        let m = session.manifest
        Task {
            isRecovering = true
            let segs = SegmentJournal.read(dir.appendingPathComponent("segments.jsonl"))
            do {
                let result = try TranscriptWriter.write(
                    title: m.title, date: m.startedAt, attendees: m.attendees,
                    destination: m.filing, segments: segs,
                    manualNotes: m.manualNotes.isEmpty ? nil : m.manualNotes,
                    audioPath: dir.appendingPathComponent("mic.caf").path,
                    folderURL: AppPaths.unprocessedURL)
                var finalized = m; finalized.status = .finalized; finalized.lastHeartbeat = Date()
                SessionStore.write(finalized, to: dir)
                lastTranscriptURL = result.url
                lastResult = "Recovered “\(m.title)” → \(result.url.lastPathComponent)"
                AppLog.log("Recovered \(session.id) (from journal; \(segs.count) segments) → \(result.url.lastPathComponent)", category: "record")
                store.refresh()
                // Give the recovered session the same background offline pass a normal
                // stop gets (speaker detect + attributed rewrite), when next idle.
                let batch = m.batchMode == true
                if batch || !segs.isEmpty {
                    let binding = Self.offlineBinding(
                        batchMode: batch,
                        language: settings.liveStreamingLanguage,
                        storedProfile: m.fluidAsrProfile,
                        fallbackProfile: FluidAsrBinding.profile(from: settings))
                    SessionStore.setOfflineStatus(.pending, attempts: 0, transcriptPath: result.url.path,
                                                  presentReviewWhenDone: false, in: dir)
                    offlineService.enqueue(OfflineJob(
                        sessionDir: dir, transcriptURL: result.url, title: m.title,
                        attendees: m.attendees, filing: m.filing,
                        presentReviewWhenDone: false, autoSummarize: settings.autoRunClaude,
                        fluidAsrProfile: binding.profile,
                        schedule: BatchModePolicy.pinnedSchedule(
                            batchMode: batch, stored: m.transcriptionTiming, live: .afterCall),
                        windowStartHour: m.transcriptionWindowStartHour ?? settings.transcriptionWindowStartHour,
                        windowEndHour: m.transcriptionWindowEndHour ?? settings.transcriptionWindowEndHour,
                        accurateBatch: binding.accurate))
                    armIdleDrain()
                }
            } catch {
                lastResult = "Recovery failed: \(error.localizedDescription)"
                AppLog.log("Recovery failed for \(session.id): \(error.localizedDescription)", category: "record")
            }
            isRecovering = false
            pendingRecoveries.removeAll { $0.id == session.id }
        }
    }

    /// Whether a crashed session's call appears to still be live right now (the
    /// same conferencing app is on the mic) — Resume is recommended when true.
    func isCallLive(_ session: RecoverableSession) -> Bool {
        guard let bid = session.manifest.callBundleID else { return false }
        let known = settings.conferencingBundleIDs
        let wanted = AppIdentity.canonical(bid, known: known)
        if let active = callDetector.activeCall?.bundleID,
           AppIdentity.canonical(active, known: known) == wanted {
            return true
        }
        return callDetector.capturing.contains { process in
            guard let raw = process.bundleID else { return false }
            return AppIdentity.canonical(raw, known: known) == wanted
        }
    }

    /// How recently a crashed session must have been beating to be treated as "the
    /// same meeting that's now live" — so a stale, never-handled recovery from hours
    /// ago can't be auto-resumed into an unrelated new call on the same app.
    private static let resumeMatchWindow: TimeInterval = 30 * 60   // 30 minutes

    /// A pending crash recovery that belongs to the call now starting: same
    /// conferencing app (bundle id) AND a recent-enough last heartbeat. Most recent
    /// match wins. Drives auto-resume in `onCallStart` (Option B).
    private func matchingLiveRecovery(for call: DetectedCall) -> RecoverableSession? {
        let now = Date()
        let known = settings.conferencingBundleIDs
        let liveID = AppIdentity.canonical(call.bundleID, known: known)
        return pendingRecoveries
            .filter { session in
                guard let stored = session.manifest.callBundleID else { return false }
                return AppIdentity.canonical(stored, known: known) == liveID
            }
            .filter { now.timeIntervalSince($0.manifest.lastHeartbeat) < Self.resumeMatchWindow }
            .max { $0.manifest.lastHeartbeat < $1.manifest.lastHeartbeat }
    }

    /// Discard a crashed session entirely (audio + state).
    func discard(_ session: RecoverableSession) {
        try? FileManager.default.removeItem(at: session.dir)
        pendingRecoveries.removeAll { $0.id == session.id }
        AppLog.log("Discarded crashed session \(session.id)", category: "record")
    }

    /// All audio segment files for a track base name, in capture order
    /// (`mic.caf`, `mic.2.caf`, …).
    private func audioSegmentURLs(in dir: URL, base: String) -> [URL] {
        MeetingFiles.audioSegmentURLs(in: dir, base: base)
    }

    /// Enqueue a summary when the body is fully named; otherwise log why it was skipped.
    /// Confirm a speaker guess from History (no review sheet) — relabel, enroll, repair.
    func confirmSpeakerGuess(on transcript: URL, speakerId: String, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let dir = MeetingFiles.sessionDir(forAudioPath: store.items.first(where: { $0.url == transcript })?.meta.audio)
            ?? transcript.deletingLastPathComponent()
        guard var cache = SpeakerCache.read(dir) else { return }
        let previousAuto = cache.speakers.first(where: { $0.id == speakerId })?.resolvedName
        guard let idx = cache.speakers.firstIndex(where: { $0.id == speakerId }) else { return }
        cache.speakers[idx].resolvedName = clean
        cache.speakers[idx].guessedName = nil
        cache.write(to: dir)
        if let body = try? String(contentsOf: transcript, encoding: .utf8) {
            let relabeled = SpeakerCache.relabel(body, assignments: [speakerId: clean])
            if relabeled != body { try? relabeled.write(to: transcript, atomically: true, encoding: .utf8) }
        }
        let centroid = cache.speakers[idx].centroid
        if !centroid.isEmpty {
            enrollVoiceprint(name: clean, centroid: centroid, model: cache.embeddingModelID,
                             overridingAutoName: previousAuto)
        }
        if let meta = TranscriptWriter.parseFrontmatter(transcript) {
            var names = meta.attendees
            if !names.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                names.append(clean)
                TranscriptWriter.updateFrontmatter(at: transcript) { $0.attendees = names }
            }
        }
        vault.addPeople([clean])
        store.refresh()
        transcriptRevision += 1
        var renames = ["Speaker \(speakerId)": clean]
        if let previousAuto = previousAuto?.trimmingCharacters(in: .whitespacesAndNewlines),
           !previousAuto.isEmpty,
           previousAuto.caseInsensitiveCompare(clean) != .orderedSame {
            renames[previousAuto] = clean
        }
        maybeEnqueueRepair(afterRelabel: transcript, renames: renames)
        if let item = store.items.first(where: { $0.url == transcript }),
           item.summaryReadyURL == nil,
           item.meta.note?.isEmpty != false {
            summaryService.enqueueIfPolicyAllows(item, trigger: .speakerReviewCompleted)
        }
    }

    private func maybeEnqueueRepair(afterRelabel url: URL, renames: [String: String]) {
        guard !renames.isEmpty else { return }
        store.refresh()
        guard let item = store.items.first(where: { $0.url == url })
            ?? store.items.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) else { return }
        if let staged = item.summaryReadyURL {
            summaryService.enqueueRepair(item, renames: renames, previousNoteURL: staged)
        } else if let note = item.meta.note, !note.isEmpty {
            summaryService.enqueueRepair(item, renames: renames, previousNoteURL: URL(fileURLWithPath: note))
        }
    }

    static func speakerRepairRenames(
        assignments: [String: String],
        originalSpeakers: [CallSpeakerSummary]
    ) -> [String: String] {
        var renames: [String: String] = [:]
        var originals: [String: String] = [:]
        for speaker in originalSpeakers {
            if let name = speaker.resolvedName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                originals[speaker.id] = name
            }
        }
        for (id, rawName) in assignments {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            renames["Speaker \(id)"] = name
            if let original = originals[id],
               original.caseInsensitiveCompare(name) != .orderedSame {
                renames[original] = name
            }
        }
        return renames
    }

    private func enqueueSummaryAfterSpeakerReview(url: URL) {
        if let item = store.items.first(where: { $0.url == url })
            ?? store.items.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
            if item.summaryReadyURL != nil || !(item.meta.note ?? "").isEmpty { return }
            summaryService.enqueueIfPolicyAllows(item, trigger: .speakerReviewCompleted)
        } else {
            AppLog.log("Speaker review done but summary not enqueued — transcript not in store: \(url.lastPathComponent)", category: "record")
        }
    }

    /// Marks a transcript processed after a successful Claude run: moves it into
    /// `Processed/`, stamps its frontmatter (`status: processed`, `note: <path>`),
    /// and points `lastTranscriptURL` at the new processed location. (WS3 calls this.)
    func markProcessed(transcriptURL: URL, notePath: String) {
        guard let item = store.items.first(where: { $0.url == transcriptURL })
            ?? store.items.first(where: { $0.url.lastPathComponent == transcriptURL.lastPathComponent }) else {
            // Not in the store (e.g. just-written, not yet refreshed): synthesize an item.
            let meta = TranscriptWriter.parseFrontmatter(transcriptURL)
                ?? TranscriptMeta(title: transcriptURL.deletingPathExtension().lastPathComponent,
                                  date: Date(), attendees: [], filing: "", status: "unprocessed",
                                  note: nil, audio: nil, type: "recording")
            let synthetic = TranscriptItem(url: transcriptURL, meta: meta, isProcessed: false)
            let moved = store.moveToProcessed(synthetic, notePath: notePath)
            if lastTranscriptURL == transcriptURL { lastTranscriptURL = moved }
            return
        }
        let moved = store.moveToProcessed(item, notePath: notePath)
        if lastTranscriptURL == transcriptURL { lastTranscriptURL = moved }
    }

    /// Quit path. `applicationWillTerminate` cannot await, so everything here is a
    /// bounded synchronous wait: give CoreAudio a few seconds, then let quit proceed.
    /// The trade is deliberate — a truncated archive tail (and an aggregate device the
    /// next launch sweeps up) beats a quit that hangs indefinitely on `coreaudiod`.
    ///
    /// Two cases, and both need covering: quitting while still recording (the captures
    /// are live, so `stopBlocking` does the work), and quitting just after a stop, where
    /// `stop()` has already cleared the captures and teardown is in flight — the calls
    /// below no-op and `captureTeardown` is what there is to wait on.
    func teardownForQuit() {
        micCapture?.stopBlocking()
        systemCapture?.stopBlocking()
        if let captureTeardown {
            Self.drainOnQuit(captureTeardown)
            self.captureTeardown = nil
        }
    }

    /// Blocks the calling thread until `task` finishes or `timeout` elapses. Safe only
    /// because `captureTeardown` is a *detached* task: a main-actor task would need the
    /// thread we are blocking here in order to make progress.
    private static func drainOnQuit(_ task: Task<Void, Never>, timeout: TimeInterval = 5) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await task.value
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            AppLog.log(
                "quit: capture teardown still running after \(Int(timeout))s — quitting without flushing the tail",
                category: "audio"
            )
        }
    }

    // MARK: Helpers

    private var isErrorState: Bool {
        if case .error = live.state { return true }
        return false
    }

    private func captureTarget() -> SystemCaptureTarget {
        switch settings.captureMode {
        case .systemWide:
            return .global
        case .perApp:
            if let pid = selectedAppPID { return .app(pid: pid) }
            return .global   // no app chosen → fall back to system-wide
        }
    }

    private static func sessionStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}
