import Foundation
import AppKit
import UserNotifications

/// Drives the single (Claude, raw-prompt) meeting-summary flow asynchronously:
/// generate in the background → stage the result → user reviews in History → commit to the
/// vault (or discard / regenerate). Replaces the old skill-based auto-run. "Ready for review"
/// is represented purely by the presence of a staging file (`.staging/<transcript>.md`), so it
/// survives app restarts; in-flight jobs are tracked in `jobs` only while running.
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

    /// The staging file where a transcript's pending summary lives (exists ⇒ ready to review).
    @MainActor static func stagingURL(for transcriptURL: URL) -> URL {
        let base = transcriptURL.deletingPathExtension().lastPathComponent
        return AppPaths.stagingURL.appendingPathComponent("\(base).md")
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
                  !FileManager.default.fileExists(atPath: Self.stagingURL(for: item.url).path) else { return }
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
            if FileManager.default.fileExists(atPath: Self.stagingURL(for: url).path) { return nil }
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

    /// Queue a background summary for `item` (no-op if already pending or already staged).
    func summarize(_ item: TranscriptItem) {
        guard jobs[item.id] == nil else { return }
        if FileManager.default.fileExists(atPath: Self.stagingURL(for: item.url).path) { return }
        jobs[item.id] = .pending(since: Date())
        setSummaryStatus(.queued, for: item)
        queue.append(item)
        runNext()
    }

    func regenerate(_ item: TranscriptItem) {
        try? FileManager.default.removeItem(at: Self.stagingURL(for: item.url))
        jobs[item.id] = nil
        store.refresh()
        summarize(item)
    }

    func discard(_ item: TranscriptItem) {
        try? FileManager.default.removeItem(at: Self.stagingURL(for: item.url))
        jobs[item.id] = nil
        queue.removeAll { $0.id == item.id }
        setSummaryStatus(nil, for: item)
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
        runningActivity = "Starting Claude…"
        setSummaryStatus(.running, for: item)
        let built = SummaryPromptBuilder.build(
            template: settings.summaryPromptTemplate,
            transcriptURL: item.url,
            attendees: item.meta.attendees.joined(separator: ", "),
            destination: item.meta.filing,
            contactsURL: settings.contactsURL)
        let binary = settings.claudeBinaryPath
        let model = settings.claudeModel
        let staged = Self.stagingURL(for: item.url)
        let failureTrip = settings.summaryFailureTripThreshold
        AppLog.log("Summary: started for \(item.url.lastPathComponent) (model=\(model))", category: "summary")

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.runClaudeStreaming(binary: binary, prompt: built.prompt, model: model,
                onActivity: { line in
                    Task { @MainActor [weak self] in self?.runningActivity = line }
                })
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
                        ClaudeUsageStore.shared.record(usage)         // tally what the app spent
                        ClaudeConnection.shared.noteRunSucceeded()    // a real success ⇒ connected
                        Self.notifyReady(title: item.meta.title)
                        AppLog.log("Summary: ready for review — \(staged.lastPathComponent)", category: "summary")
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
                    ClaudeConnection.shared.noteUsageLimited(resumeAt: trip.resumeAt)
                    AppLog.log("Summary: Claude usage/rate limit hit (\(trip.matchedPhrase)) — pausing queue", category: "summary")
                    self.tripThrottle(reason: .usageLimit, resumeAt: trip.resumeAt)
                case .failure(let reason, let setupIssue):
                    self.jobs[item.id] = .failed(reason)
                    self.setSummaryStatus(.failed, for: item)
                    self.consecutiveFailures += 1
                    // Keep the connection badge honest so the user is pointed at setup.
                    switch setupIssue {
                    case .notInstalled:  ClaudeConnection.shared.refresh()
                    case .notLoggedIn:   ClaudeConnection.shared.noteAuthFailure(detail: reason)
                    case .none:          break
                    }
                    AppLog.log("Summary: failed for \(item.url.lastPathComponent) — \(reason)", category: "summary")
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

    /// The summary for this item is being generated right now.
    func isSummarizing(_ item: TranscriptItem) -> Bool { runningID == item.id }

    /// The item is waiting in the summary queue, or in the pending bulk-confirm batch.
    func isPendingSummary(_ item: TranscriptItem) -> Bool {
        queue.contains { $0.id == item.id }
            || (pendingBulkConfirm?.items.contains { $0.id == item.id } ?? false)
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

    /// A failure that maps to a Claude Code connection problem the user can fix, so the
    /// badge + History message can point them at Settings → Summary → Claude.
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
    /// removes the staging file, and opens the note in Obsidian. Returns the written note URL.
    @discardableResult
    func commit(_ item: TranscriptItem, destination: String) -> URL? {
        let staged = Self.stagingURL(for: item.url)
        guard let body = try? String(contentsOf: staged, encoding: .utf8) else {
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

        let content = Self.composeNote(item: item, destination: dest, body: body)
        do {
            try content.write(to: noteURL, atomically: true, encoding: .utf8)
        } catch {
            AppLog.log("Summary: commit write failed — \(error.localizedDescription)", category: "summary")
            return nil
        }
        let moved = store.moveToProcessed(item, notePath: noteURL.path)
        try? FileManager.default.removeItem(at: staged)
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

        openInObsidian(noteURL)
        AppLog.log("Summary: committed \(noteURL.lastPathComponent) → \(dest.isEmpty ? "(vault root)" : dest)", category: "summary")
        store.refresh()
        return noteURL
    }

    private static func composeNote(item: TranscriptItem, destination: String, body: String) -> String {
        if body.hasPrefix("---\n") || body.hasPrefix("---\r\n") { return body }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["---", "title: \(item.meta.title)", "date: \(df.string(from: item.meta.date))"]
        if !item.meta.attendees.isEmpty {
            lines.append("attendees:")
            for a in item.meta.attendees { lines.append("  - \(a)") }
        }
        if !destination.isEmpty { lines.append("filing: \(destination)") }
        lines.append("source: parley-summary")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + body
    }

    private func openInObsidian(_ url: URL) {
        if let obs = NotesGenerator.obsidianOpenURL(for: url, configuredVault: AppSettings.shared.vaultURL) {
            NSWorkspace.shared.open(obs)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
