import Foundation
import AppKit
import UserNotifications

/// Drives the meeting-summary flow asynchronously via Claude or Grok CLI (raw prompt):
/// generate in the background → stage the result → user reviews in History → commit to the
/// vault (or discard / regenerate). Replaces the old skill-based auto-run. "Ready for review"
/// is represented purely by the presence of a staging file (`.staging/<transcript>.md`), so it
/// survives app restarts; in-flight jobs are tracked in `jobs` only while running.
/// Backend is selected in Settings (`summaryBackend`).
@MainActor
final class SummaryService: ObservableObject, ProcessingQueue {
    enum JobState: Equatable {
        case pending(since: Date)
        case failed(String)
    }

    /// Whether the summary queue is running normally or paused (usage limit hit, too
    /// many failures, or a manual pause). While paused, the pump refuses to start runs.
    enum ThrottleState: Equatable {
        case normal
        case paused(reason: PauseReason, resumeAt: Date?)
    }
    enum PauseReason: Equatable { case usageLimit, repeatedFailures, userPaused }

    /// A batch of summaries awaiting one user confirmation ("Summarize N notes?"), so a
    /// backlog never fires silently and burns Claude usage. Debounced into a single slot.
    struct BulkConfirm: Equatable { var items: [TranscriptItem] }

    /// Repair pass after a speaker rename when a summary already exists.
    struct RepairJob: Equatable {
        let item: TranscriptItem
        let renames: [String: String]
        let previousNote: String
    }

    /// Per-transcript live job state, keyed by transcript path. Absent = not running
    /// (either never summarized, or already staged/committed).
    @Published private(set) var jobs: [String: JobState] = [:]
    /// Throttle state, surfaced in the Processing tab (paused banner + Resume).
    @Published private(set) var throttle: ThrottleState = .normal
    /// Set when a bulk wave needs confirmation; History shows the prompt.
    @Published private(set) var pendingBulkConfirm: BulkConfirm?

    private let store: TranscriptStore
    private var queue: [TranscriptItem] = []
    private var repairQueue: [RepairJob] = []
    private var isRunning = false
    /// Transcript id of the summary currently being generated (nil when none) — lets the
    /// UI distinguish "summarizing now" from "queued" (both sit at `.pending` in `jobs`).
    @Published private(set) var runningID: String?
    /// Live activity ticker for the currently-running summary (e.g. "Writing Key Topics…").
    /// "Starting Claude…" when the run begins; updated from stream events; nil when no
    /// run is active (i.e. always nil when runningID is nil).
    @Published private(set) var runningActivity: String?
    private var consecutiveFailures = 0
    private var backoffAttempt = 0
    private var lastSummaryStartedAt: Date?
    private var resumeTask: Task<Void, Never>?
    private var runningProcessHandle = ProcessHandle()
    private var preemptRequested = false

    /// Injected: only run a summary while the app is idle (no live recording), so a
    /// background Claude subprocess never competes with an active call. Pending jobs
    /// wait in the queue and are pumped from idle re-entry points via `runNextIfIdle()`.
    var isIdle: () -> Bool = { true }
    /// Injected: idle debounce elapsed — background drain may start.
    var canDrain: () -> Bool = { true }
    /// Injected: pump the queues after a job finishes (respects idle debounce).
    var requestPump: () -> Void = {}
    /// Injected: notify when `commit` deletes a session's audio folder, so the offline
    /// queue can drop any job still pending for that (now-gone) session.
    var onSessionAudioDeleted: (URL) -> Void = { _ in }

    init(store: TranscriptStore) {
        self.store = store
        // Ask once so we can ping the user when a background summary is ready to review.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func state(for item: TranscriptItem) -> JobState? { jobs[item.id] }

    /// Staging filename stem for a transcript (`YYYY-MM-DD-HHMM - Title`).
    nonisolated static func stagingBase(for transcriptURL: URL) -> String {
        transcriptURL.deletingPathExtension().lastPathComponent
    }

    /// Per-backend staging path: `.staging/<base>.<backend>.md`.
    @MainActor static func stagingURL(for transcriptURL: URL, backend: SummaryBackend) -> URL {
        stagingURL(for: transcriptURL, backend: backend, stagingDir: AppPaths.stagingURL)
    }

    nonisolated static func stagingURL(for transcriptURL: URL, backend: SummaryBackend, stagingDir: URL) -> URL {
        let base = stagingBase(for: transcriptURL)
        return stagingDir.appendingPathComponent("\(base).\(backend.rawValue).md")
    }

    /// Legacy single-slot path (pre dual-staging): `.staging/<base>.md`.
    nonisolated static func legacyStagingURL(for transcriptURL: URL, stagingDir: URL) -> URL {
        stagingDir.appendingPathComponent("\(stagingBase(for: transcriptURL)).md")
    }

    /// Summary v2 markup staging: `.staging/<base>.v2.md`.
    nonisolated static func v2StagingURL(for transcriptURL: URL, stagingDir: URL) -> URL {
        stagingDir.appendingPathComponent("\(stagingBase(for: transcriptURL)).v2.md")
    }

    @MainActor static func v2StagingURL(for transcriptURL: URL) -> URL {
        v2StagingURL(for: transcriptURL, stagingDir: AppPaths.stagingURL)
    }

    /// Every staged summary for a transcript (dual-backend + v2 + legacy), newest-friendly order.
    nonisolated static func allStagedSummaries(for transcriptURL: URL, stagingDir: URL) -> [(backend: SummaryBackend?, url: URL)] {
        let fm = FileManager.default
        var found: [(SummaryBackend?, URL)] = []
        let v2 = v2StagingURL(for: transcriptURL, stagingDir: stagingDir)
        if fm.fileExists(atPath: v2.path) { found.append((nil, v2)) }
        for backend in SummaryBackend.allCases {
            let url = stagingURL(for: transcriptURL, backend: backend, stagingDir: stagingDir)
            if fm.fileExists(atPath: url.path) { found.append((backend, url)) }
        }
        let legacy = legacyStagingURL(for: transcriptURL, stagingDir: stagingDir)
        if fm.fileExists(atPath: legacy.path) { found.append((nil, legacy)) }
        return found
    }

    /// Preferred staging file. Prefer an existing `.v2.md` when present (or when the
    /// active pipeline is v2). Never invent a URL from SQLite run history alone — runs
    /// persist after Accept & File / Discard and must not keep History stuck in review.
    nonisolated static func preferredStagingURL(for transcriptURL: URL,
                                                prefer: SummaryBackend,
                                                stagingDir: URL,
                                                pipeline: SummaryPipeline = .classic) -> URL? {
        let v2 = v2StagingURL(for: transcriptURL, stagingDir: stagingDir)
        if FileManager.default.fileExists(atPath: v2.path) {
            return v2
        }
        // `pipeline` retained for call-site clarity; preference after this point is
        // dual-staging / legacy only (v2 file absence means not ready for markup review).
        switch pipeline { case .classic, .v2: break }
        let all = allStagedSummaries(for: transcriptURL, stagingDir: stagingDir)
        if let match = all.first(where: { $0.backend == prefer }) { return match.url }
        if let dual = all.first(where: { $0.backend != nil }) { return dual.url }
        return all.first?.url
    }

    nonisolated static func anyStagingExists(for transcriptURL: URL, stagingDir: URL) -> Bool {
        !allStagedSummaries(for: transcriptURL, stagingDir: stagingDir).isEmpty
    }

    @MainActor static func removeAllStaging(for transcriptURL: URL) {
        let dir = AppPaths.stagingURL
        for entry in allStagedSummaries(for: transcriptURL, stagingDir: dir) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    /// Convenience: preferred staging for the current settings backend.
    @MainActor static func stagingURL(for transcriptURL: URL) -> URL {
        stagingURL(for: transcriptURL, backend: AppSettings.shared.summaryBackend)
    }

    // MARK: Enqueue

    /// The single auto-enqueue entry point: a note became summary-ready (fresh recording,
    /// speakers just named, an async pass auto-resolved them, or launch backlog). Applies
    /// `SummaryEnqueuePolicy` (autoRunClaude + bulk threshold) so a single fresh recording
    /// summarizes silently while a bulk wave asks for one confirmation. `userInitiated`
    /// bypasses both gates.
    func enqueueIfPolicyAllows(_ item: TranscriptItem, trigger: SummaryTrigger) {
        let settings = AppSettings.shared
        let policy = SummaryEnqueuePolicy(autoRunClaude: settings.autoRunClaude,
                                          bulkThreshold: settings.summaryBulkThreshold)
        let inFlight = queue.count + (isRunning ? 1 : 0) + (pendingBulkConfirm?.items.count ?? 0)
        switch policy.decide(trigger: trigger, alreadyQueuedOrPending: inFlight) {
        case .skipAutoOff:
            return
        case .enqueue:
            if SummaryEnqueuePolicy.liftsRepeatedFailurePause(trigger),
               case .paused(let reason, _) = throttle, reason == .repeatedFailures {
                clearThrottle()
                AppLog.log("Summary: resuming queue paused for repeated failures — explicit retry", category: "summary")
            }
            summarize(item)
        case .confirmBulk:
            // Debounce into the single slot — never raise a second dialog.
            guard jobs[item.id] == nil,
                  !Self.anyStagingExists(for: item.url, stagingDir: AppPaths.stagingURL) else { return }
            var slot = pendingBulkConfirm ?? BulkConfirm(items: [])
            guard !slot.items.contains(where: { $0.id == item.id }) else { return }
            slot.items.append(item)
            setSummaryStatus(.queued, for: item)   // durable: survives quit as pending intent
            pendingBulkConfirm = slot
        }
    }

    /// Confirm the pending bulk batch → enqueue them all.
    func confirmPendingBulk() {
        guard let slot = pendingBulkConfirm else { return }
        pendingBulkConfirm = nil
        for item in slot.items { summarize(item) }
    }

    /// Dismiss the bulk prompt without summarizing — clears the durable intent.
    func dismissPendingBulk() {
        for item in pendingBulkConfirm?.items ?? [] { setSummaryStatus(nil, for: item) }
        pendingBulkConfirm = nil
    }

    /// Rebuild pending-summary intent from disk at launch. If a backlog ≥ threshold is
    /// found, raise ONE bulk confirmation rather than a silent burst.
    func enqueuePendingFromDisk() {
        guard AppSettings.shared.autoRunClaude else { return }
        let pending: [TranscriptItem] = SessionStore.pendingSummarySessions().compactMap { (_, m) in
            guard let path = m.transcriptPath else { return nil }
            let url = URL(fileURLWithPath: path)
            if Self.anyStagingExists(for: url, stagingDir: AppPaths.stagingURL) { return nil }
            return store.items.first { $0.url == url }
                ?? store.items.first { $0.url.lastPathComponent == url.lastPathComponent }
        }
        guard !pending.isEmpty else { return }
        if pending.count >= max(2, AppSettings.shared.summaryBulkThreshold) {
            pendingBulkConfirm = BulkConfirm(items: pending)
            AppLog.log("Summary: \(pending.count) pending at launch — awaiting bulk confirmation", category: "summary")
        } else {
            for item in pending { summarize(item) }
        }
    }

    // MARK: Run

    /// Queue a background summary for `item`.
    ///
    /// A pending run is left alone so Retry cannot double-enqueue. A failed run is
    /// replaced: the failure stays in `jobs` so History can show it, and treating
    /// that record like in-flight work made Retry and Summarize return without
    /// starting anything. A staged draft still blocks a second run; Regenerate
    /// deletes that draft first.
    func summarize(_ item: TranscriptItem) {
        if case .pending = jobs[item.id] { return }
        let settings = AppSettings.shared
        if settings.summaryPipeline == .v2 {
            let v2 = Self.v2StagingURL(for: item.url)
            if FileManager.default.fileExists(atPath: v2.path) { return }
        } else {
            let backend = settings.summaryBackend
            if FileManager.default.fileExists(atPath: Self.stagingURL(for: item.url, backend: backend).path) {
                return
            }
        }
        if case .failed = jobs[item.id] {
            AppLog.log("Summary: retrying \(item.url.lastPathComponent) after a failed run", category: "summary")
            jobs[item.id] = nil
        }
        jobs[item.id] = .pending(since: Date())
        setSummaryStatus(.queued, for: item)
        queue.append(item)
        runNext()
    }

    /// Re-run the *active* backend only — other backends' staging files are kept for comparison.
    func regenerate(_ item: TranscriptItem) {
        let settings = AppSettings.shared
        if settings.summaryPipeline == .v2 {
            try? FileManager.default.removeItem(at: Self.v2StagingURL(for: item.url))
        } else {
            let backend = settings.summaryBackend
            try? FileManager.default.removeItem(at: Self.stagingURL(for: item.url, backend: backend))
            try? FileManager.default.removeItem(at: Self.legacyStagingURL(for: item.url, stagingDir: AppPaths.stagingURL))
        }
        jobs[item.id] = nil
        store.refresh()
        summarize(item)
    }

    func discard(_ item: TranscriptItem) {
        Self.removeAllStaging(for: item.url)
        jobs[item.id] = nil
        queue.removeAll { $0.id == item.id }
        setSummaryStatus(nil, for: item)
        store.refresh()
    }

    /// Discard only one backend's staged summary (keep others for side-by-side eval).
    func discardStaged(_ item: TranscriptItem, backend: SummaryBackend) {
        try? FileManager.default.removeItem(at: Self.stagingURL(for: item.url, backend: backend))
        if Self.allStagedSummaries(for: item.url, stagingDir: AppPaths.stagingURL).isEmpty {
            setSummaryStatus(nil, for: item)
        }
        store.refresh()
    }

    /// Vision-only pass over a transcript's image attachments. Caches digest on disk.
    enum DescribeAttachmentsResult {
        case success(String)
        case failure(String)
    }

    func describeAttachments(for item: TranscriptItem, forceRefresh: Bool = true) -> DescribeAttachmentsResult {
        let settings = AppSettings.shared
        let attachments = item.meta.attachments
        guard !attachments.isEmpty else { return .failure("No attachments on this meeting.") }
        guard settings.attachmentUnderstanding == .vision else {
            return .failure("Enable Vision in Settings → Summary → Attachments.")
        }
        guard settings.attachmentVisionBackend.isCursorAgent else {
            return .failure("Set a Cursor agent backend for attachment vision in Settings.")
        }
        guard let digest = AttachmentVisionService.digest(
            transcriptURL: item.url,
            vault: settings.vaultURL,
            understanding: settings.attachmentUnderstanding,
            visionBackend: settings.attachmentVisionBackend,
            cursorBinary: settings.cursorBinaryPath,
            forceRefresh: forceRefresh) else {
            return .failure("Vision pass failed or returned no output. Check Settings → Summary and try again.")
        }
        return .success(digest)
    }

    // MARK: Queue control (ProcessingQueue)

    /// Queued (not-yet-running) summaries, in run order.
    var queuedItems: [TranscriptItem] { queue }
    var queuedIDs: [String] { queue.map(\.id) }
    var hasQueuedWork: Bool { isRunning || !queue.isEmpty || !repairQueue.isEmpty }

    func prioritize(id: String) {
        guard let i = queue.firstIndex(where: { $0.id == id }), i > 0 else { return }
        let e = queue.remove(at: i); queue.insert(e, at: 0)
        objectWillChange.send()
    }
    func prioritize(_ item: TranscriptItem) { prioritize(id: item.id) }

    func move(id: String, to index: Int) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        let e = queue.remove(at: i)
        let clamped = min(max(index, 0), queue.count)
        queue.insert(e, at: clamped)
        objectWillChange.send()
    }

    func hold(id: String) {
        guard let item = queue.first(where: { $0.id == id }) else { return }
        if let dir = MeetingFiles.sessionDir(forAudioPath: item.meta.audio) {
            SessionStore.setSummaryHeld(true, in: dir)
        }
        objectWillChange.send()
    }

    func releaseHold(id: String) {
        guard let item = queue.first(where: { $0.id == id }) else { return }
        if let dir = MeetingFiles.sessionDir(forAudioPath: item.meta.audio) {
            SessionStore.setSummaryHeld(false, in: dir)
        }
        objectWillChange.send()
        requestPump()
    }

    func isHeld(id: String) -> Bool {
        guard let item = queue.first(where: { $0.id == id }),
              let dir = MeetingFiles.sessionDir(forAudioPath: item.meta.audio) else { return false }
        return SessionStore.isSummaryHeld(dir)
    }

    /// Enqueue a repair summary after the user confirms a speaker rename.
    func enqueueRepair(_ item: TranscriptItem, renames: [String: String], previousNoteURL: URL) {
        guard !renames.isEmpty else { return }
        let previousNote = (try? String(contentsOf: previousNoteURL, encoding: .utf8)) ?? ""
        repairQueue.removeAll { $0.item.id == item.id }
        repairQueue.append(RepairJob(item: item, renames: renames, previousNote: previousNote))

        // A staged draft is the common repair source. Snapshot it above, then remove it
        // so History returns to queued state until the repaired draft replaces it.
        // A committed vault note is only read as prompt input and is never overwritten.
        Self.removeAllStaging(for: item.url)
        if !queue.contains(where: { $0.id == item.id }) {
            queue.append(item)
        }
        jobs[item.id] = .pending(since: Date())
        setSummaryStatus(.queued, for: item)
        store.refresh()
        runNext()
    }

    private func pendingRepair(for item: TranscriptItem) -> RepairJob? {
        repairQueue.first { $0.item.id == item.id }
    }

    private func dequeueRepair(for item: TranscriptItem) -> RepairJob? {
        guard let i = repairQueue.firstIndex(where: { $0.item.id == item.id }) else { return nil }
        return repairQueue.remove(at: i)
    }

    func cancelQueued(id: String) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue.remove(at: i)
        jobs[id] = nil
        setSummaryStatus(nil, for: item)
        objectWillChange.send()
        store.refresh()
    }
    func cancelQueued(_ item: TranscriptItem) { cancelQueued(id: item.id) }

    // MARK: Throttle control

    /// User-driven pause of the whole summary queue.
    func pauseQueue() {
        resumeTask?.cancel(); resumeTask = nil
        throttle = .paused(reason: .userPaused, resumeAt: nil)
    }

    /// Resume after a pause (manual Resume button, or the auto-resume timer firing).
    func resumeQueue() {
        clearThrottle()
        runNextIfIdle()
    }

    /// Clear a pause without starting the queue. `resumeQueue` pumps afterwards;
    /// an explicit retry pumps via `summarize` once the retried item is enqueued,
    /// so the new run is not left behind an already-empty pump.
    private func clearThrottle() {
        resumeTask?.cancel(); resumeTask = nil
        consecutiveFailures = 0
        backoffAttempt = 0
        throttle = .normal
    }

    /// Record a terminal failure. The next `summarize` replaces it. A usage-limit
    /// hold stays `.pending` instead — that job is still in the queue.
    func noteFailedRun(_ item: TranscriptItem, reason: String) {
        jobs[item.id] = .failed(reason)
        setSummaryStatus(.failed, for: item)
    }

    private func tripThrottle(reason: PauseReason, resumeAt: Date?) {
        throttle = .paused(reason: reason, resumeAt: resumeAt)
        AppLog.log("Summary queue paused (\(reason))\(resumeAt.map { " — resumes \($0)" } ?? "")", category: "summary")
        scheduleAutoResume(at: resumeAt)
    }

    private func scheduleAutoResume(at resumeAt: Date?) {
        resumeTask?.cancel()
        guard AppSettings.shared.summaryAutoResumeAfterLimit else { return }
        backoffAttempt += 1
        let delay = resumeAt.map { max(30, $0.timeIntervalSinceNow) }
            ?? Self.backoffSeconds(attempt: backoffAttempt)
        resumeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.resumeQueue() }
        }
    }

    /// Pure exponential backoff (no jitter), capped at 1 hour — unit-testable.
    nonisolated static func backoffSeconds(attempt: Int) -> TimeInterval {
        min(3600, 60 * pow(2, Double(max(0, attempt - 1))))
    }

    /// Best-effort durable summary status on the recording's manifest (no-op if the
    /// transcript has no resolvable session, e.g. a manually-dropped .txt).
    private func setSummaryStatus(_ status: SessionManifest.SummaryStatus?, for item: TranscriptItem) {
        guard let dir = MeetingFiles.sessionDir(forAudioPath: item.meta.audio) else { return }
        SessionStore.setSummaryStatus(status, in: dir)
    }

    /// Pump the queue from an idle re-entry point (recording stopped, app launched, a
    /// review finished). No-op while recording — the gate inside `runNext` holds.
    func runNextIfIdle() { runNext() }

    /// Live capture is about to take the machine. Kill the CLI and park the job.
    func yieldToLiveRecording() {
        guard isRunning else { return }
        preemptRequested = true
        runningProcessHandle.terminate()
    }

    /// True when this completion should requeue instead of committing success or failure.
    @discardableResult
    private func parkIfPreempted(_ item: TranscriptItem) -> Bool {
        guard preemptRequested || !isIdle() else { return false }
        if !queue.contains(where: { $0.id == item.id }) {
            queue.insert(item, at: 0)
        }
        jobs[item.id] = .pending(since: Date())
        setSummaryStatus(.queued, for: item)
        isRunning = false
        runningID = nil
        runningActivity = nil
        preemptRequested = false
        runningProcessHandle = ProcessHandle()
        AppLog.log("Summary: parked for live recording — \(item.url.lastPathComponent)", category: "summary")
        store.refresh()
        return true
    }

    /// Pump the queue after a min-interval pacing delay.
    private func schedulePump(after delay: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.runNextIfIdle()
        }
    }

    private func runNext() {
        guard !isRunning, !queue.isEmpty else { return }
        guard isIdle(), canDrain() else { return }                 // hold while recording / settling
        guard case .normal = throttle else { return }  // hold while paused (usage limit / user)
        let settings = AppSettings.shared
        // Optional pacing: at most one summary per `summaryMinIntervalSeconds` (0 = off).
        if settings.summaryMinIntervalSeconds > 0, let last = lastSummaryStartedAt {
            let wait = settings.summaryMinIntervalSeconds - Date().timeIntervalSince(last)
            if wait > 0 { schedulePump(after: wait); return }
        }
        let allowHeld = settings.allowsHeldJobDrain(canDrain: true)
        guard let idx = queue.firstIndex(where: { item in
            guard let dir = MeetingFiles.sessionDir(forAudioPath: item.meta.audio) else { return true }
            if !SessionStore.isSummaryHeld(dir) { return true }
            return allowHeld
        }) else { return }
        isRunning = true
        lastSummaryStartedAt = Date()
        let item = queue.remove(at: idx)
        runningID = item.id
        if settings.summaryPipeline == .v2, pendingRepair(for: item) == nil {
            runV2(item: item, settings: settings)
            return
        }
        let backend = settings.summaryBackend
        runningActivity = {
            switch backend.provider {
            case .claude: return "Starting Claude…"
            case .grok: return "Starting Grok…"
            case .cursor: return "Starting \(backend.statusName)…"
            }
        }()
        setSummaryStatus(.running, for: item)
        let vault = settings.vaultURL
        let attachmentUnderstanding = settings.attachmentUnderstanding
        let visionBackend = settings.attachmentVisionBackend
        let summaryPromptTemplate = settings.summaryPromptTemplate
        let contactsURL = settings.contactsURL
        let terminologyScope = TerminologyStore.customerScope(fromFiling: item.meta.filing)
        let terminology = SummaryPromptBuilder.terminologyBlock(filingScope: terminologyScope)
        let peopleRecords = PeopleStore().all()
        let dbContacts = peopleRecords.map { $0.asContact() }
        let config = RunnerConfig(settings)
        let staged = Self.stagingURL(for: item.url, backend: backend)
        let failureTrip = settings.summaryFailureTripThreshold
        let backendLabel = backend.displayName
        AppLog.log("Summary: started for \(item.url.lastPathComponent) (backend=\(backend.rawValue), model=\(config.model(for: backend)))", category: "summary")

        let sessionDir = MeetingFiles.sessionDir(forAudioPath: item.meta.audio)
        let speakerHints = SpeakerGuessResolver.readPromptBlock(
            sessionDir: sessionDir,
            attendees: item.meta.attendees.joined(separator: ", "))
        let repairJob = pendingRepair(for: item)
        let repairTemplate = settings.summaryRepairPromptTemplate

        let handle = ProcessHandle()
        runningProcessHandle = handle
        preemptRequested = false
        Task.detached(priority: .userInitiated) { [weak self] in
            await MainActor.run { [weak self] in
                if attachmentUnderstanding == .vision, !item.meta.attachments.isEmpty {
                    self?.runningActivity = "Analyzing attachments…"
                }
            }
            let vision = AttachmentVisionService.digest(
                transcriptURL: item.url, vault: vault,
                understanding: attachmentUnderstanding,
                visionBackend: visionBackend,
                cursorBinary: config.cursorBinary)
            let built: SummaryPromptBuilder.Built
            if let repairJob {
                built = SummaryPromptBuilder.buildRepair(
                    template: repairTemplate,
                    previousNote: repairJob.previousNote,
                    renames: repairJob.renames,
                    transcriptURL: item.url,
                    attendees: item.meta.attendees.joined(separator: ", "),
                    destination: item.meta.filing,
                    contactsURL: contactsURL,
                    contactsFromDB: dbContacts,
                    peopleRecords: peopleRecords,
                    terminologyBlock: terminology.isEmpty ? nil : terminology,
                    visionDigest: vision,
                    attachmentUnderstanding: attachmentUnderstanding,
                    speakerHints: speakerHints)
            } else {
                built = SummaryPromptBuilder.build(
                    template: summaryPromptTemplate,
                    transcriptURL: item.url,
                    attendees: item.meta.attendees.joined(separator: ", "),
                    destination: item.meta.filing,
                    contactsURL: contactsURL,
                    contactsFromDB: dbContacts,
                    peopleRecords: peopleRecords,
                    terminologyBlock: terminology.isEmpty ? nil : terminology,
                    visionDigest: vision,
                    attachmentUnderstanding: attachmentUnderstanding,
                    speakerHints: speakerHints)
            }
            let runStart = DispatchTime.now().uptimeNanoseconds
            let result = await Self.runBackend(backend, prompt: built.prompt, config: config, processHandle: handle) { line in
                Task { @MainActor [weak self] in self?.runningActivity = line }
            }
            let timed = Self.withWallClock(runStart, result, model: config.model(for: backend))
            let attachments = item.meta.attachments
            await MainActor.run {
                guard let self else { return }
                if self.parkIfPreempted(item) { return }
                switch timed {
                case .success(let text, let metrics):
                    do {
                        let body = Self.mergeVisionDiagrams(
                            into: text, visionDigest: vision, attachments: attachments,
                            item: item, vault: vault)
                        AppPaths.ensureDirectory(staged.deletingLastPathComponent())
                        try body.write(to: staged, atomically: true, encoding: .utf8)
                        if repairJob != nil {
                            _ = self.dequeueRepair(for: item)
                        }
                        self.jobs[item.id] = nil
                        self.setSummaryStatus(.done, for: item)
                        self.consecutiveFailures = 0
                        self.backoffAttempt = 0
                        Self.noteConnection(backend, timed)
                        let run = SummaryRunRecord(
                            id: UUID().uuidString,
                            transcriptID: item.url.path,
                            transcriptPath: item.url.path,
                            createdAt: Date(),
                            pipeline: .classic,
                            writerBackend: backend.rawValue,
                            checkerBackend: "",
                            draftMarkdown: text,
                            writerMetrics: metrics
                        )
                        SummaryRunStore().insertRun(run, hunks: [])
                        Self.notifyReady(title: item.meta.title)
                        AppLog.log("Summary: ready for review — \(staged.lastPathComponent) (\(backendLabel))", category: "summary")
                    } catch {
                        self.noteFailedRun(item, reason: "Couldn't write the summary: \(error.localizedDescription)")
                    }
                case .usageLimited(let trip):
                    // Don't lose it or burn the rest of the queue — put it back at the
                    // front and pause until the limit lifts.
                    self.queue.insert(item, at: 0)
                    self.jobs[item.id] = .pending(since: Date())
                    self.setSummaryStatus(.paused, for: item)
                    Self.noteConnection(backend, timed)
                    AppLog.log("Summary: \(backendLabel) usage/rate limit hit (\(trip.matchedPhrase)) — pausing queue", category: "summary")
                    self.tripThrottle(reason: .usageLimit, resumeAt: trip.resumeAt)
                case .failure(let reason, _):
                    self.noteFailedRun(item, reason: reason)
                    self.consecutiveFailures += 1
                    Self.noteConnection(backend, timed)
                    AppLog.log("Summary: failed for \(item.url.lastPathComponent) (\(backendLabel)) — \(reason)", category: "summary")
                    if self.consecutiveFailures >= failureTrip {
                        self.tripThrottle(reason: .repeatedFailures, resumeAt: nil)
                    }
                }
                self.store.refresh()
                self.isRunning = false
                self.runningID = nil
                self.runningActivity = nil
                self.requestPump()
            }
        }
    }

    // MARK: Summary v2 pipeline

    private func runV2(item: TranscriptItem, settings: AppSettings) {
        runningActivity = "Starting writer (\(settings.summaryWriterBackend.statusName))…"
        setSummaryStatus(.running, for: item)
        let vault = settings.vaultURL
        let attachmentUnderstanding = settings.attachmentUnderstanding
        let visionBackend = settings.attachmentVisionBackend
        let terminology = SummaryPromptBuilder.terminologyBlock(
            filingScope: TerminologyStore.customerScope(fromFiling: item.meta.filing))
        let peopleRecords = PeopleStore().all()
        let dbContacts = peopleRecords.map { $0.asContact() }
        let writer = settings.summaryWriterBackend
        let checker = settings.summaryCheckerBackend
        let staged = Self.v2StagingURL(for: item.url)
        let failureTrip = settings.summaryFailureTripThreshold
        let config = RunnerConfig(settings)
        let cursorBinary = config.cursorBinary
        let summaryPromptTemplate = settings.summaryPromptTemplate
        let contactsURL = settings.contactsURL
        let transcriptText = SummaryPromptBuilder.readTranscript(item.url)
        let contactsText = SummaryPromptBuilder.readContacts(contactsURL,
                                                             dbContacts: dbContacts)
        let attendeesText = SummaryPromptBuilder.annotate(
            attendees: item.meta.attendees.joined(separator: ", "),
            contacts: SummaryPromptBuilder.parseContactsList(contactsText))
        let checkerInstructions = settings.summaryCheckerPromptTemplate
        let attachmentCaptions = MeetingAttachmentStore.promptBlock(attachments: item.meta.attachments)
        let v2SpeakerHints = SpeakerGuessResolver.readPromptBlock(
            sessionDir: MeetingFiles.sessionDir(forAudioPath: item.meta.audio),
            attendees: item.meta.attendees.joined(separator: ", "))

        let handle = ProcessHandle()
        runningProcessHandle = handle
        preemptRequested = false
        Task.detached(priority: .userInitiated) { [weak self] in
            await MainActor.run { [weak self] in
                if attachmentUnderstanding == .vision, !item.meta.attachments.isEmpty {
                    self?.runningActivity = "Analyzing attachments…"
                }
            }
            let vision = AttachmentVisionService.digest(
                transcriptURL: item.url, vault: vault,
                understanding: attachmentUnderstanding,
                visionBackend: visionBackend,
                cursorBinary: cursorBinary)
            let built = SummaryPromptBuilder.build(
                template: summaryPromptTemplate,
                transcriptURL: item.url,
                attendees: item.meta.attendees.joined(separator: ", "),
                destination: item.meta.filing,
                contactsURL: contactsURL,
                contactsFromDB: dbContacts,
                peopleRecords: peopleRecords,
                terminologyBlock: terminology.isEmpty ? nil : terminology,
                visionDigest: vision,
                attachmentUnderstanding: attachmentUnderstanding,
                speakerHints: v2SpeakerHints)

            await MainActor.run { [weak self] in
                self?.runningActivity = "Writer is drafting…"
            }
            let writerStart = DispatchTime.now().uptimeNanoseconds
            let draftResult = Self.withWallClock(
                writerStart,
                await Self.runBackend(writer, prompt: built.prompt, config: config, processHandle: handle) { line in
                    Task { @MainActor [weak self] in self?.runningActivity = line }
                },
                model: config.model(for: writer)
            )
            switch draftResult {
            case .success:
                break
            case .usageLimited(let trip):
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.parkIfPreempted(item) { return }
                    self.queue.insert(item, at: 0)
                    self.jobs[item.id] = .pending(since: Date())
                    self.setSummaryStatus(.paused, for: item)
                    Self.noteConnection(writer, draftResult)
                    self.tripThrottle(reason: .usageLimit, resumeAt: trip.resumeAt)
                    self.isRunning = false
                    self.runningID = nil
                    self.runningActivity = nil
                }
                return
            case .failure(let reason, let setupIssue):
                await MainActor.run { [weak self] in
                    self?.finishFailure(item: item, reason: reason, setupIssue: setupIssue,
                                        backend: writer, failureTrip: failureTrip)
                }
                return
            }

            guard case .success(let draft, let writerMetrics) = draftResult else { return }

            await MainActor.run { [weak self] in
                self?.runningActivity = "Checker is reviewing…"
            }
            let checkerPrompt = SummaryCheckerPromptBuilder.build(
                transcript: transcriptText,
                draft: draft,
                contacts: contactsText,
                attendees: attendeesText,
                destination: item.meta.filing,
                terminologyBlock: terminology,
                visionDigest: vision,
                attachmentCaptions: attachmentCaptions,
                instructions: checkerInstructions
            )
            let checkerStart = DispatchTime.now().uptimeNanoseconds
            let checkerResult = Self.withWallClock(
                checkerStart,
                await Self.runBackend(checker, prompt: checkerPrompt, config: config, processHandle: handle) { _ in },
                model: config.model(for: checker)
            )

            let runID = UUID().uuidString
            var checkerRaw = ""
            var hunks: [SummaryHunk] = []
            var parseOK = false
            var checkerMetrics: SummaryRunMetrics?

            if case .success(let raw, let metrics) = checkerResult {
                checkerRaw = raw
                checkerMetrics = metrics
                let parsed = SummaryEditJSONParser.parse(raw: raw, runID: runID)
                hunks = parsed.hunks
                parseOK = parsed.parseOK
            }

            let run = SummaryRunRecord(
                id: runID,
                transcriptID: item.url.path,
                transcriptPath: item.url.path,
                createdAt: Date(),
                pipeline: .v2,
                writerBackend: writer.rawValue,
                checkerBackend: checker.rawValue,
                draftMarkdown: draft,
                checkerRaw: checkerRaw,
                checkerParseOK: parseOK,
                writerMetrics: writerMetrics,
                checkerMetrics: checkerMetrics
            )
            SummaryRunStore().insertRun(run, hunks: hunks)
            let preview = SummaryHunkEngine.mergedMarkdown(draft: draft, hunks: hunks)
            let stagedBody = Self.mergeVisionDiagrams(
                into: preview.isEmpty ? draft : preview,
                visionDigest: vision,
                attachments: item.meta.attachments,
                item: item,
                vault: vault)

            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.parkIfPreempted(item) { return }
                do {
                    AppPaths.ensureDirectory(staged.deletingLastPathComponent())
                    try stagedBody.write(to: staged, atomically: true, encoding: .utf8)
                    self.jobs[item.id] = nil
                    self.setSummaryStatus(.done, for: item)
                    self.consecutiveFailures = 0
                    self.backoffAttempt = 0
                    Self.noteConnection(writer, draftResult)
                    if case .success = checkerResult { Self.noteConnection(checker, checkerResult) }
                    Self.notifyReady(title: item.meta.title)
                    AppLog.log("Summary v2: ready for review — \(staged.lastPathComponent)", category: "summary")
                } catch {
                    self.noteFailedRun(item, reason: "Couldn't write the summary: \(error.localizedDescription)")
                }
                self.store.refresh()
                self.isRunning = false
                self.runningID = nil
                self.runningActivity = nil
                self.requestPump()
            }
        }
    }

    private func finishFailure(item: TranscriptItem, reason: String, setupIssue: SetupIssue?,
                               backend: SummaryBackend, failureTrip: Int) {
        if parkIfPreempted(item) { return }
        noteFailedRun(item, reason: reason)
        consecutiveFailures += 1
        Self.noteConnection(backend, .failure(reason: reason, setupIssue: setupIssue))
        AppLog.log("Summary: failed for \(item.url.lastPathComponent) (\(backend.displayName)) — \(reason)", category: "summary")
        if consecutiveFailures >= failureTrip {
            tripThrottle(reason: .repeatedFailures, resumeAt: nil)
        }
        store.refresh()
        isRunning = false
        runningID = nil
        runningActivity = nil
        requestPump()
    }

    /// Keeps each provider's connection badge honest after a run, so a broken setup
    /// points the user at Settings and a success clears a stale warning.
    private static func noteConnection(_ backend: SummaryBackend, _ result: RunResult) {
        switch (backend.provider, result) {
        case (.claude, .success(_, let metrics)):
            if let usage = metrics.flatMap({ claudeUsage(from: $0) }) {
                ClaudeUsageStore.shared.record(usage)
            }
            ClaudeConnection.shared.noteRunSucceeded()
        case (.grok, .success):
            GrokConnection.shared.noteRunSucceeded()
        case (.cursor, .success):
            CursorConnection.shared.noteRunSucceeded()
        case (.claude, .usageLimited(let trip)):
            ClaudeConnection.shared.noteUsageLimited(resumeAt: trip.resumeAt)
        case (.grok, .usageLimited(let trip)):
            GrokConnection.shared.noteUsageLimited(resumeAt: trip.resumeAt)
        case (.cursor, .usageLimited):
            break
        case (.claude, .failure(_, .notInstalled)): ClaudeConnection.shared.refresh()
        case (.claude, .failure(let reason, .notLoggedIn)): ClaudeConnection.shared.noteAuthFailure(detail: reason)
        case (.grok, .failure(_, .notInstalled)): GrokConnection.shared.refresh()
        case (.grok, .failure(let reason, .notLoggedIn)): GrokConnection.shared.noteAuthFailure(detail: reason)
        case (.cursor, .failure(_, .notInstalled)): CursorConnection.shared.refresh()
        case (.cursor, .failure(let reason, .notLoggedIn)): CursorConnection.shared.noteAuthFailure(detail: reason)
        case (_, .failure(_, nil)):
            break
        }
    }

    /// Settings a background run needs, read once on the main actor.
    struct RunnerConfig: Sendable {
        var claudeBinary: String
        var claudeModel: String
        var grokBinary: String
        var grokModel: String
        var cursorBinary: String

        @MainActor init(_ settings: AppSettings) {
            claudeBinary = settings.claudeBinaryPath
            claudeModel = settings.claudeModel
            grokBinary = settings.grokBinaryPath
            grokModel = settings.grokModel
            cursorBinary = settings.cursorBinaryPath
        }

        func model(for backend: SummaryBackend) -> String {
            switch backend.provider {
            case .claude: return claudeModel
            case .grok: return grokModel
            case .cursor: return backend.rawValue
            }
        }
    }

    nonisolated private static func runBackend(
        _ backend: SummaryBackend,
        prompt: String,
        config: RunnerConfig,
        processHandle: ProcessHandle? = nil,
        onActivity: @escaping @Sendable (String) -> Void
    ) async -> RunResult {
        let model = config.model(for: backend)
        switch backend.provider {
        case .claude:
            return runClaudeStreaming(binary: config.claudeBinary, prompt: prompt, model: model,
                                      onActivity: onActivity, processHandle: processHandle)
        case .grok:
            onActivity("Grok is writing…")
            return runJSONAgent(.grok, model: model, processHandle: processHandle) {
                try GrokRunner.makeRawSummaryProcess(binaryPath: config.grokBinary, prompt: prompt, model: model)
            }
        case .cursor:
            onActivity("\(backend.statusName) is writing…")
            return runJSONAgent(.cursor, model: model, processHandle: processHandle) {
                try CursorAgentRunner.makeRawSummaryProcess(binaryPath: config.cursorBinary, prompt: prompt, model: model)
            }
        }
    }

    /// Refresh v2 staging file after hunk status changes in the markup UI.
    func refreshV2Staging(transcriptURL: URL, runID: String) {
        let store = SummaryRunStore()
        guard let run = store.run(id: runID) else { return }
        let hunks = store.hunks(forRunID: runID)
        let merged = SummaryHunkEngine.mergedMarkdown(draft: run.draftMarkdown, hunks: hunks)
        let staged = Self.v2StagingURL(for: transcriptURL)
        try? merged.write(to: staged, atomically: true, encoding: .utf8)
    }

    /// The summary for this item is being generated right now.
    func isSummarizing(_ item: TranscriptItem) -> Bool { runningID == item.id }

    /// The item is waiting in the summary queue, or in the pending bulk-confirm batch.
    func isPendingSummary(_ item: TranscriptItem) -> Bool {
        pendingSummaryIDs.contains(item.id)
    }

    /// Transcript IDs waiting in the summary queue or bulk-confirm batch — O(1) membership.
    var pendingSummaryIDs: Set<String> {
        var ids = Set(queue.map(\.id))
        if let bulk = pendingBulkConfirm {
            ids.formUnion(bulk.items.map(\.id))
        }
        return ids
    }

    /// Hard wall-clock cap on a single `claude` run, so a wedged/stalled process (e.g.
    /// the Mac slept mid-request, a hung network call) can't block the whole queue for
    /// an hour and then fail with an empty "exited with code 1". On trip the process is
    /// terminated and the job fails *retryably*.
    nonisolated private static let runTimeout: TimeInterval = 600   // 10 minutes

    /// Runs `claude -p` with `--output-format stream-json --include-partial-messages`,
    /// incrementally parsing NDJSON lines so the caller can drive a live-activity ticker.
    ///
    /// `onActivity` is called with human-readable lines (tool summaries early on, then
    /// "Writing <Section>…" whenever the heading in the accumulated text changes). Calls
    /// are throttled to at most once per second to avoid UI churn; section changes that
    /// arrive faster are coalesced.
    ///
    /// The staged note text is the `resultText` from the `result` event. If exit is 0
    /// but no result event arrived (e.g. the model wrote everything as deltas without a
    /// result envelope), the accumulated text deltas are used as a fallback.
    ///
    /// Usage-limit detection is applied to (resultText ?? rawTail) + stderr so limit
    /// phrases embedded inside the JSON wrapping are still caught.
    private nonisolated static func runClaudeStreaming(
        binary: String,
        prompt: String,
        model: String,
        onActivity: @escaping @Sendable (String) -> Void,
        processHandle: ProcessHandle? = nil
    ) -> RunResult {
        let built: (process: Process, stdout: Pipe, stderr: Pipe)
        do {
            built = try ClaudeRunner.makeRawSummaryStreamProcess(binaryPath: binary, prompt: prompt, model: model)
        } catch let e as AgentCLI.BinaryNotFound {
            return .failure(reason: e.localizedDescription, setupIssue: .notInstalled)
        } catch {
            return .failure(reason: error.localizedDescription, setupIssue: nil)
        }
        var buffer = Data()
        var accumulatedText = ""    // text deltas joined in order (note-sized, not bounded)
        var resultText: String?     // set once the `result` event arrives
        var isError = false
        var usage: ClaudeStreamParser.Usage?   // token/cost tally from the `result` event

        // Bounded raw tail for usage-limit phrase detection — limit phrases can appear
        // anywhere inside the JSON wrapping, so we keep the last ~64 KB of raw stdout.
        let rawTailCap = 65_536
        var rawTailData = Data()

        // Ticker throttle state — section heading last emitted and the wall-clock time.
        var lastActivitySection: String?
        var lastActivityTime: Date = .distantPast

        // Fire the first few tool/text lines immediately so the ticker isn't blank
        // before the model reaches a section heading.
        var earlyLinesEmitted = false

        let output: ProcessOutput
        do {
            output = try ProcessRun.run(built.process, stdout: built.stdout, stderr: built.stderr,
                                        timeout: runTimeout, handle: processHandle) { chunk in
                // Accumulate raw bytes for limit detection (bounded ring-like behaviour via
                // trimming: we only ever trim when we exceed the cap, which is rare).
                rawTailData.append(chunk)
                if rawTailData.count > rawTailCap {
                    rawTailData = rawTailData.suffix(rawTailCap)
                }

                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)

                    let event = ClaudeStreamParser.parse(lineData)

                    // Accumulate text deltas.
                    if !event.textDelta.isEmpty {
                        accumulatedText += event.textDelta
                    }

                    // Capture the result envelope (text, error flag, usage tally).
                    if let r = event.resultText {
                        resultText = r
                        isError = event.isError ?? false
                        if let u = event.usage { usage = u }
                    }

                    // Early tool/text lines surface before a section heading appears.
                    if !earlyLinesEmitted, !event.activityLines.isEmpty {
                        earlyLinesEmitted = true
                        onActivity(event.activityLines.first ?? "Working…")
                    }

                    // Section-change ticker (≥1 s between updates).
                    if let section = ClaudeStreamParser.currentSection(in: accumulatedText) {
                        let now = Date()
                        if section != lastActivitySection,
                           now.timeIntervalSince(lastActivityTime) >= 1.0 {
                            lastActivitySection = section
                            lastActivityTime = now
                            onActivity("Writing \(section)…")
                        }
                    }
                }
            }
        } catch {
            return .failure(reason: "Failed to launch claude: \(error.localizedDescription)", setupIssue: nil)
        }

        if output.timedOut {
            return .failure(reason: "Summary timed out after \(Int(runTimeout / 60)) min — retry.", setupIssue: nil)
        }

        let code = output.exitCode
        let err = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Usage-limit / auth detection: prefer the decoded result text; fall back to the
        // bounded raw tail so phrases inside JSON wrapping are still found.
        let rawTail = String(data: rawTailData, encoding: .utf8) ?? ""
        let limitCandidate = resultText ?? rawTail

        guard code == 0, !isError else {
            if let trip = ClaudeUsageLimit.detect(stdout: limitCandidate, stderr: err, exitCode: code) {
                return .usageLimited(trip)
            }
            if ClaudeAuthError.detect(stdout: limitCandidate, stderr: err, exitCode: code) != nil {
                return .failure(
                    reason: "Claude Code isn't logged in. Open Settings → Summary → Claude to log in, then retry.",
                    setupIssue: .notLoggedIn)
            }
            let detail = (resultText ?? "").isEmpty ? (err.isEmpty ? "claude exited with code \(code)" : err) : (resultText ?? "")
            return .failure(reason: String(detail.prefix(240)), setupIssue: nil)
        }

        // Staged note text: prefer the result envelope; fall back to accumulated deltas.
        let noteText = (resultText ?? accumulatedText).trimmingCharacters(in: .whitespacesAndNewlines)
        return noteText.isEmpty ? .failure(reason: "claude produced no output.", setupIssue: nil)
                                : .success(noteText, SummaryRunMetrics.from(claude: usage, wallClock: 0, model: model))
    }

    /// What differs between the JSON-output agent CLIs (Grok, Cursor agent).
    private struct JSONAgent: Sendable {
        let cliName: String
        let loginReason: String
        let extraAuthPhrases: [String]
        let parse: @Sendable (String) -> AgentCLI.JSONResult
        let usage: @Sendable (String) -> SummaryRunMetrics?

        static let grok = JSONAgent(
            cliName: "grok",
            loginReason: "Grok isn't logged in. Open Settings → Summary → Grok to log in, then retry.",
            extraAuthPhrases: [],
            parse: { GrokRunner.parseJSONResult(stdout: $0) },
            usage: { GrokRunner.parseUsage(stdout: $0) })

        static let cursor = JSONAgent(
            cliName: "cursor agent",
            loginReason: "Cursor isn't logged in. Run `cursor agent` once in Terminal to sign in, then retry.",
            extraAuthPhrases: ["api key"],
            parse: { CursorAgentRunner.parseJSONResult(stdout: $0) },
            usage: { CursorAgentRunner.parseUsage(stdout: $0) })
    }

    /// Runs a JSON-output agent CLI and classifies the result the same way as Claude:
    /// timeout, usage limit, missing login, or the note body from the final JSON object.
    private nonisolated static func runJSONAgent(
        _ agent: JSONAgent,
        model: String,
        processHandle: ProcessHandle?,
        makeProcess: () throws -> (process: Process, stdout: Pipe, stderr: Pipe)
    ) -> RunResult {
        let built: (process: Process, stdout: Pipe, stderr: Pipe)
        do {
            built = try makeProcess()
        } catch let e as AgentCLI.BinaryNotFound {
            return .failure(reason: e.localizedDescription, setupIssue: .notInstalled)
        } catch {
            return .failure(reason: error.localizedDescription, setupIssue: nil)
        }
        let output: ProcessOutput
        do {
            output = try ProcessRun.run(built.process, stdout: built.stdout, stderr: built.stderr,
                                        timeout: runTimeout, handle: processHandle)
        } catch {
            return .failure(reason: "Failed to launch \(agent.cliName): \(error.localizedDescription)", setupIssue: nil)
        }
        if output.timedOut {
            return .failure(reason: "Summary timed out after \(Int(runTimeout / 60)) min — retry.", setupIssue: nil)
        }

        let code = output.exitCode
        let out = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trip = ClaudeUsageLimit.detect(stdout: out, stderr: err, exitCode: code) {
            return .usageLimited(trip)
        }

        let looksAuth = AgentCLI.looksLikeAuth(out + "\n" + err, extraPhrases: agent.extraAuthPhrases)
        let notLoggedIn = RunResult.failure(reason: agent.loginReason, setupIssue: .notLoggedIn)
        let success = { (note: String) in
            RunResult.success(AgentCLI.sanitizeNoteText(note),
                              SummaryRunMetrics.merging(parsed: agent.usage(out), wallClock: 0, model: model))
        }

        switch agent.parse(out) {
        case .text(let note) where code == 0:
            return success(note)
        case .error(let msg):
            if looksAuth || AgentCLI.looksLikeAuth(msg, extraPhrases: ["login"]) { return notLoggedIn }
            return .failure(reason: String(msg.prefix(240)), setupIssue: nil)
        case .text, .unparseable:
            if code != 0 {
                if looksAuth { return notLoggedIn }
                let detail = err.isEmpty ? (out.isEmpty ? "\(agent.cliName) exited with code \(code)" : out) : err
                return .failure(reason: String(detail.prefix(240)), setupIssue: nil)
            }
            // Exit 0 but non-JSON: treat raw stdout as the note if it looks like markdown.
            if !out.isEmpty, out.first != "{" { return success(out) }
            return .failure(reason: "\(agent.cliName) produced no usable output.", setupIssue: nil)
        }
    }

    /// One-shot generation for the ground-truth check. Same runners as the queue,
    /// with wall-clock and token metrics kept so cost and speed can be compared.
    nonisolated static func generateForEval(
        backend: SummaryBackend,
        prompt: String,
        config: RunnerConfig
    ) async -> SummaryEvalRunResult {
        let modelLabel = config.model(for: backend)
        let start = DispatchTime.now().uptimeNanoseconds
        let result = await runBackend(backend, prompt: prompt, config: config) { _ in }
        switch withWallClock(start, result, model: modelLabel) {
        case .success(let text, let metrics):
            return .success(text, metrics ?? SummaryRunMetrics(wallClock: 0, model: modelLabel))
        case .usageLimited(let trip):
            return .failed("Usage limit: \(trip.matchedPhrase)")
        case .failure(let reason, _):
            return .failed(reason)
        }
    }

    // MARK: Compare harness (shared runners)

    /// Outcome shared with `SummaryComparison` (avoids `Swift.Result` + `Error` boilerplate).
    enum CompareGenerateResult: Sendable {
        case ok(String)
        case failed(String)
    }

    /// Used by `SummaryComparison` so the compare window and the queue share the same
    /// CLI invocation and parsing.
    nonisolated static func runForCompare(_ backend: SummaryBackend, prompt: String, config: RunnerConfig,
                                          processHandle: ProcessHandle? = nil) async -> CompareGenerateResult {
        switch await runBackend(backend, prompt: prompt, config: config, processHandle: processHandle, onActivity: { _ in }) {
        case .success(let text, _): return .ok(text)
        case .usageLimited(let trip): return .failed("Usage limit: \(trip.matchedPhrase)")
        case .failure(let reason, _): return .failed(reason)
        }
    }

    /// Files an already-generated markdown body (from the compare window). Appends the
    /// raw transcript like a normal commit. `overwriteExisting` replaces `meta.note` when set.
    @discardableResult
    func commitGeneratedMarkdown(_ item: TranscriptItem,
                                 destination: String,
                                 body: String,
                                 overwriteExisting: Bool) -> URL? {
        let vault = AppSettings.shared.vaultURL
        let dest = destination.trimmingCharacters(in: .whitespaces)
        let folder = dest.isEmpty ? vault : vault.appendingPathComponent(dest, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let safeTitle = item.meta.title.replacingOccurrences(of: "/", with: "-")
        var noteURL = folder.appendingPathComponent("\(df.string(from: item.meta.date)) - \(safeTitle).md")

        if overwriteExisting, let existing = item.meta.note, !existing.isEmpty {
            noteURL = URL(fileURLWithPath: existing)
        } else if FileManager.default.fileExists(atPath: noteURL.path), item.meta.note != noteURL.path {
            var n = 2
            repeat {
                noteURL = folder.appendingPathComponent("\(df.string(from: item.meta.date)) - \(safeTitle) (\(n)).md")
                n += 1
            } while FileManager.default.fileExists(atPath: noteURL.path)
        }

        let transcriptText = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
        let content = Self.composeNote(item: item, destination: dest, body: body,
                                       transcriptSource: transcriptText, noteURL: noteURL, vault: vault)
        do {
            try content.write(to: noteURL, atomically: true, encoding: .utf8)
        } catch {
            AppLog.log("Summary: compare commit write failed — \(error.localizedDescription)", category: "summary")
            return nil
        }

        return finishFiling(item: item, noteURL: noteURL, destination: dest,
                            alreadyProcessed: item.isProcessed,
                            logMessage: "compare-filed \(noteURL.lastPathComponent) (overwrite=\(overwriteExisting))")
    }

    private enum RunResult {
        case success(String, SummaryRunMetrics?)
        case usageLimited(ClaudeUsageLimit.Trip)
        case failure(reason: String, setupIssue: SetupIssue?)
    }

    private nonisolated static func withWallClock(_ start: UInt64,
                                                  _ result: RunResult,
                                                  model: String) -> RunResult {
        let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        switch result {
        case .success(let text, var metrics):
            if var m = metrics {
                m.wallClock = wall
                if m.model.isEmpty { m.model = model }
                return .success(text, m)
            }
            return .success(text, SummaryRunMetrics(wallClock: wall, model: model))
        default:
            return result
        }
    }

    /// Reconstruct Claude usage for `ClaudeUsageStore` from neutral metrics.
    private nonisolated static func claudeUsage(from metrics: SummaryRunMetrics) -> ClaudeStreamParser.Usage? {
        guard metrics.inputTokens > 0 || metrics.outputTokens > 0 || metrics.reportedCostUSD != nil else {
            return nil
        }
        return ClaudeStreamParser.Usage(
            inputTokens: metrics.inputTokens,
            outputTokens: metrics.outputTokens,
            cacheCreationTokens: metrics.cacheWriteTokens,
            cacheReadTokens: metrics.cacheReadTokens,
            costUSD: metrics.reportedCostUSD
        )
    }

    /// A failure that maps to a CLI connection problem the user can fix, so the
    /// badge + History message can point them at Settings → Summary.
    private enum SetupIssue { case notInstalled, notLoggedIn }

    /// Local notification when a summary lands, since runs take a minute or two and the user
    /// may be in another tab/app.
    private static func notifyReady(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Summary ready to review"
        content.body = title.isEmpty ? "A meeting summary is ready in History → Review." : title
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: Commit

    /// Files the staged summary into the vault at `destination`, marks the transcript processed,
    /// removes staging files, and returns the written note URL. Pass `stagedURL` from the review
    /// pane when comparing multiple backends; defaults to the preferred staging file.
    @discardableResult
    func commit(_ item: TranscriptItem, destination: String, stagedURL: URL? = nil) -> URL? {
        let staged = stagedURL
            ?? item.summaryReadyURL
            ?? Self.preferredStagingURL(for: item.url,
                                        prefer: AppSettings.shared.summaryBackend,
                                        stagingDir: AppPaths.stagingURL,
                                        pipeline: AppSettings.shared.summaryPipeline)
        guard let staged,
              let body = try? String(contentsOf: staged, encoding: .utf8) else {
            AppLog.log("Summary: commit failed — no staged file for \(item.url.lastPathComponent)", category: "summary")
            return nil
        }
        let vault = AppSettings.shared.vaultURL
        let dest = destination.trimmingCharacters(in: .whitespaces)
        let folder = dest.isEmpty ? vault : vault.appendingPathComponent(dest, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let safeTitle = item.meta.title.replacingOccurrences(of: "/", with: "-")
        var noteURL = folder.appendingPathComponent("\(df.string(from: item.meta.date)) - \(safeTitle).md")
        // Don't clobber an existing note unless it's this transcript's own note.
        if FileManager.default.fileExists(atPath: noteURL.path), item.meta.note != noteURL.path {
            var n = 2
            repeat {
                noteURL = folder.appendingPathComponent("\(df.string(from: item.meta.date)) - \(safeTitle) (\(n)).md")
                n += 1
            } while FileManager.default.fileExists(atPath: noteURL.path)
        }

        // Read the raw transcript body before moving it to Processed/.
        let transcriptText = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
        let content = Self.composeNote(item: item, destination: dest, body: body,
                                       transcriptSource: transcriptText, noteURL: noteURL, vault: vault)
        do {
            try content.write(to: noteURL, atomically: true, encoding: .utf8)
        } catch {
            AppLog.log("Summary: commit write failed — \(error.localizedDescription)", category: "summary")
            return nil
        }
        return finishFiling(item: item, noteURL: noteURL, destination: dest,
                            alreadyProcessed: item.isProcessed)
    }

    /// Everything that happens once the note content is written: move/relink,
    /// clear staging + queue state, reclaim audio. Shared by both commit paths.
    @discardableResult
    private func finishFiling(item: TranscriptItem,
                              noteURL: URL,
                              destination: String,
                              alreadyProcessed: Bool,
                              logMessage: String? = nil) -> URL {
        let dest = destination.trimmingCharacters(in: .whitespaces)
        let moved: URL
        if alreadyProcessed {
            moved = item.url
            TranscriptWriter.updateFrontmatter(at: moved) { $0.note = noteURL.path; $0.filing = dest }
        } else {
            moved = store.moveToProcessed(item, notePath: noteURL.path)
        }
        // Reverse link only: the filed note already embeds the raw transcript inline.
        crossLinkSummaryOntoRaw(summaryURL: noteURL, rawURL: moved)
        // Remove every backend's staging file for this transcript (dual-staging + legacy).
        Self.removeAllStaging(for: item.url)
        jobs[item.id] = nil
        queue.removeAll { $0.id == item.id }
        setSummaryStatus(.done, for: item)   // clear pending-summary intent (before any audio delete)

        // The committed summary + the raw transcript make the session audio redundant —
        // delete it (and its session folder) to reclaim disk, and clear the `audio` link.
        // Permanent (not Trash): this is an automatic, opt-in disk reclaim, not a user-initiated
        // delete they might want to undo. The session-dir guard is shared via MeetingFiles.
        if AppSettings.shared.deleteAudioAfterFiling, let audio = item.meta.audio, !audio.isEmpty {
            if let sessionDir = MeetingFiles.sessionDir(forAudioPath: audio) {
                onSessionAudioDeleted(sessionDir)                     // drop any pending offline job first
                try? FileManager.default.removeItem(at: sessionDir)   // mic/system/mixed.caf + manifest
            } else {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: audio))
            }
            TranscriptWriter.updateFrontmatter(at: moved) { $0.audio = nil }
            AppLog.log("Summary: deleted session audio after filing", category: "summary")
        }

        let msg = logMessage ?? "committed \(noteURL.lastPathComponent) → \(dest.isEmpty ? "(vault root)" : dest)"
        AppLog.log("Summary: \(msg)", category: "summary")
        store.refresh()
        return noteURL
    }

    /// Best-effort note path for relative attachment embeds before filing.
    nonisolated static func prospectiveNoteURL(item: TranscriptItem, destination: String, vault: URL) -> URL {
        if let existing = item.meta.note, !existing.isEmpty {
            return URL(fileURLWithPath: existing)
        }
        let dest = destination.trimmingCharacters(in: .whitespaces)
        let folder = dest.isEmpty ? vault : vault.appendingPathComponent(dest, isDirectory: true)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let safeTitle = item.meta.title.replacingOccurrences(of: "/", with: "-")
        return folder.appendingPathComponent("\(df.string(from: item.meta.date)) - \(safeTitle).md")
    }

    /// Merges an enriched `## Diagrams` section when vision output is available.
    nonisolated static func mergeVisionDiagrams(into draft: String,
                                                visionDigest: String?,
                                                attachments: [MeetingAttachment],
                                                item: TranscriptItem,
                                                vault: URL) -> String {
        guard let visionDigest else { return draft }
        let documentURL = prospectiveNoteURL(item: item, destination: item.meta.filing, vault: vault)
        return AttachmentVisionService.mergeDiagrams(
            into: draft, visionDigest: visionDigest, attachments: attachments,
            documentURL: documentURL, vault: vault)
    }

    /// Builds the filed note: YAML frontmatter + summary body + inline raw transcript.
    /// `transcriptSource` is the full transcript file text (frontmatter allowed); only the
    /// `## Transcript` / manual-notes sections are appended. Idempotent if `body` already
    /// contains a `## Raw Transcript` section (stripped first).
    nonisolated static func composeNote(item: TranscriptItem, destination: String, body: String,
                            transcriptSource: String, noteURL: URL, vault: URL) -> String {
        var summary = strippingRawTranscriptSection(body)
        summary = strippingRawTranscriptWikiLink(summary)
        summary = strippingAttachmentsSection(summary)

        let headed: String
        if summary.hasPrefix("---\n") || summary.hasPrefix("---\r\n") {
            headed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var lines = ["---", "title: \(item.meta.title)", "date: \(df.string(from: item.meta.date))"]
            if !item.meta.attendees.isEmpty {
                lines.append("attendees:")
                for a in item.meta.attendees { lines.append("  - \(a)") }
            }
            if !destination.isEmpty { lines.append("filing: \(destination)") }
            lines.append("source: parley-summary")
            lines.append("---")
            headed = lines.joined(separator: "\n") + "\n\n" + summary.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let sourceAttachments = TranscriptWriter.parseFrontmatter(text: transcriptSource)?.attachments
            ?? item.meta.attachments
        let filedAttachments = MeetingAttachmentStore.attachmentsForFiling(attachments: sourceAttachments)
        var noteBody = headed
        if !filedAttachments.isEmpty,
           let section = MeetingAttachmentStore.renderSection(
            attachments: filedAttachments, documentURL: noteURL, vault: vault) {
            noteBody += "\n\n" + section
        }

        let sections = TranscriptWriter.extractBodySections(text: transcriptSource)
        var appendix: [String] = ["", "---", "", "## Raw Transcript", ""]
        if let notes = sections.manualNotes, !notes.isEmpty {
            appendix.append("### Notes (manual)")
            appendix.append("")
            appendix.append(notes)
            appendix.append("")
        }
        appendix.append(sections.transcript.isEmpty ? "_(no transcript text)_" : sections.transcript)
        appendix.append("")
        return noteBody.trimmingCharacters(in: CharacterSet.newlines) + "\n" + appendix.joined(separator: "\n")
    }

    nonisolated static func strippingAttachmentsSection(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "## Attachments"
        }) else { return text }
        var end = idx + 1
        while end < lines.count {
            let t = lines[end].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") { break }
            end += 1
        }
        var result = lines[..<idx] + lines[end...]
        while result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func strippingDiagramsSection(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "## Diagrams"
        }) else { return text }
        var end = idx + 1
        while end < lines.count {
            let t = lines[end].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") { break }
            end += 1
        }
        var result = lines[..<idx] + lines[end...]
        while result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a trailing `## Raw Transcript` section (and the `---` rule above it, if any).
    nonisolated static func strippingRawTranscriptSection(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let idx = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "## Raw Transcript"
        }) else { return text }
        var end = idx
        if end > 0, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        if end > 0, lines[end - 1].trimmingCharacters(in: .whitespaces) == "---" { end -= 1 }
        if end > 0, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return lines[..<end].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func strippingRawTranscriptWikiLink(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { $0.hasPrefix("**Raw transcript:**") }) else {
            return text
        }
        lines.remove(at: idx)
        // Drop a bare `---` separator left immediately above the removed link.
        if idx > 0, lines[idx - 1].trimmingCharacters(in: .whitespaces) == "---" {
            lines.remove(at: idx - 1)
            if idx > 1, lines[idx - 2].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.remove(at: idx - 2)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Cross-linking

    /// Inserts/updates an Obsidian wiki-link on the raw transcript pointing at the filed note.
    /// The filed note embeds the transcript inline, so we no longer add a reverse wiki-link footer.
    private func crossLinkSummaryOntoRaw(summaryURL: URL, rawURL: URL) {
        let summaryName = summaryURL.deletingPathExtension().lastPathComponent
        guard var text = try? String(contentsOf: rawURL, encoding: .utf8) else { return }
        let linkLine = "**Summary note:** [[\(summaryName)]]"
        var lines = text.components(separatedBy: "\n")
        if let idx = lines.firstIndex(where: { $0.hasPrefix("**Summary note:**") }) {
            if lines[idx] != linkLine {
                lines[idx] = linkLine
                text = lines.joined(separator: "\n")
                try? text.write(to: rawURL, atomically: true, encoding: .utf8)
            }
            return
        }
        // Insert after **Attendees:**, then **Date:**, then first # heading, else top.
        let insertIdx: Int
        if let idx = lines.firstIndex(where: { $0.hasPrefix("**Attendees:**") }) {
            insertIdx = idx + 1
        } else if let idx = lines.firstIndex(where: { $0.hasPrefix("**Date:**") }) {
            insertIdx = idx + 1
        } else if let idx = lines.firstIndex(where: { $0.hasPrefix("# ") && !$0.hasPrefix("## ") }) {
            insertIdx = idx + 1
        } else {
            insertIdx = 0
        }
        lines.insert(linkLine, at: insertIdx)
        text = lines.joined(separator: "\n")
        try? text.write(to: rawURL, atomically: true, encoding: .utf8)
    }
}
