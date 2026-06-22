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
/// their ring buffers, the shared clock, the model, the two transcription
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
        notes.$state.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.armClearIfReady() }
            .store(in: &cancellables)
        $pendingSpeakerReview.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.armClearIfReady() }
            .store(in: &cancellables)
    }

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var segments: [Segment] = []

    // Session metadata (fed to the transcript + the Claude prompt).
    @Published var meetingTitle = ""
    /// Vault-relative folder the note should be filed under, e.g. "Internal/Customers/Vanguard".
    @Published var destinationPath = ""
    @Published var attendees = ""
    /// Chosen app for per-app capture (when capture mode is `.perApp`).
    @Published var selectedAppPID: pid_t?
    /// Status of the last finalize (transcript write / Claude run), for the UI.
    @Published private(set) var lastResult: String?
    /// When the current recording started (nil when not recording) — drives the live timer.
    @Published private(set) var recordingStarted: Date?
    /// URL of the most recently written transcript (for "Reveal in Finder").
    @Published private(set) var lastTranscriptURL: URL?
    /// Live capture levels (0…1) for the meters, while recording.
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var remoteLevel: Float = 0

    /// Permission state surfaced after launch warmup, so the UI can show a
    /// persistent "fix this" banner instead of only failing at record time.
    /// `nil` = not yet determined.
    @Published private(set) var micDenied = false
    @Published private(set) var systemAudioAvailable: Bool?

    /// Crashed sessions found at launch, offered in the Recovery sheet.
    @Published private(set) var pendingRecoveries: [RecoverableSession] = []
    /// True while a recover-by-re-transcribe is running (UI feedback).
    @Published private(set) var isRecovering = false

    /// Manual notes jotted during a recording; merged into the saved transcript.
    @Published var manualNotes: String = ""

    // Meeting-metadata discovery (Accessibility) — suggestions for the fields above.
    /// Roster discovered for the current/last call; the UI offers these as chips
    /// (never auto-added to `attendees` — conference-room entries etc. are the
    /// user's call). Kept after stop so chips remain usable while assigning speakers.
    @Published private(set) var suggestedAttendees: [SuggestedAttendee] = []
    /// Title discovered via AX. Auto-applied only while the user hasn't edited
    /// the field; otherwise surfaced as an accept chip.
    @Published private(set) var discoveredTitle: String?
    private var discoveredTitleSource: String?
    /// Where the current title came from (persisted in the session manifest).
    private(set) var titleSource: String?
    /// Set on focused typing in the Title field; blocks auto-fill from then on.
    private var titleWasUserEdited = false

    /// After a FluidAudio recording stops, the discovered speakers offered for naming
    /// in the "Assign speakers" sheet (nil when there's nothing to review).
    @Published var pendingSpeakerReview: SpeakerReview?

    /// `true` when the pending review should auto-present itself (the History
    /// "Detect speakers" flow), as opposed to the live at-stop flow, which is
    /// opt-in via a footer button. Hosted at the always-mounted window root so the
    /// review survives switching tabs / notes instead of being torn down with the
    /// History view (which used to silently discard it, forcing a full re-run).
    @Published var autoPresentSpeakerReview = false

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
    private var cancellables = Set<AnyCancellable>()

    /// The post-meeting work that should defer (and later re-arm) the auto-clear
    /// countdown: an open speaker-review sheet, or a running Claude summary. The
    /// offline pass no longer gates this — it runs on a background queue against an
    /// older session's data, so it must not pin the Record view (which could otherwise
    /// stay un-clearable indefinitely under a queue backlog).
    private var clearIsBusy: Bool {
        pendingSpeakerReview != nil || pendingEnrichment != nil || notes.isRunning
    }

    /// Bumped whenever a saved transcript's body is rewritten (offline pass, speaker
    /// review, add-attendee). The History/preview pane watches this to re-read the
    /// file — the URL is unchanged on a rewrite, so it wouldn't reload otherwise.
    @Published private(set) var transcriptRevision = 0

    let models = ModelManager()
    let fluidModels = FluidModelManager()
    let voiceprints = VoiceprintStore()
    let vault = VaultDirectory()
    let notes = NotesGenerator()
    let store = TranscriptStore()
    /// Holds the local MLX summary model across compare runs (download/load/unload).
    /// Drives the background Claude summary → review → commit flow.
    private(set) lazy var summaryService = SummaryService(store: store)
    /// Background offline pass (ASR + speaker detect + compaction) for finalized
    /// recordings — serialized and idle-gated so it never competes with live recording.
    private(set) lazy var offlineService = OfflineProcessingService(
        models: models, voiceprints: voiceprints, store: store, vault: vault, summaryService: summaryService)
    let callDetector = CallDetector()
    let metadataResolver = MeetingMetadataResolver()

    private let settings = AppSettings.shared

    // Capture
    private let micRing = AudioRingBuffer(capacity: 16_000 * 30)
    private let systemRing = AudioRingBuffer(capacity: 16_000 * 30)
    private var micCapture: MicCapture?
    private var systemCapture: SystemAudioCapture?
    private var clock: RecordingClock?
    private var sessionDirectory: URL?
    private var recordingStartDate: Date?
    private var meterTimer: Timer?
    private var partialTimer: Timer?
    /// Fires after a stretch of inactivity to unload the model and reclaim RAM.
    private var idleUnloadTimer: Timer?
    /// The active session's durable manifest + its heartbeat (crash recovery).
    private var manifest: SessionManifest?
    private var heartbeatTimer: Timer?
    /// Append-only confirmed-segment journal for the active session.
    private var journal: SegmentJournal?
    /// True when the current recording was auto-started by call detection (so it
    /// may be auto-stopped on call end; user-started recordings are not).
    private var startedByDetection = false

    // Transcription — the active engine (WhisperKit or FluidAudio), chosen per
    // session from settings. Owns the pipelines/service/merger (or its native
    // equivalents) and reports the merged timeline back via `onSegmentsChanged`.
    private var engine: TranscriptionEngine?

    var isRecording: Bool { state == .recording }

    /// The session currently being recorded (nil when idle) — so the Storage
    /// manager can refuse to delete the in-progress recording's audio.
    var currentSessionID: String? { isRecording ? manifest?.id : nil }

    /// Build the transcription engine for this session from settings (gated to
    /// the next recording — no mid-session switch) and wire segment publishing +
    /// the confirmed-segment journal.
    private func makeEngine() -> TranscriptionEngine {
        let engine: TranscriptionEngine
        switch settings.transcriptionEngine {
        case .whisperKit:
            // WhisperKit ASR + SpeakerKit diarization + voiceprints.
            let wsk = WhisperKitSpeakerKitEngine(models: models, settings: settings, voiceprints: voiceprints,
                                                 identificationThreshold: settings.identificationThreshold)
            wsk.onSpeakerIdentified = { [weak self] name in self?.addAttendeeIfAbsent(name) }
            engine = wsk
        case .fluidAudio:
            let fluid = FluidAudioEngine(settings: settings, voiceprints: voiceprints,
                                         identificationThreshold: settings.identificationThreshold)
            // Auto-add a recognized person to the attendees list (above threshold).
            fluid.onSpeakerIdentified = { [weak self] name in self?.addAttendeeIfAbsent(name) }
            engine = fluid
        }
        engine.onSegmentsChanged = { [weak self] merged in
            guard let self else { return }
            self.segments = merged
            // Persist confirmed segments as they land (near-zero crash loss).
            self.journal?.append(confirmed: self.engine?.confirmedTimeline() ?? [])
        }
        return engine
    }

    // MARK: Speaker naming / enrollment (FluidAudio engine)

    /// Name a diarized speaker: relabel their transcript lines, enroll or refine their
    /// voiceprint (so future sessions recognise them), and add them to attendees.
    func nameSpeaker(_ speakerId: String, as rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        // Cache-backed review (no live engine): enrol the voiceprint from the persisted
        // centroid and record the assignment — the transcript is relabeled on Done.
        if let review = pendingSpeakerReview, let cache = review.cache {
            if let c = cache.speakers.first(where: { $0.id == speakerId })?.centroid, !c.isEmpty {
                enrollVoiceprint(name: name, centroid: c, model: cache.embeddingModelID)
            } else {
                AppLog.log("Named speaker \(speakerId) as \(name) (cache) — no centroid, labeled only", category: "record")
            }
            pendingSpeakerReview?.assignments[speakerId] = name
            pendingSpeakerReview?.attendees = OfflineProcessingService.merge(review.attendees, with: [name])
            return
        }

        // Prefer the review's own engine (History "Detect speakers" runs on a transient
        // engine via the offline queue); fall back to the live engine for any other path.
        guard let eng = pendingSpeakerReview?.engine ?? (engine as? SpeakerCapableEngine) else { return }
        let model = eng.embeddingModelId
        if let centroid = eng.setSpeakerName(speakerId, as: name) {
            let vpId = enrollVoiceprint(name: name, centroid: centroid, model: model)
            // Retain a short enrollment clip for re-enrollment, AND cross-enroll the
            // OTHER engine's space from that same clip so naming a person once makes
            // them recognisable on both engines (off-main, best-effort).
            Task { [weak self] in
                guard let self, let audio = await eng.repAudioSample(for: speakerId) else { return }
                self.voiceprints.attachAudioSample(to: vpId, samples: audio)
                await self.crossEnroll(name: name, clip: audio, activeModel: model)
            }
        } else {
            AppLog.log("Named speaker \(speakerId) as \(name) but not enough clean audio — labeled, not enrolled", category: "record")
        }
        // Add to the right attendee target: the review's own snapshot (queued/History
        // flow), or the live Record field when naming during a live session.
        if pendingSpeakerReview != nil {
            pendingSpeakerReview?.attendees = OfflineProcessingService.merge(
                pendingSpeakerReview?.attendees ?? "", with: [name])
        } else {
            addAttendeeIfAbsent(name)
        }
    }

    /// Enrol (or refine) a voiceprint for `name` from a centroid embedding, keyed by the
    /// embedding model. Returns the voiceprint id. Shared by the live-engine and
    /// cache-backed naming paths.
    @discardableResult
    private func enrollVoiceprint(name: String, centroid: [Float], model: String) -> UUID {
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


    private func crossEnroll(name: String, clip: [Float], activeModel: String) async {
        let targetModel = activeModel == VoiceprintStore.embeddingModel
            ? VoiceprintStore.speakerKitEmbeddingModel    // active FluidAudio → add pyannote
            : VoiceprintStore.embeddingModel              // active WhisperKit → add wespeaker
        guard !voiceprints.voiceprints.contains(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.embeddingModel == targetModel
        }) else { return }

        let embedding: [Float]?
        switch targetModel {
        case VoiceprintStore.embeddingModel:
            embedding = await FluidAudioEngine.embeddings(
                forClip: clip, clusterThreshold: Float(settings.diarizationThreshold))?.first
        case VoiceprintStore.speakerKitEmbeddingModel:
            let diarizer = SpeakerKitDiarizer()
            embedding = await diarizer.embedding(forClip: clip)
            await diarizer.unload()
        default:
            embedding = nil
        }
        guard let embedding, !embedding.isEmpty else {
            AppLog.log("Cross-enroll \(name) → \(targetModel): no embedding derived", category: "record")
            return
        }
        _ = voiceprints.enroll(name: name, embedding: embedding, model: targetModel)
        AppLog.log("Cross-enrolled \(name) into \(targetModel) space from rep clip", category: "record")
    }

    /// Append a name to the comma-separated attendees list if not already present.
    private func addAttendeeIfAbsent(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let current = TranscriptWriter.splitAttendees(attendees)
        guard !current.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        attendees = current.isEmpty ? name : attendees + ", " + name
    }

    // MARK: Meeting-metadata discovery (title/attendee suggestions)

    private func resetDiscovery() {
        suggestedAttendees = []
        discoveredTitle = nil
        discoveredTitleSource = nil
        titleSource = nil
        titleWasUserEdited = false
    }

    /// Titles the app set itself ("Teams call", "Recorded call", empty) — safe
    /// to replace with a discovered one. Anything the user typed is protected
    /// separately by `titleWasUserEdited`.
    private func isDefaultTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == "Recorded call" || t.hasSuffix(" call")
    }

    /// Union a roster snapshot into the suggestions, stamping `firstSeen` (the
    /// join timestamp) only on first sighting; entries never disappear (someone
    /// leaving the call keeps their chip).
    private func mergeRoster(_ roster: [RosterEntry]) {
        for entry in roster {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let idx = suggestedAttendees.firstIndex(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                if suggestedAttendees[idx].role == nil, let role = entry.role {
                    suggestedAttendees[idx].role = role
                }
            } else {
                AppLog.log("Roster: \(name)\(entry.role.map { " (\($0))" } ?? "") joined", category: "detect")
                suggestedAttendees.append(SuggestedAttendee(name: name, role: entry.role, firstSeen: Date()))
            }
        }
    }

    /// Called by the Title field on focused (user) edits — from then on,
    /// discovery offers instead of overwriting.
    func userEditedTitle() {
        titleWasUserEdited = true
        titleSource = "user"
    }

    /// The title accept-chip action (shown when discovery found a title after
    /// the user had already edited the field).
    func acceptDiscoveredTitle() {
        guard let title = discoveredTitle else { return }
        meetingTitle = title
        titleSource = discoveredTitleSource
        scheduleMetadataSync()
    }

    func acceptSuggestion(_ name: String) {
        guard let idx = suggestedAttendees.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { return }
        suggestedAttendees[idx].accepted = true
        suggestedAttendees[idx].dismissed = false
        addAttendeeIfAbsent(suggestedAttendees[idx].name)
        scheduleMetadataSync()
    }

    func acceptAllSuggestions() {
        for s in suggestedAttendees where !s.accepted && !s.dismissed {
            acceptSuggestion(s.name)
        }
    }

    func dismissSuggestion(_ name: String) {
        guard let idx = suggestedAttendees.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { return }
        suggestedAttendees[idx].dismissed = true
    }

    private var didWarmup = false

    /// One-time launch warmup: surface both permission prompts together up front
    /// and load the model in the background, so the first recording neither
    /// prompts nor waits.
    func launchWarmup() {
        guard !didWarmup else { return }
        didWarmup = true
        let engineDesc = settings.transcriptionEngine == .fluidAudio
            ? "FluidAudio (Parakeet \(settings.parakeetVersion.rawValue))"
            : "WhisperKit (\(settings.model.rawValue))"
        AppLog.log("Launch warmup — engine=\(engineDesc), \(MemoryGuard.snapshot()), logs at \(AppLog.fileURL.path)", category: "app")
        VaultMigration.runIfNeeded(vault: settings.vaultURL)
        SystemAudioCapture.cleanupLeakedAggregates()    // destroy any aggregate device a crash left behind
        ModelManager.recoverFromCrashedLoadIfNeeded()   // self-heal a corrupt compiled-model cache
        gatherRecoveries()        // crashed sessions (with a manifest) → Recovery sheet
        recoverOrphanedPartials() // legacy crashed sessions (no manifest) → auto-salvage
        vault.refresh()
        store.refresh()
        wireBackgroundQueues()    // offline + summary services gate on idle, host reviews
        offlineService.enqueuePendingFromDisk()   // resume offline passes interrupted by a quit/crash
        summaryService.enqueuePendingFromDisk()   // resume queued summaries (bulk-confirmed, not a burst)
        preloadModel()
        scheduleIdleUnload()   // if nothing happens for a while, free the model's RAM
        startCallDetection()
        Task {
            let micGranted = await PermissionManager.requestMicrophone()          // mic prompt
            micDenied = !micGranted
            // audio prompt — off-main, can block until the user answers; the
            // result tells us whether system-audio capture/detection is usable.
            let audioOK = await Task.detached { SystemAudioCapture.primeAudioCapturePermission() }.value
            systemAudioAvailable = audioOK
            if !audioOK {
                AppLog.log("System-audio capture unavailable after prime — remote-track capture and call detection by mic-signal may not work until the audio-recording permission is granted", category: "audio")
            }
        }
    }

    /// Wire the offline + summary queues to the controller: both gate on "idle" (no
    /// live recording) so live recording always wins, and the offline queue hands any
    /// History "Detect speakers" review back to the controller to host the sheet.
    private func wireBackgroundQueues() {
        let idle: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.state == .idle && !self.isRecording
        }
        offlineService.isIdle = idle
        summaryService.isIdle = idle
        offlineService.presentReview = { [weak self] review in self?.presentQueuedReview(review) }
        summaryService.onSessionAudioDeleted = { [weak self] dir in self?.offlineService.cancel(sessionDir: dir) }
    }

    /// Host a speaker-review produced by the offline queue (History "Detect speakers").
    private func presentQueuedReview(_ review: SpeakerReview) {
        pendingSpeakerReview = review
        autoPresentSpeakerReview = true
    }

    /// Starts background call detection. This increment is detection + logging
    /// only: the callbacks log the decision the next increment will act on
    /// (auto-record / notify). No recording is started/stopped yet.
    private func startCallDetection() {
        guard settings.callDetectionEnabled else {
            AppLog.log("Call detection disabled in settings", category: "detect")
            return
        }
        metadataResolver.onUpdate = { [weak self] meta in
            guard let self else { return }
            if let title = meta.title {
                self.discoveredTitle = title
                self.discoveredTitleSource = meta.titleSource
                // Auto-fill only while the title is still an untouched default;
                // after a manual edit, the chip UI offers it instead.
                if !self.titleWasUserEdited, self.isDefaultTitle(self.meetingTitle) {
                    AppLog.log("Discovered title (\(meta.titleSource ?? "?")): \(title)", category: "detect")
                    self.meetingTitle = title
                    self.titleSource = meta.titleSource
                    self.scheduleMetadataSync()
                }
            }
            self.mergeRoster(meta.roster)
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
            self.preloadModel()
            // New call context: reset the last call's discoveries, start fresh.
            self.resetDiscovery()
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
                self.meetingTitle = "\(call.displayName) call"   // sensible default; user can edit
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

    /// Loads (and on first run downloads) the model in the background so the
    /// first Start is instant instead of paying cold-start latency at record time.
    /// Engine-aware: only the WhisperKit path uses `ModelManager`; the FluidAudio
    /// engine loads its own model at record time (we just check presence here).
    func preloadModel() {
        switch settings.transcriptionEngine {
        case .whisperKit:
            Task { _ = await models.prepare(settings.model) }
        case .fluidAudio:
            fluidModels.refreshPresence()
        }
    }

    // MARK: Start / stop

    func start(detectionInitiated: Bool = false) async {
        guard state == .idle || isErrorState else { return }
        cancelIdleUnload()
        startedByDetection = detectionInitiated
        if detectionInitiated, meetingTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            meetingTitle = "Recorded call"   // fallback for the notification-Start path
        }
        state = .preparing
        cancelPendingClear(); clearArmable = false   // a new recording supersedes any pending auto-clear
        segments = []
        lastResult = nil
        lastTranscriptURL = nil
        manualNotes = ""
        // Discovery context: a detected call already reset + started the
        // resolver in onCallStart, and its pre-record findings (title, early
        // roster) belong to this session — keep them. Only a pure manual start
        // clears leftovers from the previous session.
        if let call = callDetector.activeCall {
            if !metadataResolver.isPolling { metadataResolver.start(for: call) }
        } else {
            resetDiscovery()
            metadataResolver.stop()
        }
        engine = makeEngine()

        guard await PermissionManager.requestMicrophone() else {
            micDenied = true
            state = .error("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
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

        launchCapture(sessionDir: sessionDir,
                      micArchive: sessionDir.appendingPathComponent("mic.caf"),
                      systemArchive: sessionDir.appendingPathComponent("system.caf"),
                      startOffset: 0, reactivate: false)
    }

    /// Continue a crashed session into the SAME note: restore its metadata, reload
    /// the journaled segments, mark the interruption, and capture fresh audio
    /// timed after the prior recording. Finalizes into one combined transcript.
    func resume(_ session: RecoverableSession) async {
        guard state == .idle || isErrorState else { return }
        cancelIdleUnload()
        let m = session.manifest
        startedByDetection = false          // user-driven resume → manual stop
        state = .preparing
        cancelPendingClear(); clearArmable = false   // a resumed recording supersedes any pending auto-clear
        meetingTitle = m.title
        attendees = m.attendees
        destinationPath = m.filing
        manualNotes = m.manualNotes
        lastResult = nil
        lastTranscriptURL = nil
        engine = makeEngine()

        guard await PermissionManager.requestMicrophone() else {
            micDenied = true
            state = .error("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
            return
        }
        micDenied = false

        let dir = session.dir
        sessionDirectory = dir

        // Reload prior confirmed segments; seed them (shown + finalized) and mark
        // the gap. New audio is timed to start where the prior recording ended.
        let journalURL = dir.appendingPathComponent("segments.jsonl")
        let prior = SegmentJournal.read(journalURL)
        let offset = max(session.durationSeconds, prior.map(\.end).max() ?? 0)
        let marker = Segment(track: .me, start: offset, end: offset,
                             text: "— recording resumed after interruption —", confirmed: true)
        engine?.seed(prior + [marker])
        journal = SegmentJournal(url: journalURL, alreadyWritten: Set(prior.map(\.id)))
        journal?.append(confirmed: [marker])

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
        let system = SystemAudioCapture(ringBuffer: systemRing, archiveURL: systemArchive)
        let clock = RecordingClock()
        self.clock = clock
        recordingStartDate = Date()
        recordingStarted = recordingStartDate

        do {
            try mic.start()
            try system.start(target: captureTarget())
            micCapture = mic
            systemCapture = system
            AppLog.log("Capture started (model loads in parallel) — mode=\(settings.captureMode.rawValue), model=\(settings.model.rawValue), offset=\(Int(startOffset))s", category: "record")
        } catch {
            mic.stop()
            system.stop()
            AppLog.log("Capture failed to start: \(error.localizedDescription)", category: "record")
            state = .error(error.localizedDescription)
            startedByDetection = false
            return
        }

        // Hand the capture rings to the active engine, anchored to the shared
        // timeline (0 for a fresh start, or the prior duration when resuming). The
        // engine loads its model in the background and holds audio until ready.
        // Speaker-capable engines build a clean mixed file from the archived tracks at
        // stop (for the offline diarization + play-sample + retained clips).
        if let eng = engine as? SpeakerCapableEngine {
            eng.mixedAudioURL = sessionDir.appendingPathComponent("mixed.caf")
            eng.micArchiveURL = micArchive
            eng.systemArchiveURL = systemArchive
        }
        engine?.start(micRing: micRing, systemRing: systemRing, startElapsed: startOffset)

        startMeterTimer()
        startPartialTimer()
        if reactivate { reactivateSessionManifest(dir: sessionDir) }
        else { beginSessionManifest(dir: sessionDir) }
        state = .recording
    }

    /// Next free audio-segment index in a session dir (resume writes mic.2.caf, …).
    private func nextAudioIndex(in dir: URL) -> Int {
        var idx = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.\(idx).caf").path) { idx += 1 }
        return idx
    }

    // MARK: Meters + crash-recovery autosave

    private func startMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.micLevel = self.micCapture?.level ?? 0
                self.remoteLevel = self.systemCapture?.level ?? 0
            }
        }
    }

    private func startPartialTimer() {
        partialTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writePartial() }
        }
    }

    private func stopTimers() {
        meterTimer?.invalidate(); meterTimer = nil
        partialTimer?.invalidate(); partialTimer = nil
        micLevel = 0; remoteLevel = 0
    }

    /// Periodically dumps the confirmed transcript to a `.partial` file so a
    /// crash mid-recording can be recovered on next launch.
    private func writePartial() {
        guard let dir = sessionDirectory else { return }
        let segments = engine?.finalTimeline() ?? []
        guard !segments.isEmpty else { return }
        let body = TranscriptWriter.makeBody(
            title: meetingTitle.isEmpty ? "Recovered recording" : meetingTitle,
            date: recordingStartDate ?? Date(), attendees: attendees,
            destination: destinationPath, segments: segments)
        try? body.write(to: dir.appendingPathComponent("transcript.partial.md"), atomically: true, encoding: .utf8)
    }

    private func partialURL() -> URL? {
        sessionDirectory?.appendingPathComponent("transcript.partial.md")
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
        guard state == .recording else { return }
        state = .stopping
        recordingStarted = nil
        startedByDetection = false
        stopTimers()
        // Freeze discovery; suggestions stay for the preview/speaker-assignment UI.
        metadataResolver.enterPreviewMode()

        micCapture?.stop()
        systemCapture?.stop()
        micCapture = nil
        systemCapture = nil

        // Tear down the engine off the main actor; finalize() reads the
        // already-populated timeline synchronously, so it needn't wait on this. The
        // offline pass (ASR re-pass + speaker detect + compaction) is NOT run here
        // anymore — finalize() enqueues it on the idle-gated offline queue, so a new
        // recording starting immediately can never be blocked by, or corrupted by, the
        // previous call's offline work.
        let engine = self.engine
        Task { await engine?.stop() }
        clock = nil

        finalize()
    }

    /// Writes the transcript to the vault and, if enabled, runs Claude to
    /// produce the polished note. Runs off the main thread; never blocks quit.
    private func finalize() {
        // Include the trailing unconfirmed tail — on stop it's final.
        let segments = engine?.finalTimeline() ?? []
        AppLog.log("Recording stopped — \(segments.count) segments (confirmed + tail)", category: "record")
        // Always save (even with no speech) so a recorded call is never lost and
        // its audio stays linked in History — rather than silently discarded.

        // Write new destination/attendees back to the vault so they're indexed next time.
        if !destinationPath.isEmpty { vault.ensureDestination(destinationPath) }
        let attendeeNames = attendees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        vault.addPeople(attendeeNames)

        let date = recordingStartDate ?? Date()
        let folder = AppPaths.unprocessedURL
        let title = meetingTitle
        let destination = destinationPath
        let attendees = self.attendees
        let manual = manualNotes
        // Snapshot session identity into LOCALS before the async Task, so a new recording
        // starting immediately (which reassigns `sessionDirectory`/`engine`) can never
        // redirect this session's offline job — the root cause of the data-loss bug.
        let sessionDir = sessionDirectory
        let isSpeakerEngine = engine is SpeakerCapableEngine
        let autoSummarize = settings.autoRunClaude
        // Link to the session audio (mic track) if it was archived.
        let audioPath = sessionDir.map { $0.appendingPathComponent("mic.caf").path }

        // DURABILITY: stop the heartbeat timer NOW so no further `.active` stamps can
        // land after the user stopped. The actual `.finalized` stamp is written inside
        // the Task's SUCCESS path (below) — so a crash between here and the transcript
        // write leaves the manifest `.active`, which the Recovery sheet catches.
        stopHeartbeat()

        Task {
            do {
                let result = try TranscriptWriter.write(
                    title: title, date: date, attendees: attendees, destination: destination,
                    segments: segments,
                    manualNotes: manual.isEmpty ? nil : manual,
                    audioPath: audioPath,
                    folderURL: folder
                )
                AppLog.log("Transcript written: \(result.url.path)\(segments.isEmpty ? " (no speech — saved for the record + audio link)" : "")", category: "record")
                if let p = partialURL() { try? FileManager.default.removeItem(at: p) }   // clean recovery files
                if let dir = sessionDir {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("segments.jsonl"))
                }
                lastTranscriptURL = result.url
                lastResult = segments.isEmpty
                    ? "Saved (no speech transcribed): \(result.url.lastPathComponent)"
                    : "Transcript saved: \(result.url.lastPathComponent)"
                notes.reset()
                store.refresh()
                // B: offer a one-time enrichment sheet for attendees with no known
                // company. On the non-speaker path this also defers the summary so
                // E-annotation reflects whatever the user fills in. On the speaker path
                // it is best-effort rolodex enrichment only (the summary is queued via
                // the offline service independently).
                let destinationLeaf = destination.split(separator: "/").last.map(String.init) ?? ""
                let enrichRows = enrichmentRows(forAttendees: attendeeNames)
                if !enrichRows.isEmpty {
                    let runSummary = autoSummarize && !segments.isEmpty && !isSpeakerEngine
                    pendingEnrichment = AttendeeEnrichment(
                        rows: enrichRows,
                        transcriptURL: result.url,
                        destinationDefault: destinationLeaf,
                        runSummaryOnFinish: runSummary)
                    autoPresentEnrichment = true
                    // Non-speaker summary is deferred to finishEnrichment(); speaker path
                    // does not summarize here regardless.
                } else {
                    // No unenriched attendees: preserve today's behavior exactly.
                    if autoSummarize && !segments.isEmpty && !isSpeakerEngine {
                        maybeAutoRunClaude()
                    }
                }
                // Transcript write succeeded — stamp the manifest finalized NOW, before
                // the offline enqueue. `setOfflineStatus` does a read-modify-write on the
                // manifest, so the `.finalized` stamp must be on disk first.
                stampFinalizedManifest()
                // Hand the finalized session to the idle-gated offline queue: ASR re-pass
                // + speaker detect + compaction, run when nothing is recording. The job is
                // a self-contained snapshot, so it's safe even if a new recording starts.
                if isSpeakerEngine, let dir = sessionDir, !segments.isEmpty {
                    SessionStore.setOfflineStatus(.pending, attempts: 0, transcriptPath: result.url.path,
                                                  presentReviewWhenDone: false, in: dir)
                    offlineService.enqueue(OfflineJob(
                        sessionDir: dir, transcriptURL: result.url, title: title,
                        attendees: attendees, filing: destination,
                        presentReviewWhenDone: false, autoSummarize: autoSummarize))
                    offlineService.runNextIfIdle()
                }
                // The transcript is on disk — the Record view is settled and eligible for
                // auto-clear regardless of engine (the offline pass is decoupled now and
                // runs on a background queue against the saved file).
                clearArmable = true
                armClearIfReady()
            } catch {
                // Write failed — leave the manifest `.active` (heartbeat is already stopped,
                // so no spurious heartbeat will overwrite state) so the Recovery sheet catches
                // this session on next launch. Do NOT stamp `.finalized` here.
                AppLog.log("Finalize failed: \(error.localizedDescription)", category: "record")
                lastResult = "Finalize failed: \(error.localizedDescription)"
            }
        }

        state = .idle
        // Now idle again — drain any work that was waiting for a live recording to end.
        offlineService.runNextIfIdle()
        summaryService.runNextIfIdle()
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
        let engine: SpeakerCapableEngine?
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
        let cache: SpeakerCache?
        let sessionDir: URL?
        /// speakerId → assigned name, accumulated during a cache-backed review.
        var assignments: [String: String] = [:]

        init(speakers: [CallSpeakerSummary], mixedCaf: URL?,
             engine: SpeakerCapableEngine? = nil, transcriptURL: URL? = nil,
             title: String = "", filing: String = "", attendees: String = "", autoSummarize: Bool = false,
             cache: SpeakerCache? = nil, sessionDir: URL? = nil) {
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
        }
    }

    /// Open the assign-speakers review for a History note. Prefers the persisted speaker
    /// cache (instant — no re-run); falls back to re-running the offline pass only when no
    /// cache exists (older recordings) or its audio is gone.
    func assignSpeakers(forAudioPath audioPath: String?, transcript: URL,
                        attendees: String, title: String, filing: String) {
        guard let audioPath, !audioPath.isEmpty else {
            lastResult = "No saved audio for this recording — can't detect speakers."; return
        }
        let dir = URL(fileURLWithPath: audioPath).deletingLastPathComponent()
        let mixed = dir.appendingPathComponent("mixed.caf")
        if let cache = SpeakerCache.read(dir),
           !cache.speakers.isEmpty,
           FileManager.default.fileExists(atPath: mixed.path) {
            let summaries = cache.speakers.map {
                CallSpeakerSummary(id: $0.id, resolvedName: $0.resolvedName, talkSeconds: $0.talkSeconds,
                                   sampleStart: $0.sampleStart, sampleEnd: $0.sampleEnd, firstLine: $0.firstLine)
            }
            pendingSpeakerReview = SpeakerReview(
                speakers: summaries, mixedCaf: mixed, engine: nil, transcriptURL: transcript,
                title: title, filing: filing, attendees: attendees,
                autoSummarize: settings.autoRunClaude, cache: cache, sessionDir: dir)
            autoPresentSpeakerReview = true
            AppLog.log("Assign speakers from cache (\(cache.speakers.count)) — \(transcript.lastPathComponent)", category: "record")
        } else {
            // No cache (or audio gone) → fall back to a full re-run that opens the review.
            reprocessSpeakers(forAudioPath: audioPath, transcript: transcript,
                              attendees: attendees, title: title, filing: filing)
        }
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
        SessionStore.setOfflineStatus(.pending, attempts: 0, transcriptPath: transcript.path,
                                      presentReviewWhenDone: true, in: dir)
        offlineService.enqueue(OfflineJob(
            sessionDir: dir, transcriptURL: transcript, title: title,
            attendees: attendees, filing: filing,
            presentReviewWhenDone: true, autoSummarize: false))
        offlineService.runNextIfIdle()
        lastResult = isRecording
            ? "Speaker detection queued — runs when the current recording stops."
            : "Detecting speakers…"
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

    /// Replace (or insert after the Date line) the body "**Attendees:**" header so it
    /// matches the frontmatter list.
    private static func replaceAttendeeHeader(in text: String, with names: [String]) -> String {
        guard !names.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
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
    /// live Record session.
    func finishSpeakerReview() {
        let review = pendingSpeakerReview
        pendingSpeakerReview = nil
        autoPresentSpeakerReview = false

        if let review, review.cache != nil, let url = review.transcriptURL {
            // Cache-backed: relabel the transcript by substituting "Speaker N" → name
            // (no engine, no re-run). Voiceprints were already enrolled in nameSpeaker.
            if !review.assignments.isEmpty,
               let body = try? String(contentsOf: url, encoding: .utf8) {
                let relabeled = SpeakerCache.relabel(body, assignments: review.assignments)
                if relabeled != body { try? relabeled.write(to: url, atomically: true, encoding: .utf8) }
            }
            TranscriptWriter.updateFrontmatter(at: url) {
                $0.attendees = TranscriptWriter.splitAttendees(review.attendees)
            }
            vault.addPeople(TranscriptWriter.splitAttendees(review.attendees))
            store.refresh()
            transcriptRevision += 1
            AppLog.log("Assigned speakers from cache: \(url.lastPathComponent)", category: "record")
            if !TranscriptStore.bodyHasGenericLabels(at: url),
               let item = store.items.first(where: { $0.url == url })
                ?? store.items.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
                summaryService.enqueueIfPolicyAllows(item, trigger: .speakerReviewCompleted)
            }
        } else if let review, let url = review.transcriptURL, let eng = review.engine {
            let segs = eng.finalTimeline()
            let audioDuration = SessionStore.audioDuration(url.deletingLastPathComponent()
                .appendingPathComponent("mic.caf"))
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
            // Becoming fully-named is the moment a note is summary-ready — enqueue it
            // (policy-gated), unless generic labels remain after a coverage-kept rewrite.
            if !TranscriptStore.bodyHasGenericLabels(at: url),
               let item = store.items.first(where: { $0.url == url })
                ?? store.items.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
                summaryService.enqueueIfPolicyAllows(item, trigger: .speakerReviewCompleted)
            }
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
        offlineService.runNextIfIdle()
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
    func finishEnrichment(save: Bool) {
        let e = pendingEnrichment
        pendingEnrichment = nil
        autoPresentEnrichment = false
        if save {
            for row in e?.rows ?? [] where !row.company.trimmingCharacters(in: .whitespaces).isEmpty {
                vault.upsertPerson(
                    name: row.name,
                    title: row.title,
                    company: row.company,
                    linkedin: row.linkedin)
            }
        }
        // Always fire the deferred summary (if any) — Skip must not lose the summary.
        if e?.runSummaryOnFinish == true { maybeAutoRunClaude(forTranscriptURL: e?.transcriptURL) }
        armClearIfReady()
    }

    /// Record that `detected` (e.g. a Teams display name) is an alias for an existing
    /// canonical contact. Writes the alias line to the rolodex, then removes the
    /// enrichment row whose name equals `detected` -- the person is now known, so no
    /// manual company fill is needed. If that empties the row set, finishes enrichment
    /// (saving any remaining filled rows) so the deferred summary fires correctly.
    func linkAttendeeToExisting(detected: String, canonicalName: String) {
        vault.addAlias(detected, toCanonical: canonicalName)
        guard pendingEnrichment != nil else { return }
        pendingEnrichment!.rows.removeAll { $0.name == detected }
        if pendingEnrichment!.rows.isEmpty {
            finishEnrichment(save: true)
        }
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
        guard state == .idle else { return }
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
        guard token == clearToken, state == .idle else { return }
        clearTimer?.invalidate(); clearTimer = nil
        pendingClear = nil
        segments = []
        meetingTitle = ""
        attendees = ""
        destinationPath = ""
        manualNotes = ""
        lastResult = nil
        lastTranscriptURL = nil
        autoPresentSpeakerReview = false
        clearArmable = false
        resetDiscovery()
        notes.reset()
        AppLog.log("Auto-cleared Record view for the next meeting", category: "record")
    }

    /// Queue a background Claude summary for the just-saved recording, if auto-summarize
    /// is on. Reads the current transcript (post-attribution) from the store so the summary
    /// reflects assigned speakers + attendees. The result is staged for review in History.
    /// Enqueue the auto-summary for a finalized transcript. `targetURL` lets a DEFERRED
    /// caller (the enrichment sheet, which may be dismissed only after a new recording
    /// has re-pointed `lastTranscriptURL`) pin the summary to the correct session rather
    /// than whatever is live now. Note: both shipping live engines are speaker-capable,
    /// so the deferred branch is currently inert; the guard is defensive for that path.
    private func maybeAutoRunClaude(forTranscriptURL targetURL: URL? = nil) {
        guard settings.autoRunClaude, let url = targetURL ?? lastTranscriptURL else { return }
        // The live (non-deferred) path requires a non-empty timeline; a deferred call
        // targets a file already saved to disk, so it skips the live-engine check.
        if targetURL == nil {
            guard !(engine?.finalTimeline() ?? segments).isEmpty else { return }
        }
        store.refresh()
        guard let item = store.items.first(where: { $0.url == url })
            ?? store.items.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) else { return }
        summaryService.enqueueIfPolicyAllows(item, trigger: .freshRecording)
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
        let liveTitle = meetingTitle.trimmingCharacters(in: .whitespaces)
        if !liveTitle.isEmpty { meta.title = liveTitle }
        let liveDest = destinationPath.trimmingCharacters(in: .whitespaces)
        if !liveDest.isEmpty { meta.filing = liveDest }
        meta.attendees = TranscriptWriter.splitAttendees(attendees)

        let segs = engine?.finalTimeline() ?? segments
        if segs.isEmpty {
            // No transcript body to regenerate (e.g. metadata-only edit) — just re-stamp.
            TranscriptWriter.updateFrontmatter(at: url) { m in
                m.title = meta.title; m.filing = meta.filing; m.attendees = meta.attendees
            }
        } else {
            let body = TranscriptWriter.makeBody(
                title: meta.title, date: meta.date, attendees: attendees, destination: meta.filing,
                segments: segs, manualNotes: manualNotes.isEmpty ? nil : manualNotes, meta: meta)
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
        vault.addPeople(TranscriptWriter.splitAttendees(attendees))
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
            self?.rewriteLastTranscript(reason: "edited metadata")
        }
    }

    // MARK: Idle model unload

    /// Schedule unloading the model after the configured idle stretch, freeing
    /// its ~1 GB+ of resident memory. Reset whenever activity resumes. The model
    /// reloads on the next call/record while capture proceeds, so the only cost
    /// is a short catch-up at the start of that session.
    private func scheduleIdleUnload() {
        idleUnloadTimer?.invalidate(); idleUnloadTimer = nil
        // Idle-unload only applies to the persistent WhisperKit model. FluidAudio
        // loads its models per-recording and releases them on stop, so there's
        // nothing to idle-unload (and logging it would be misleading).
        guard settings.idleUnloadEnabled, settings.transcriptionEngine == .whisperKit else { return }
        let interval = max(60, settings.idleUnloadMinutes * 60)
        idleUnloadTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.idleUnloadEnabled,
                      self.state == .idle, !self.isRecording else { return }
                // Don't unload while the offline queue has work — it needs the heavier
                // batch model and would just have to reload it immediately.
                if self.offlineService.hasWork {
                    self.scheduleIdleUnload()   // re-arm; try again after another idle stretch
                    return
                }
                AppLog.log("Idle \(Int(interval / 60))min — unloading model to free memory", category: "model")
                Task { await self.models.unload() }
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
        let m = SessionManifest(
            id: dir.lastPathComponent,
            title: meetingTitle, attendees: attendees, filing: destinationPath,
            model: settings.model.rawValue, computeMode: settings.computeMode.rawValue,
            startedAt: recordingStartDate ?? Date(), lastHeartbeat: Date(),
            status: .active, startedByDetection: startedByDetection,
            callBundleID: call?.bundleID, callDisplayName: call?.displayName,
            manualNotes: manualNotes, audioTracks: ["mic.caf", "system.caf"])
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
        guard var m = manifest, let dir = sessionDirectory else { return }
        m.title = meetingTitle
        m.attendees = attendees
        m.filing = destinationPath
        m.manualNotes = manualNotes
        m.titleSource = titleSource
        m.suggestedAttendees = suggestedAttendees.isEmpty ? nil : suggestedAttendees
        m.lastHeartbeat = Date()
        m.status = status
        manifest = m
        SessionStore.write(m, to: dir)
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
    private func stampFinalizedManifest() {
        guard manifest != nil else { return }
        persistManifest(status: .finalized)
        AppLog.log("Session manifest finalized — \(manifest?.id ?? "?")", category: "record")
        manifest = nil
        journal = nil
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

    /// Finalize a crashed session into a transcript without resuming. Fast path
    /// rebuilds from the journal; `reTranscribe` re-runs the (crash-safe) audio
    /// through the model for the complete text. Idempotent: marks the manifest
    /// finalized so it won't reappear.
    func recover(_ session: RecoverableSession, reTranscribe: Bool) {
        guard state == .idle || isErrorState else { return }
        let dir = session.dir
        let m = session.manifest
        Task {
            isRecovering = reTranscribe
            let segs = reTranscribe
                ? await reTranscribeSession(dir: dir)
                : SegmentJournal.read(dir.appendingPathComponent("segments.jsonl"))
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
                AppLog.log("Recovered \(session.id) (\(reTranscribe ? "re-transcribed" : "from journal"); \(segs.count) segments) → \(result.url.lastPathComponent)", category: "record")
                store.refresh()
                // Give the recovered session the same background offline pass a normal
                // stop gets (speaker detect + attributed rewrite), when next idle.
                if !segs.isEmpty {
                    SessionStore.setOfflineStatus(.pending, attempts: 0, transcriptPath: result.url.path,
                                                  presentReviewWhenDone: false, in: dir)
                    offlineService.enqueue(OfflineJob(
                        sessionDir: dir, transcriptURL: result.url, title: m.title,
                        attendees: m.attendees, filing: m.filing,
                        presentReviewWhenDone: false, autoSummarize: settings.autoRunClaude))
                    offlineService.runNextIfIdle()
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
        return callDetector.activeCall?.bundleID == bid
            || callDetector.capturing.contains { $0.bundleID?.lowercased() == bid }
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
        return pendingRecoveries
            .filter { $0.manifest.callBundleID == call.bundleID }
            .filter { now.timeIntervalSince($0.manifest.lastHeartbeat) < Self.resumeMatchWindow }
            .max { $0.manifest.lastHeartbeat < $1.manifest.lastHeartbeat }
    }

    /// Discard a crashed session entirely (audio + state).
    func discard(_ session: RecoverableSession) {
        try? FileManager.default.removeItem(at: session.dir)
        pendingRecoveries.removeAll { $0.id == session.id }
        AppLog.log("Discarded crashed session \(session.id)", category: "record")
    }

    /// Re-transcribe every audio segment of a session through the model, mapping
    /// mic*→Me and system*→Remote with cumulative time offsets.
    private func reTranscribeSession(dir: URL) async -> [Segment] {
        guard let kit = await models.prepare(settings.model) else { return [] }
        var out: [Segment] = []
        for (track, base) in [(SpeakerTrack.me, "mic"), (SpeakerTrack.remote, "system")] {
            var offset: TimeInterval = 0
            for url in audioSegmentURLs(in: dir, base: base) {
                out += await OfflineTranscriber.transcribe(caf: url, track: track, using: kit, startElapsed: offset)
                offset += SessionStore.audioDuration(url)
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// All audio segment files for a track base name, in capture order
    /// (`mic.caf`, `mic.2.caf`, …).
    private func audioSegmentURLs(in dir: URL, base: String) -> [URL] {
        var urls: [URL] = []
        let first = dir.appendingPathComponent("\(base).caf")
        if FileManager.default.fileExists(atPath: first.path) { urls.append(first) }
        var idx = 2
        while case let u = dir.appendingPathComponent("\(base).\(idx).caf"),
              FileManager.default.fileExists(atPath: u.path) {
            urls.append(u); idx += 1
        }
        return urls
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

    func teardownForQuit() {
        micCapture?.stop()
        systemCapture?.stop()
    }

    // MARK: Helpers

    private var isErrorState: Bool {
        if case .error = state { return true }
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
