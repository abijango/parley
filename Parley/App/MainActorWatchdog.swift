import Foundation

/// Detects a wedged main actor while recording and captures the live process's
/// stacks, so a freeze can be diagnosed instead of only noticed.
///
/// Why this exists: on 2026-08-04 the app blocked mid-recording for 11m45s. Every
/// main-actor timer stopped output in the same instant, the detached ASR mixer loop
/// stalled at its `await` back onto `@MainActor FluidAudioEngine`, and audio capture
/// (off-main) carried on regardless. macOS filed no CPU-pressure report — the thread
/// was parked, not spinning — and a force quit leaves no crash log, so the block left
/// behind nothing that named what the main thread was waiting on. See
/// `docs/RECORDING_FREEZE_INVESTIGATION.md`.
///
/// Mechanism: a timer on a utility queue pings the main queue each tick and measures
/// how long the pong takes to come back. Past `stallThreshold` it shells out to
/// `/usr/bin/sample` against our own pid; a sample of a blocked process *is* the
/// diagnosis. Only runs while recording — the failure we're chasing is session-scoped,
/// and an app-napped idle app would otherwise look identical to a freeze on wake.
///
/// Findings go to `~/Library/Logs/<App>/freeze.log` with a **synchronous** write, not
/// through `AppLog`: that logger enqueues on a serial queue, and anything still queued
/// is discarded on SIGKILL — which is exactly how these sessions end.
final class MainActorWatchdog {
    static let shared = MainActorWatchdog()

    // MARK: - Tuning

    /// Injectable so tests can drive the same mechanism on a sub-second budget.
    struct Config {
        /// Main-queue round-trip beyond this is a stall worth capturing. Well above any
        /// legitimate hitch (model-load hops, a heavy History derivation) so a slow
        /// frame never trips it.
        var stallThreshold: TimeInterval = 5
        var tickInterval: TimeInterval = 1
        /// Seconds of stacks to collect. Long enough to distinguish a persistent block
        /// from a one-off hitch that resolved mid-capture.
        var sampleSeconds = 5
        /// Minimum spacing between captures within one freeze.
        var captureCooldown: TimeInterval = 120
        /// Hard cap per freeze. The cooldown alone is not enough: a 98-minute freeze on
        /// 2026-08-07 wrote ~50 captures at ~22 MB each. The first few samples of a
        /// freeze say everything — a wedged main thread does not change its mind — so
        /// there is no diagnostic value in the rest, only disk.
        var maxCapturesPerFreeze = 3
        /// Newest-N retention across all freezes, pruned after each write. Same reason:
        /// captures are ~22 MB and only the recent ones are ever read.
        var retainedCaptures = 8
        var directory: URL = AppLog.directory
        /// Mirror to `AppLog` as well as the durable inline write. Off in tests.
        var mirrorToAppLog = true
    }

    private let config: Config

    /// Where the durable findings land. Written synchronously — see below.
    var logURL: URL { config.directory.appendingPathComponent("freeze.log") }

    // MARK: - Queue-confined state
    //
    // Everything below is touched only on `queue` (the timer's own target queue), so
    // no locking is needed. `start`/`stop` hop onto it rather than mutating directly.

    private let queue = DispatchQueue(label: "\(AppInfo.name).mainactor-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// When the outstanding ping was sent; `nil` once the main queue answers it.
    private var pingSentAt: Date?
    /// Set while a stall is in progress, so recovery can report the total duration.
    private var stalledSince: Date?
    private var lastCaptureAt: Date?
    private var capturing = false
    /// Captures written during the current stall; reset when the main queue recovers.
    private var capturesThisFreeze = 0

    init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            pingSentAt = nil
            stalledSince = nil
            lastCaptureAt = nil

            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + config.tickInterval, repeating: config.tickInterval)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            pingSentAt = nil
            stalledSince = nil
        }
    }

    // MARK: - Detection

    private func tick() {
        let now = Date()

        // A ping is still outstanding — the main queue hasn't drained our closure.
        if let sent = pingSentAt {
            let stall = now.timeIntervalSince(sent)
            guard stall >= config.stallThreshold else { return }
            if stalledSince == nil { stalledSince = sent }
            capture(stall: stall)
            return
        }

        // The previous ping came back. Report the end of any stall we announced.
        if let since = stalledSince {
            record("main actor recovered after \(Self.seconds(now.timeIntervalSince(since)))")
            stalledSince = nil
            capturesThisFreeze = 0
        }

        pingSentAt = now
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queue.async { self.pingSentAt = nil }
        }
    }

    /// Run `sample` against ourselves. Blocks `queue` for `sampleSeconds`, which is
    /// deliberate: the timer coalesces, and there is nothing else for it to do while
    /// the main actor is wedged.
    /// Whether a stalled tick should spend a capture. Pure and separate from `capture`
    /// so the limits can be tested exactly — driving them end-to-end would depend on
    /// `sample`'s symbolization time, which varies by seconds and made the test flaky.
    enum CaptureDecision: Equatable {
        case capture
        /// Cap just reached; the caller should say so once, then stay quiet.
        case capped
        /// Cap already announced, or too soon since the last capture.
        case skip
    }

    static func captureDecision(capturesThisFreeze: Int, maxPerFreeze: Int,
                                lastCaptureAt: Date?, now: Date,
                                cooldown: TimeInterval) -> CaptureDecision {
        if capturesThisFreeze > maxPerFreeze { return .skip }       // already announced
        if capturesThisFreeze == maxPerFreeze { return .capped }
        if let last = lastCaptureAt, now.timeIntervalSince(last) < cooldown { return .skip }
        return .capture
    }

    private func capture(stall: TimeInterval) {
        guard !capturing else { return }
        let now = Date()
        switch Self.captureDecision(capturesThisFreeze: capturesThisFreeze,
                                    maxPerFreeze: config.maxCapturesPerFreeze,
                                    lastCaptureAt: lastCaptureAt, now: now,
                                    cooldown: config.captureCooldown) {
        case .skip:
            return
        case .capped:
            capturesThisFreeze += 1     // step past the cap so this logs exactly once
            record("capture cap reached (\(config.maxCapturesPerFreeze)) — still stalled, no further samples this freeze")
            return
        case .capture:
            break
        }
        capturing = true
        defer { capturing = false }
        lastCaptureAt = now
        capturesThisFreeze += 1

        let url = config.directory
            .appendingPathComponent("freeze-\(Self.fileStamp.string(from: Date())).txt")
        record("main actor stalled \(Self.seconds(stall)) — sampling stacks to \(url.path)")

        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            String(config.sampleSeconds),
            "-file", url.path,
        ]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        do {
            try sample.run()
        } catch {
            record("stack capture failed to launch: \(error.localizedDescription)")
            return
        }
        sample.waitUntilExit()
        record(sample.terminationStatus == 0
               ? "stack capture written — \(url.lastPathComponent)"
               : "stack capture exited \(sample.terminationStatus) — no usable sample")
        pruneCaptures()
    }

    /// Keep only the newest `retainedCaptures` samples. Sorting is by the timestamp in
    /// the filename, which sorts lexicographically because `fileStamp` is zero-padded
    /// big-endian — no `stat` per file needed. Internal so tests can drive it against
    /// fixture files rather than waiting on real captures.
    func pruneCaptures() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: config.directory.path)) ?? []
        let captures = names
            .filter { $0.hasPrefix("freeze-") && $0.hasSuffix(".txt") }
            .sorted()
        guard captures.count > config.retainedCaptures else { return }
        let stale = captures.dropLast(config.retainedCaptures)
        for name in stale {
            try? FileManager.default.removeItem(at: config.directory.appendingPathComponent(name))
        }
        record("pruned \(stale.count) old capture(s), keeping newest \(config.retainedCaptures)")
    }

    // MARK: - Synchronous logging
    //
    // `AppLog` is mirrored for convenience, but the durable copy is written inline:
    // a freeze normally ends in a force quit, and SIGKILL discards whatever is sitting
    // on AppLog's serial queue. The formatters are queue-confined (`DateFormatter` is
    // not thread-safe) — only `record`/`capture` touch them, both on `queue`.

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    private static func seconds(_ t: TimeInterval) -> String {
        String(format: "%.1fs", t)
    }

    private func record(_ message: String) {
        if config.mirrorToAppLog { AppLog.log(message, category: "freeze") }

        try? FileManager.default.createDirectory(at: config.directory, withIntermediateDirectories: true)
        let url = logURL
        guard let data = "\(Self.stamp.string(from: Date())) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
