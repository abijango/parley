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

    /// Per-transcript live job state, keyed by transcript path. Absent = not running
    /// (either never summarized, or already staged/committed).
    @Published private(set) var jobs: [String: JobState] = [:]
    /// Throttle state, surfaced in the Processing tab (paused banner + Resume).
    @Published private(set) var throttle: ThrottleState = .normal
    /// Set when a bulk wave needs confirmation; History shows the prompt.
    @Published private(set) var pendingBulkConfirm: BulkConfirm?

    private let store: TranscriptStore
    private var queue: [TranscriptItem] = []
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

    /// Injected: only run a summary while the app is idle (no live recording), so a
    /// background Claude subprocess never competes with an active call. Pending jobs
    /// wait in the queue and are pumped from idle re-entry points via `runNextIfIdle()`.
    var isIdle: () -> Bool = { true }
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

    /// Whether a v2 staged file or run history exists for this transcript.
    nonisolated static func hasV2Artifacts(for transcriptURL: URL, stagingDir: URL) -> Bool {
        let v2 = v2StagingURL(for: transcriptURL, stagingDir: stagingDir)
        if FileManager.default.fileExists(atPath: v2.path) { return true }
        return SummaryRunStore().hasRuns(forTranscriptID: transcriptURL.path)
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

    /// Queue a background summary for `item` (no-op if already pending or this backend is staged).
    func summarize(_ item: TranscriptItem) {
        guard jobs[item.id] == nil else { return }
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

    // MARK: Queue control (ProcessingQueue)

    /// Queued (not-yet-running) summaries, in run order.
    var queuedItems: [TranscriptItem] { queue }
    var queuedIDs: [String] { queue.map(\.id) }

    func prioritize(id: String) {
        guard let i = queue.firstIndex(where: { $0.id == id }), i > 0 else { return }
        let e = queue.remove(at: i); queue.insert(e, at: 0)
        objectWillChange.send()
    }
    func prioritize(_ item: TranscriptItem) { prioritize(id: item.id) }

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
        resumeTask?.cancel(); resumeTask = nil
        consecutiveFailures = 0
        backoffAttempt = 0
        throttle = .normal
        runNextIfIdle()
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

    /// Pump the queue after a min-interval pacing delay.
    private func schedulePump(after delay: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.runNextIfIdle()
        }
    }

    private func runNext() {
        guard !isRunning, !queue.isEmpty else { return }
        guard isIdle() else { return }                 // hold while recording
        guard case .normal = throttle else { return }  // hold while paused (usage limit / user)
        let settings = AppSettings.shared
        // Optional pacing: at most one summary per `summaryMinIntervalSeconds` (0 = off).
        if settings.summaryMinIntervalSeconds > 0, let last = lastSummaryStartedAt {
            let wait = settings.summaryMinIntervalSeconds - Date().timeIntervalSince(last)
            if wait > 0 { schedulePump(after: wait); return }
        }
        isRunning = true
        lastSummaryStartedAt = Date()
        let item = queue.removeFirst()
        runningID = item.id
        if settings.summaryPipeline == .v2 {
            runV2(item: item, settings: settings)
            return
        }
        let backend = settings.summaryBackend
        runningActivity = {
            switch backend {
            case .claude: return "Starting Claude…"
            case .grok: return "Starting Grok…"
            case .local: return "Starting local Qwen…"
            case .composer25, .composer25Fast, .cursorGrok45, .cursorGrok45Fast:
                return "Starting \(backend.displayName)…"
            }
        }()
        setSummaryStatus(.running, for: item)
        let built = SummaryPromptBuilder.build(
            template: settings.summaryPromptTemplate,
            transcriptURL: item.url,
            attendees: item.meta.attendees.joined(separator: ", "),
            destination: item.meta.filing,
            contactsURL: settings.contactsURL,
            contactsFromDB: settings.contactsUseKnowledgeDB ? PeopleStore().contacts() : nil,
            terminologyBlock: {
                let scope = TerminologyStore.customerScope(fromFiling: item.meta.filing)
                let t = SummaryPromptBuilder.terminologyBlock(filingScope: scope)
                return t.isEmpty ? nil : t
            }()
        )
        let claudeBinary = settings.claudeBinaryPath
        let claudeModel = settings.claudeModel
        let grokBinary = settings.grokBinaryPath
        let grokModel = settings.grokModel
        let cursorBinary = settings.cursorBinaryPath
        let staged = Self.stagingURL(for: item.url, backend: backend)
        let failureTrip = settings.summaryFailureTripThreshold
        let backendLabel = backend.displayName
        let modelLabel: String = {
            switch backend {
            case .claude: return claudeModel
            case .grok: return grokModel
            case .local: return settings.localSummaryModelId
            case .composer25, .composer25Fast, .cursorGrok45, .cursorGrok45Fast:
                return backend.rawValue
            }
        }()
        AppLog.log("Summary: started for \(item.url.lastPathComponent) (backend=\(backend.rawValue), model=\(modelLabel))", category: "summary")

        Task.detached(priority: .userInitiated) { [weak self] in
            let result: RunResult
            switch backend {
            case .claude:
                result = Self.runClaudeStreaming(binary: claudeBinary, prompt: built.prompt, model: claudeModel,
                    onActivity: { line in
                        Task { @MainActor [weak self] in self?.runningActivity = line }
                    })
            case .grok:
                Task { @MainActor [weak self] in self?.runningActivity = "Grok is writing…" }
                result = Self.runGrok(binary: grokBinary, prompt: built.prompt, model: grokModel)
            case .local:
                result = await Self.runLocal(prompt: built.prompt) { line in
                    Task { @MainActor [weak self] in self?.runningActivity = line }
                }
            case .composer25, .composer25Fast, .cursorGrok45, .cursorGrok45Fast:
                Task { @MainActor [weak self] in self?.runningActivity = "\(backend.displayName) is writing…" }
                result = Self.runCursorAgent(binary: cursorBinary, prompt: built.prompt, model: backend.rawValue)
            }
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let text, let usage):
                    do {
                        AppPaths.ensureDirectory(staged.deletingLastPathComponent())
                        try text.write(to: staged, atomically: true, encoding: .utf8)
                        self.jobs[item.id] = nil
                        self.setSummaryStatus(.done, for: item)
                        self.consecutiveFailures = 0
                        self.backoffAttempt = 0
                        switch backend {
                        case .claude:
                            ClaudeUsageStore.shared.record(usage)
                            ClaudeConnection.shared.noteRunSucceeded()
                        case .grok:
                            GrokConnection.shared.noteRunSucceeded()
                        case .local:
                            break
                        case .composer25, .composer25Fast, .cursorGrok45, .cursorGrok45Fast:
                            CursorConnection.shared.noteRunSucceeded()
                        }
                        Self.notifyReady(title: item.meta.title)
                        AppLog.log("Summary: ready for review — \(staged.lastPathComponent) (\(backendLabel))", category: "summary")
                    } catch {
                        self.jobs[item.id] = .failed("Couldn't write the summary: \(error.localizedDescription)")
                        self.setSummaryStatus(.failed, for: item)
                    }
                case .usageLimited(let trip):
                    // Don't lose it or burn the rest of the queue — put it back at the
                    // front and pause until the limit lifts.
                    self.queue.insert(item, at: 0)
                    self.jobs[item.id] = .pending(since: Date())
                    self.setSummaryStatus(.paused, for: item)
                    switch backend {
                    case .claude:
                        ClaudeConnection.shared.noteUsageLimited(resumeAt: trip.resumeAt)
                    case .grok:
                        GrokConnection.shared.noteUsageLimited(resumeAt: trip.resumeAt)
                    case .local:
                        break
                    case .composer25, .composer25Fast, .cursorGrok45, .cursorGrok45Fast:
                        break
                    }
                    AppLog.log("Summary: \(backendLabel) usage/rate limit hit (\(trip.matchedPhrase)) — pausing queue", category: "summary")
                    self.tripThrottle(reason: .usageLimit, resumeAt: trip.resumeAt)
                case .failure(let reason, let setupIssue):
                    self.jobs[item.id] = .failed(reason)
                    self.setSummaryStatus(.failed, for: item)
                    self.consecutiveFailures += 1
                    // Keep the connection badge honest so the user is pointed at setup.
                    switch (backend, setupIssue) {
                    case (.claude, .notInstalled):  ClaudeConnection.shared.refresh()
                    case (.claude, .notLoggedIn):   ClaudeConnection.shared.noteAuthFailure(detail: reason)
                    case (.grok, .notInstalled):    GrokConnection.shared.refresh()
                    case (.grok, .notLoggedIn):     GrokConnection.shared.noteAuthFailure(detail: reason)
                    case (.composer25, .notInstalled), (.composer25Fast, .notInstalled),
                         (.cursorGrok45, .notInstalled), (.cursorGrok45Fast, .notInstalled):
                        CursorConnection.shared.refresh()
                    case (.composer25, .notLoggedIn), (.composer25Fast, .notLoggedIn),
                         (.cursorGrok45, .notLoggedIn), (.cursorGrok45Fast, .notLoggedIn):
                        CursorConnection.shared.noteAuthFailure(detail: reason)
                    default: break
                    }
                    AppLog.log("Summary: failed for \(item.url.lastPathComponent) (\(backendLabel)) — \(reason)", category: "summary")
                    if self.consecutiveFailures >= failureTrip {
                        self.tripThrottle(reason: .repeatedFailures, resumeAt: nil)
                    }
                }
                self.store.refresh()
                self.isRunning = false
                self.runningID = nil
                self.runningActivity = nil
                self.runNext()   // no-ops if paused (throttle guard) or idle gate closed
            }
        }
    }

    // MARK: Summary v2 pipeline

    private func runV2(item: TranscriptItem, settings: AppSettings) {
        runningActivity = "Starting writer (\(settings.summaryWriterBackend.displayName))…"
        setSummaryStatus(.running, for: item)
        let terminology = SummaryPromptBuilder.terminologyBlock(
            filingScope: TerminologyStore.customerScope(fromFiling: item.meta.filing))
        let dbContacts = settings.contactsUseKnowledgeDB ? PeopleStore().contacts() : nil
        let built = SummaryPromptBuilder.build(
            template: settings.summaryPromptTemplate,
            transcriptURL: item.url,
            attendees: item.meta.attendees.joined(separator: ", "),
            destination: item.meta.filing,
            contactsURL: settings.contactsURL,
            contactsFromDB: dbContacts,
            terminologyBlock: terminology.isEmpty ? nil : terminology
        )
        let writer = settings.summaryWriterBackend
        let checker = settings.summaryCheckerBackend
        let staged = Self.v2StagingURL(for: item.url)
        let failureTrip = settings.summaryFailureTripThreshold
        let claudeBinary = settings.claudeBinaryPath
        let claudeModel = settings.claudeModel
        let grokBinary = settings.grokBinaryPath
        let grokModel = settings.grokModel
        let cursorBinary = settings.cursorBinaryPath
        let transcriptText = SummaryPromptBuilder.readTranscript(item.url)

        Task.detached(priority: .userInitiated) { [weak self] in
            await MainActor.run { [weak self] in
                self?.runningActivity = "Writer is drafting…"
            }
            let draftResult = Self.runBackend(
                writer, prompt: built.prompt,
                claudeBinary: claudeBinary, claudeModel: claudeModel,
                grokBinary: grokBinary, grokModel: grokModel,
                cursorBinary: cursorBinary,
                onActivity: { line in Task { @MainActor [weak self] in self?.runningActivity = line } }
            )
            switch draftResult {
            case .success:
                break
            case .usageLimited(let trip):
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.queue.insert(item, at: 0)
                    self.jobs[item.id] = .pending(since: Date())
                    self.setSummaryStatus(.paused, for: item)
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

            guard case .success(let draft, _) = draftResult else { return }

            await MainActor.run { [weak self] in
                self?.runningActivity = "Checker is reviewing…"
            }
            let checkerPrompt = SummaryCheckerPromptBuilder.build(
                transcript: transcriptText,
                draft: draft,
                terminologyBlock: terminology
            )
            let checkerResult = Self.runBackend(
                checker, prompt: checkerPrompt,
                claudeBinary: claudeBinary, claudeModel: claudeModel,
                grokBinary: grokBinary, grokModel: grokModel,
                cursorBinary: cursorBinary,
                onActivity: { _ in }
            )

            let runID = UUID().uuidString
            var checkerRaw = ""
            var hunks: [SummaryHunk] = []
            var parseOK = false

            if case .success(let raw, _) = checkerResult {
                checkerRaw = raw
                let parsed = SummaryEditJSONParser.parse(raw: raw, runID: runID)
                hunks = parsed.hunks
                parseOK = parsed.parseOK
            }

            let run = SummaryRunRecord(
                id: runID,
                transcriptID: item.url.path,
                transcriptPath: item.url.path,
                createdAt: Date(),
                writerBackend: writer.rawValue,
                checkerBackend: checker.rawValue,
                draftMarkdown: draft,
                checkerRaw: checkerRaw,
                checkerParseOK: parseOK
            )
            SummaryRunStore().insertRun(run, hunks: hunks)
            let preview = SummaryHunkEngine.mergedMarkdown(draft: draft, hunks: hunks)
            let stagedBody = preview.isEmpty ? draft : preview

            await MainActor.run { [weak self] in
                guard let self else { return }
                do {
                    AppPaths.ensureDirectory(staged.deletingLastPathComponent())
                    try stagedBody.write(to: staged, atomically: true, encoding: .utf8)
                    self.jobs[item.id] = nil
                    self.setSummaryStatus(.done, for: item)
                    self.consecutiveFailures = 0
                    self.backoffAttempt = 0
                    Self.noteBackendSuccess(writer)
                    if case .success = checkerResult { Self.noteBackendSuccess(checker) }
                    Self.notifyReady(title: item.meta.title)
                    AppLog.log("Summary v2: ready for review — \(staged.lastPathComponent)", category: "summary")
                } catch {
                    self.jobs[item.id] = .failed("Couldn't write the summary: \(error.localizedDescription)")
                    self.setSummaryStatus(.failed, for: item)
                }
                self.store.refresh()
                self.isRunning = false
                self.runningID = nil
                self.runningActivity = nil
                self.runNext()
            }
        }
    }

    private func finishFailure(item: TranscriptItem, reason: String, setupIssue: SetupIssue?,
                               backend: SummaryBackend, failureTrip: Int) {
        jobs[item.id] = .failed(reason)
        setSummaryStatus(.failed, for: item)
        consecutiveFailures += 1
        switch (backend, setupIssue) {
        case (.claude, .notInstalled): ClaudeConnection.shared.refresh()
        case (.claude, .notLoggedIn): ClaudeConnection.shared.noteAuthFailure(detail: reason)
        case (.grok, .notInstalled): GrokConnection.shared.refresh()
        case (.grok, .notLoggedIn): GrokConnection.shared.noteAuthFailure(detail: reason)
        case (.composer25, .notInstalled), (.composer25Fast, .notInstalled),
             (.cursorGrok45, .notInstalled), (.cursorGrok45Fast, .notInstalled):
            CursorConnection.shared.refresh()
        case (.composer25, .notLoggedIn), (.composer25Fast, .notLoggedIn),
             (.cursorGrok45, .notLoggedIn), (.cursorGrok45Fast, .notLoggedIn):
            CursorConnection.shared.noteAuthFailure(detail: reason)
        default: break
        }
        AppLog.log("Summary: failed for \(item.url.lastPathComponent) (\(backend.displayName)) — \(reason)", category: "summary")
        if consecutiveFailures >= failureTrip {
            tripThrottle(reason: .repeatedFailures, resumeAt: nil)
        }
        store.refresh()
        isRunning = false
        runningID = nil
        runningActivity = nil
        runNext()
    }

    private static func noteBackendSuccess(_ backend: SummaryBackend) {
        switch backend {
        case .claude: ClaudeConnection.shared.noteRunSucceeded()
        case .grok: GrokConnection.shared.noteRunSucceeded()
        case .local: break
        case .composer25, .composer25Fast, .cursorGrok45, .cursorGrok45Fast:
            CursorConnection.shared.noteRunSucceeded()
        }
    }

    nonisolated private static func runBackend(
        _ backend: SummaryBackend,
        prompt: String,
        claudeBinary: String,
        claudeModel: String,
        grokBinary: String,
        grokModel: String,
        cursorBinary: String,
        onActivity: @escaping @Sendable (String) -> Void
    ) -> RunResult {
        switch backend {
        case .claude:
            return runClaudeStreaming(binary: claudeBinary, prompt: prompt, model: claudeModel, onActivity: onActivity)
        case .grok:
            return runGrok(binary: grokBinary, prompt: prompt, model: grokModel)
        case .local:
            return .failure(reason: "Local Qwen is not supported in the v2 writer/checker roles yet.", setupIssue: nil)
        case .composer25, .composer25Fast, .cursorGrok45, .cursorGrok45Fast:
            return runCursorAgent(binary: cursorBinary, prompt: prompt, model: backend.rawValue)
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
    private static let runTimeout: TimeInterval = 600   // 10 minutes

    /// A flag the watchdog flips so the caller can tell a timeout-kill from a real exit-1.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func trip() { lock.lock(); v = true; lock.unlock() }
        var tripped: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

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
        onActivity: @escaping @Sendable (String) -> Void
    ) -> RunResult {
        let built: (process: Process, stdout: Pipe, stderr: Pipe)
        do {
            built = try ClaudeRunner.makeRawSummaryStreamProcess(binaryPath: binary, prompt: prompt, model: model)
        } catch let e as ClaudeRunner.RunError {
            if case .binaryNotFound = e {
                return .failure(reason: e.localizedDescription, setupIssue: .notInstalled)
            }
            return .failure(reason: e.localizedDescription, setupIssue: nil)
        } catch {
            return .failure(reason: error.localizedDescription, setupIssue: nil)
        }
        do { try built.process.run() }
        catch { return .failure(reason: "Failed to launch claude: \(error.localizedDescription)", setupIssue: nil) }

        // Watchdog: terminate the process if it overruns the cap. Terminating closes the
        // write-end of the pipe, so availableData returns empty and the read loop exits
        // naturally — no extra synchronisation needed.
        let flag = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            guard built.process.isRunning else { return }
            flag.trip()
            built.process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + runTimeout, execute: watchdog)

        // Incremental NDJSON read — same pattern as NotesGenerator's proven loop.
        let handle = built.stdout.fileHandleForReading
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

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }   // EOF (process exited or was terminated)

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

        built.process.waitUntilExit()
        watchdog.cancel()

        if flag.tripped {
            return .failure(reason: "Summary timed out after \(Int(runTimeout / 60)) min — retry.", setupIssue: nil)
        }

        let code = built.process.terminationStatus
        let errData = built.stderr.fileHandleForReading.readDataToEndOfFile()
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

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
                                : .success(noteText, usage)
    }

    /// Runs `grok -p` with `--output-format json`, parsing the final `.text` field as
    /// the staged note body. Same timeout / usage-limit / auth classification as Claude.
    private nonisolated static func runGrok(binary: String, prompt: String, model: String) -> RunResult {
        let built: (process: Process, stdout: Pipe, stderr: Pipe)
        do {
            built = try GrokRunner.makeRawSummaryProcess(binaryPath: binary, prompt: prompt, model: model)
        } catch let e as GrokRunner.RunError {
            if case .binaryNotFound = e {
                return .failure(reason: e.localizedDescription, setupIssue: .notInstalled)
            }
            return .failure(reason: e.localizedDescription, setupIssue: nil)
        } catch {
            return .failure(reason: error.localizedDescription, setupIssue: nil)
        }
        do { try built.process.run() }
        catch { return .failure(reason: "Failed to launch grok: \(error.localizedDescription)", setupIssue: nil) }

        let flag = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            guard built.process.isRunning else { return }
            flag.trip()
            built.process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + runTimeout, execute: watchdog)

        let outData = built.stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = built.stderr.fileHandleForReading.readDataToEndOfFile()
        built.process.waitUntilExit()
        watchdog.cancel()

        if flag.tripped {
            return .failure(reason: "Summary timed out after \(Int(runTimeout / 60)) min — retry.", setupIssue: nil)
        }

        let code = built.process.terminationStatus
        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let trip = ClaudeUsageLimit.detect(stdout: out, stderr: err, exitCode: code) {
            return .usageLimited(trip)
        }

        let lower = (out + "\n" + err).lowercased()
        let looksAuth = lower.contains("not logged in")
            || lower.contains("please log in")
            || lower.contains("unauthorized")
            || lower.contains("authentication")
            || lower.contains("sign in")
            || lower.contains("login required")

        switch GrokRunner.parseJSONResult(stdout: out) {
        case .text(let note) where code == 0:
            return .success(GrokRunner.sanitizeNoteText(note), nil)
        case .error(let msg):
            if looksAuth || Self.looksLikeAuthMessage(msg) {
                return .failure(
                    reason: "Grok isn't logged in. Open Settings → Summary → Grok to log in, then retry.",
                    setupIssue: .notLoggedIn)
            }
            return .failure(reason: String(msg.prefix(240)), setupIssue: nil)
        case .text, .unparseable:
            if code != 0 {
                if looksAuth {
                    return .failure(
                        reason: "Grok isn't logged in. Open Settings → Summary → Grok to log in, then retry.",
                        setupIssue: .notLoggedIn)
                }
                let detail = err.isEmpty ? (out.isEmpty ? "grok exited with code \(code)" : out) : err
                return .failure(reason: String(detail.prefix(240)), setupIssue: nil)
            }
            // Exit 0 but non-JSON: treat raw stdout as the note if it looks like markdown.
            let plain = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty, plain.first != "{" {
                return .success(GrokRunner.sanitizeNoteText(plain), nil)
            }
            return .failure(reason: "grok produced no usable output.", setupIssue: nil)
        }
    }

    nonisolated private static func looksLikeAuthMessage(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("not logged in")
            || lower.contains("unauthorized")
            || lower.contains("authentication")
            || lower.contains("login")
    }

    /// Runs `cursor agent -p --mode ask --output-format json` for Composer / Cursor Grok models.
    private nonisolated static func runCursorAgent(binary: String, prompt: String, model: String) -> RunResult {
        let built: (process: Process, stdout: Pipe, stderr: Pipe)
        do {
            built = try CursorAgentRunner.makeRawSummaryProcess(binaryPath: binary, prompt: prompt, model: model)
        } catch let e as CursorAgentRunner.RunError {
            if case .binaryNotFound = e {
                return .failure(reason: e.localizedDescription, setupIssue: .notInstalled)
            }
            return .failure(reason: e.localizedDescription, setupIssue: nil)
        } catch {
            return .failure(reason: error.localizedDescription, setupIssue: nil)
        }
        do { try built.process.run() }
        catch { return .failure(reason: "Failed to launch cursor agent: \(error.localizedDescription)", setupIssue: nil) }

        let flag = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            guard built.process.isRunning else { return }
            flag.trip()
            built.process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + runTimeout, execute: watchdog)

        let outData = built.stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = built.stderr.fileHandleForReading.readDataToEndOfFile()
        built.process.waitUntilExit()
        watchdog.cancel()

        if flag.tripped {
            return .failure(reason: "Summary timed out after \(Int(runTimeout / 60)) min — retry.", setupIssue: nil)
        }

        let code = built.process.terminationStatus
        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let trip = ClaudeUsageLimit.detect(stdout: out, stderr: err, exitCode: code) {
            return .usageLimited(trip)
        }

        let lower = (out + "\n" + err).lowercased()
        let looksAuth = lower.contains("not logged in")
            || lower.contains("please log in")
            || lower.contains("unauthorized")
            || lower.contains("authentication")
            || lower.contains("sign in")
            || lower.contains("login required")
            || lower.contains("api key")

        switch CursorAgentRunner.parseJSONResult(stdout: out) {
        case .text(let note) where code == 0:
            return .success(CursorAgentRunner.sanitizeNoteText(note), nil)
        case .error(let msg):
            if looksAuth || Self.looksLikeAuthMessage(msg) {
                return .failure(
                    reason: "Cursor isn't logged in. Run `cursor agent` once in Terminal to sign in, then retry.",
                    setupIssue: .notLoggedIn)
            }
            return .failure(reason: String(msg.prefix(240)), setupIssue: nil)
        case .text, .unparseable:
            if code != 0 {
                if looksAuth {
                    return .failure(
                        reason: "Cursor isn't logged in. Run `cursor agent` once in Terminal to sign in, then retry.",
                        setupIssue: .notLoggedIn)
                }
                let detail = err.isEmpty ? (out.isEmpty ? "cursor agent exited with code \(code)" : out) : err
                return .failure(reason: String(detail.prefix(240)), setupIssue: nil)
            }
            let plain = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty, plain.first != "{" {
                return .success(CursorAgentRunner.sanitizeNoteText(plain), nil)
            }
            return .failure(reason: "cursor agent produced no usable output.", setupIssue: nil)
        }
    }

    /// Runs the on-device MLX/Qwen summarizer. Unloads WhisperKit first when possible to free GPU RAM.
    private nonisolated static func runLocal(
        prompt: String,
        onActivity: @escaping @Sendable (String) -> Void
    ) async -> RunResult {
        onActivity("Loading local model…")
        do {
            let text = try await Task { @MainActor in
                await RecordingController.shared.prepareForLocalSummary()
                onActivity("Qwen is writing…")
                return try await LocalSummaryRunner.shared.summarize(prompt: prompt)
            }.value
            return text.isEmpty
                ? .failure(reason: "Local model produced no output.", setupIssue: nil)
                : .success(text, nil)
        } catch let e as SummaryError {
            return .failure(reason: e.localizedDescription, setupIssue: nil)
        } catch {
            return .failure(reason: error.localizedDescription, setupIssue: nil)
        }
    }

    // MARK: Compare harness (shared runners)

    /// Outcome shared with `SummaryComparison` (avoids `Swift.Result` + `Error` boilerplate).
    enum CompareGenerateResult: Sendable {
        case ok(String)
        case failed(String)
    }

    /// Thin wrappers used by `SummaryComparison` so the compare window and the queue
    /// share the same CLI invocation + parsing.
    nonisolated static func runClaudeForCompare(binary: String, prompt: String, model: String) -> CompareGenerateResult {
        switch runClaudeStreaming(binary: binary, prompt: prompt, model: model, onActivity: { _ in }) {
        case .success(let text, _): return .ok(text)
        case .usageLimited(let trip): return .failed("Usage limit: \(trip.matchedPhrase)")
        case .failure(let reason, _): return .failed(reason)
        }
    }

    nonisolated static func runGrokForCompare(binary: String, prompt: String, model: String) -> CompareGenerateResult {
        switch runGrok(binary: binary, prompt: prompt, model: model) {
        case .success(let text, _): return .ok(text)
        case .usageLimited(let trip): return .failed("Usage limit: \(trip.matchedPhrase)")
        case .failure(let reason, _): return .failed(reason)
        }
    }

    nonisolated static func runCursorForCompare(binary: String, prompt: String, model: String) -> CompareGenerateResult {
        switch runCursorAgent(binary: binary, prompt: prompt, model: model) {
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
                                       transcriptSource: transcriptText)
        do {
            try content.write(to: noteURL, atomically: true, encoding: .utf8)
        } catch {
            AppLog.log("Summary: compare commit write failed — \(error.localizedDescription)", category: "summary")
            return nil
        }

        // Move to Processed if still unprocessed; otherwise just update note: path.
        let moved: URL
        if item.isProcessed {
            moved = item.url
            TranscriptWriter.updateFrontmatter(at: moved) { $0.note = noteURL.path; $0.filing = dest }
        } else {
            moved = store.moveToProcessed(item, notePath: noteURL.path)
        }
        crossLinkSummaryOntoRaw(summaryURL: noteURL, rawURL: moved)
        Self.removeAllStaging(for: item.url)
        jobs[item.id] = nil
        setSummaryStatus(.done, for: item)
        AppLog.log("Summary: compare-filed \(noteURL.lastPathComponent) (overwrite=\(overwriteExisting))", category: "summary")
        store.refresh()
        return noteURL
    }

    /// Blocking text-output variant — kept for reference while streaming is validated.
    private nonisolated static func runClaude(binary: String, prompt: String, model: String) -> RunResult {
        let built: (process: Process, stdout: Pipe, stderr: Pipe)
        do {
            built = try ClaudeRunner.makeRawSummaryProcess(binaryPath: binary, prompt: prompt, model: model)
        } catch {
            return .failure(reason: error.localizedDescription, setupIssue: nil)
        }
        do { try built.process.run() }
        catch { return .failure(reason: "Failed to launch claude: \(error.localizedDescription)", setupIssue: nil) }

        // Watchdog: terminate the process if it overruns the cap. The pipe reads below
        // then unblock (EOF on the closed handles) and we surface a timeout failure.
        let flag = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            guard built.process.isRunning else { return }
            flag.trip()
            built.process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + runTimeout, execute: watchdog)

        let outData = built.stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = built.stderr.fileHandleForReading.readDataToEndOfFile()
        built.process.waitUntilExit()
        watchdog.cancel()

        if flag.tripped {
            return .failure(reason: "Summary timed out after \(Int(runTimeout / 60)) min — retry.", setupIssue: nil)
        }
        let code = built.process.terminationStatus
        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard code == 0 else {
            // Distinguish a usage/rate limit (→ pause + retry) from a plain failure.
            if let trip = ClaudeUsageLimit.detect(stdout: out, stderr: err, exitCode: code) {
                return .usageLimited(trip)
            }
            return .failure(reason: err.isEmpty ? "claude exited with code \(code)" : String(err.prefix(240)), setupIssue: nil)
        }
        return out.isEmpty ? .failure(reason: "claude produced no output.", setupIssue: nil) : .success(out, nil)
    }

    private enum RunResult {
        case success(String, ClaudeStreamParser.Usage?)
        case usageLimited(ClaudeUsageLimit.Trip)
        case failure(reason: String, setupIssue: SetupIssue?)
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
                                       transcriptSource: transcriptText)
        do {
            try content.write(to: noteURL, atomically: true, encoding: .utf8)
        } catch {
            AppLog.log("Summary: commit write failed — \(error.localizedDescription)", category: "summary")
            return nil
        }
        let moved = store.moveToProcessed(item, notePath: noteURL.path)
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

        AppLog.log("Summary: committed \(noteURL.lastPathComponent) → \(dest.isEmpty ? "(vault root)" : dest)", category: "summary")
        store.refresh()
        return noteURL
    }

    /// Builds the filed note: YAML frontmatter + summary body + inline raw transcript.
    /// `transcriptSource` is the full transcript file text (frontmatter allowed); only the
    /// `## Transcript` / manual-notes sections are appended. Idempotent if `body` already
    /// contains a `## Raw Transcript` section (stripped first).
    nonisolated static func composeNote(item: TranscriptItem, destination: String, body: String,
                            transcriptSource: String) -> String {
        var summary = strippingRawTranscriptSection(body)
        // Drop a leftover wiki-link footer from older commits.
        summary = strippingRawTranscriptWikiLink(summary)

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
        return headed.trimmingCharacters(in: CharacterSet.newlines) + "\n" + appendix.joined(separator: "\n")
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
