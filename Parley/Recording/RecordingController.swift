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

    /// Progress of the post-stop whole-recording diarization pass (FluidAudio only),
    /// surfaced as a strip at the bottom of the record screen.
    enum OfflinePass: Equatable {
        case idle
        case running
        case done(String)
    }
    @Published private(set) var offlinePass: OfflinePass = .idle

    /// Bumped whenever a saved transcript's body is rewritten (offline pass, speaker
    /// review, add-attendee). The History/preview pane watches this to re-read the
    /// file — the URL is unchanged on a rewrite, so it wouldn't reload otherwise.
    @Published private(set) var transcriptRevision = 0

    /// Auto-run was deferred at stop because the FluidAudio recording still has
    /// unassigned speakers — finishing the speaker review will trigger it, so the
    /// summary is generated from the attributed transcript.
    private var autoRunAfterReview = false

    let models = ModelManager()
    let fluidModels = FluidModelManager()
    let voiceprints = VoiceprintStore()
    let vault = VaultDirectory()
    let notes = NotesGenerator()
    let store = TranscriptStore()
    /// Holds the local MLX summary model across compare runs (download/load/unload).
    /// Drives the background Claude summary → review → commit flow.
    private(set) lazy var summaryService = SummaryService(store: store)
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
        guard !name.isEmpty, let eng = engine as? SpeakerCapableEngine else { return }
        let model = eng.embeddingModelId
        let centroid = eng.setSpeakerName(speakerId, as: name)
        if let centroid {
            let vpId: UUID
            // Match an existing print of the SAME name AND embedding model (different
            // engines use non-comparable embedding spaces, so keep them separate).
            if let existing = voiceprints.voiceprints.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.embeddingModel == model
            }) {
                voiceprints.addSample(to: existing.id, embedding: centroid); vpId = existing.id
            } else {
                vpId = voiceprints.enroll(name: name, embedding: centroid, model: model).id
            }
            // Retain a short enrollment clip for re-enrollment (off-main, best-effort).
            Task { [weak self] in
                guard let self, let audio = await eng.repAudioSample(for: speakerId) else { return }
                self.voiceprints.attachAudioSample(to: vpId, samples: audio)
            }
        } else {
            AppLog.log("Named speaker \(speakerId) as \(name) but not enough clean audio — labeled, not enrolled", category: "record")
        }
        addAttendeeIfAbsent(name)
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
            if call.known && self.settings.autoRecordEnabled {
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
        offlinePass = .idle
        autoRunAfterReview = false
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

    /// On launch, salvage any `.partial` left by a crashed session into the vault inbox.
    private func recoverOrphanedPartials() {
        let recordings = AppPaths.recordingsDirectory
        guard let sessions = try? FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil) else { return }
        for session in sessions {
            // Sessions with a manifest are handled by the Recovery sheet — skip
            // them here so they aren't both auto-salvaged AND offered for resume.
            if SessionStore.read(session) != nil { continue }
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

        // Tear down the engine off the main actor; finalize() below reads the
        // already-populated timeline synchronously, so it needn't wait on this.
        // For a speaker-capable engine, then run one authoritative whole-recording
        // pass and offer the speaker-review sheet with the cleaned-up speakers.
        let engine = self.engine
        Task { [weak self] in
            await engine?.stop()
            if let eng = engine as? SpeakerCapableEngine {
                self?.offlinePass = .running
                let summary = await eng.runOfflinePass()
                guard let self else { return }
                self.offlinePass = .done(summary.note)
                // Persist the offline result (corrected labels + higher-accuracy
                // transcript) to the saved file — finalize() wrote the streaming
                // version synchronously before this pass completed.
                self.rewriteLastTranscript(reason: "offline pass")
                let speakers = eng.speakerSummaries()
                if !speakers.isEmpty {
                    self.pendingSpeakerReview = SpeakerReview(
                        speakers: speakers,
                        mixedCaf: self.sessionDirectory?.appendingPathComponent("mixed.caf"))
                }
                // Auto-run (if enabled): summarize now when every speaker is already
                // identified (or none were found); otherwise wait until the user
                // assigns names in the review, so the summary is correctly attributed.
                if self.settings.autoRunClaude {
                    let hasUnnamed = speakers.contains { $0.resolvedName == nil }
                    if speakers.isEmpty || !hasUnnamed {
                        self.maybeAutoRunClaude()
                    } else {
                        self.autoRunAfterReview = true
                    }
                }
            }
        }
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
        // Link to the session audio (mic track) if it was archived.
        let audioPath = sessionDirectory.map { $0.appendingPathComponent("mic.caf").path }

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
                if let dir = sessionDirectory {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("segments.jsonl"))
                }
                lastTranscriptURL = result.url
                lastResult = segments.isEmpty
                    ? "Saved (no speech transcribed): \(result.url.lastPathComponent)"
                    : "Transcript saved: \(result.url.lastPathComponent)"
                notes.reset()
                store.refresh()
                // Auto-run is opt-in; skip it when there's nothing to summarise. For
                // ANY speaker-capable engine, DON'T run here — defer until speakers are
                // assigned (after the offline pass / review) so the summary uses the
                // attributed transcript. stop()'s Task / finishSpeakerReview trigger it.
                if settings.autoRunClaude && !segments.isEmpty && !(engine is SpeakerCapableEngine) {
                    maybeAutoRunClaude()
                }
            } catch {
                AppLog.log("Finalize failed: \(error.localizedDescription)", category: "record")
                lastResult = "Finalize failed: \(error.localizedDescription)"
            }
        }

        finalizeManifest()   // mark the session cleanly finished (not a crash)
        state = .idle
        scheduleIdleUnload()   // free the model's RAM if we sit idle after this
        // The "Assign speakers" review is presented from stop() after the final
        // whole-recording diarization pass completes.
    }

    // MARK: At-stop speaker review (FluidAudio)

    /// Discovered speakers offered for naming after a FluidAudio recording stops.
    struct SpeakerReview: Identifiable {
        let id = UUID()
        var speakers: [CallSpeakerSummary]
        let mixedCaf: URL?
    }

    /// On-demand speaker detection for an already-recorded call (from History).
    /// Re-runs the offline diarization + batch-ASR pass on the session's saved audio,
    /// rewrites the transcript with attributed text, and opens the assign-speakers
    /// review. Reuses the live review machinery by pointing `engine`/`lastTranscriptURL`
    /// at this item (safe — we're idle, not recording).
    func reprocessSpeakers(forAudioPath audioPath: String?, transcript: URL,
                           attendees: String, title: String, filing: String) {
        guard !isRecording else { return }
        guard let audioPath, !audioPath.isEmpty else {
            lastResult = "No saved audio for this recording — can't detect speakers."; return
        }
        let micURL = URL(fileURLWithPath: audioPath)
        let dir = micURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: micURL.path) else {
            lastResult = "The audio for this recording was deleted — can't detect speakers."; return
        }

        // Build a transient speaker-capable engine matching the current setting.
        let eng: SpeakerCapableEngine
        switch settings.transcriptionEngine {
        case .whisperKit:
            eng = WhisperKitSpeakerKitEngine(models: models, settings: settings, voiceprints: voiceprints,
                                             identificationThreshold: settings.identificationThreshold)
        case .fluidAudio:
            eng = FluidAudioEngine(settings: settings, voiceprints: voiceprints,
                                   identificationThreshold: settings.identificationThreshold)
        }
        eng.onSpeakerIdentified = { [weak self] name in self?.addAttendeeIfAbsent(name) }
        eng.mixedAudioURL = dir.appendingPathComponent("mixed.caf")
        eng.micArchiveURL = micURL
        eng.systemArchiveURL = dir.appendingPathComponent("system.caf")
        eng.forceOfflineAsr = true   // no streaming units exist for a saved call

        // Point the review/rewrite machinery at this item.
        engine = eng
        lastTranscriptURL = transcript
        self.attendees = attendees
        meetingTitle = title
        destinationPath = filing
        offlinePass = .running

        Task { [weak self] in
            guard let self else { return }
            let summary = await eng.runOfflinePass()
            self.offlinePass = .done(summary.note)
            self.rewriteLastTranscript(reason: "history speaker detection")
            self.store.refresh()
            let speakers = eng.speakerSummaries()
            if speakers.isEmpty {
                self.lastResult = "No speakers detected in this recording."
            } else {
                self.pendingSpeakerReview = SpeakerReview(speakers: speakers, mixedCaf: eng.mixedAudioURL)
            }
        }
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

    /// Finish the review: clear the sheet and rewrite the just-written transcript
    /// with the (possibly newly-named) speakers + updated attendees.
    func finishSpeakerReview() {
        pendingSpeakerReview = nil
        rewriteLastTranscript(reason: "reviewed speakers")
        // If auto-run was deferred at stop pending speaker assignment, run it now —
        // on the freshly-attributed transcript.
        if autoRunAfterReview {
            autoRunAfterReview = false
            maybeAutoRunClaude()
        }
    }

    /// Queue a background Claude summary for the just-saved recording, if auto-summarize
    /// is on. Reads the current transcript (post-attribution) from the store so the summary
    /// reflects assigned speakers + attendees. The result is staged for review in History.
    private func maybeAutoRunClaude() {
        guard settings.autoRunClaude, let url = lastTranscriptURL else { return }
        guard !(engine?.finalTimeline() ?? segments).isEmpty else { return }
        store.refresh()
        guard let item = store.items.first(where: { $0.url == url })
            ?? store.items.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) else { return }
        summaryService.summarize(item)
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
        manifest = m
        SessionStore.write(m, to: dir)
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

    /// Mark the session cleanly finished so it isn't treated as a crash.
    private func finalizeManifest() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
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
