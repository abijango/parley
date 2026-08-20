import Foundation
import AVFoundation
import os

/// Captures the local microphone via `AVAudioEngine` → the "Me" track.
///
/// The tap block runs on a real-time audio thread: it only archives the raw
/// buffer and pushes resampled 16 kHz mono floats into the ring buffer. No
/// allocation-heavy or blocking work belongs here.
///
/// # Device-change recovery
///
/// When the audio input device changes (Bluetooth connect/disconnect, headset swap,
/// default-input change) `AVAudioEngine` posts `AVAudioEngineConfigurationChange`
/// and stops itself. `MicCapture` observes that notification and also runs a
/// silence watchdog: if no buffer arrives for 3 s, it rebuilds the engine
/// unconditionally — catching device changes AND any other stall.
///
/// Recovery keeps writing into the same `mic.caf` file (AudioMix overlays by
/// sample index from 0, so a continuation file won't be mixed in). The outage
/// gap is silence-padded in the archive so subsequent audio stays sample-aligned.
///
/// `@unchecked Sendable`: every field crossing a thread boundary is already behind
/// an explicit lock (`stateLock`, `tapLock`, `modeLock`) or confined to
/// `rebuildQueue` — the class has always been used concurrently by the tap, the
/// watchdog and the caller.
final class MicCapture: @unchecked Sendable {
    // MARK: - Engine & state (rebuildable)

    private var engine = AVAudioEngine()

    /// True after `start()` and false after `stop()`. Guards rebuilds.
    /// Written by the caller's thread (`start`/`stop`) and read on `rebuildQueue`
    /// (watchdog + rebuild), so it goes through `stateLock` rather than being a
    /// bare cross-thread `Bool`.
    private var _isRunning = false
    private var stateLock = os_unfair_lock()
    /// Guards against overlapping rebuild attempts (set on `rebuildQueue`).
    private var isRebuilding = false

    private var isRunning: Bool {
        get {
            os_unfair_lock_lock(&stateLock)
            defer { os_unfair_lock_unlock(&stateLock) }
            return _isRunning
        }
        set {
            os_unfair_lock_lock(&stateLock)
            _isRunning = newValue
            os_unfair_lock_unlock(&stateLock)
        }
    }

    /// Atomically clears `isRunning`, returning true only to the caller that won
    /// the race. Quit tears down twice — the menu's Quit button, then
    /// `applicationWillTerminate` — and with teardown now asynchronous a plain
    /// check-then-set would let both callers through.
    private func beginStop() -> Bool {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        guard _isRunning else { return false }
        _isRunning = false
        return true
    }

    // MARK: - Serialization

    /// All teardown/rebuild work runs on this queue. Config-change notifications
    /// and the watchdog both dispatch onto it so rebuilds are serialized.
    private let rebuildQueue = DispatchQueue(label: "com.naufalmir.parley.miccapture.rebuild")

    // MARK: - Tap/rebuild synchronization

    /// Protects `resampler` and `archiver` and `lastBufferDate` — the real-time
    /// tap thread reads them; the rebuild thread swaps them.
    /// Critical section is just a reference copy/assign — keep it minimal.
    private var tapLock = os_unfair_lock()

    // MARK: - Capture resources (guarded by tapLock)

    private var resampler: AudioResampler?
    private var archiver: AudioArchiver?
    /// Updated by the tap on every buffer; read by the watchdog.
    private var lastBufferDate: Date = .distantPast

    // MARK: - Fixed state

    private let ringBuffer: AudioRingBuffer
    private let archiveURL: URL?

    // MARK: - Watchdog & observer

    private var watchdogTimer: DispatchSourceTimer?
    private var configObserver: NSObjectProtocol?

    // MARK: - Mic input mode (readable from the real-time tap thread)

    private var _micInputMode: MicInputMode = .regular
    private var modeLock = os_unfair_lock()

    var micInputMode: MicInputMode {
        get {
            os_unfair_lock_lock(&modeLock)
            let mode = _micInputMode
            os_unfair_lock_unlock(&modeLock)
            return mode
        }
        set {
            os_unfair_lock_lock(&modeLock)
            _micInputMode = newValue
            os_unfair_lock_unlock(&modeLock)
        }
    }

    // MARK: - Public

    let meter = LevelMeter()
    var level: Float { meter.level }

    init(ringBuffer: AudioRingBuffer, archiveURL: URL?) {
        self.ringBuffer = ringBuffer
        self.archiveURL = archiveURL
    }

    func start() throws {
        guard !isRunning else { return }

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "MicCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input format available"])
        }

        resampler = AudioResampler(inputFormat: format)
        if let archiveURL {
            archiver = try? AudioArchiver(url: archiveURL, format: format)
        }

        installTap(on: engine, format: format)
        engine.prepare()
        try engine.start()

        // Set lastBufferDate now so the watchdog doesn't fire before the first buffer.
        lastBufferDate = Date()
        isRunning = true

        startWatchdog()
        startObserver()

        AppLog.log(
            "mic capture started — \(format.sampleRate)Hz/\(format.channelCount)ch, mode=\(micInputMode.rawValue)",
            category: "audio"
        )
    }

    /// Stops capture and flushes the archive.
    ///
    /// Teardown is serialized on `rebuildQueue`, so it queues behind any in-flight
    /// `rebuildEngine()` — and a rebuild can sit inside CoreAudio for tens of
    /// seconds while the audio device reconfigures (a Teams call ending does
    /// exactly that). This is `async` for that reason: awaiting it leaves the main
    /// actor free instead of parking the whole UI on `coreaudiod`.
    ///
    /// Callers that go on to read `mic.caf` — the offline ASR pass does — must
    /// await this first. The archive isn't complete until the flush below runs.
    func stop() async {
        guard beginStop() else { return }

        stopWatchdog()
        stopObserver()

        await withCheckedContinuation { continuation in
            rebuildQueue.async { [self] in
                performTeardownAndFlush()
                continuation.resume()
            }
        }
    }

    /// Synchronous stop for `applicationWillTerminate`, which has no way to await.
    /// Waits up to `timeout` for teardown, then proceeds regardless so quit is
    /// never hostage to a wedged `coreaudiod`. Giving up can truncate the tail of
    /// `mic.caf`; a bounded, logged loss beats an unbounded hang.
    func stopBlocking(timeout: TimeInterval = 5) {
        guard beginStop() else { return }

        stopWatchdog()
        stopObserver()

        let done = DispatchSemaphore(value: 0)
        rebuildQueue.async { [self] in
            performTeardownAndFlush()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            AppLog.log(
                "mic stop: teardown still blocked after \(Int(timeout))s — quitting without flushing the tail",
                category: "audio"
            )
        }
    }

    /// Runs on `rebuildQueue`. Order matters: the archiver flushes only once the
    /// tap is gone, since the tap appends from a real-time thread and finalizing
    /// underneath it races.
    private func performTeardownAndFlush() {
        tearDownEngine()
        archiver?.finalize()
    }

    // MARK: - Tap installation

    private func installTap(on engine: AVAudioEngine, format: AVAudioFormat) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            // Copy refs under the lock; do the work outside it to avoid holding
            // the unfair lock across file I/O / resampling (priority inversion risk).
            os_unfair_lock_lock(&self.tapLock)
            let currentResampler = self.resampler
            let currentArchiver = self.archiver
            self.lastBufferDate = Date()
            os_unfair_lock_unlock(&self.tapLock)

            let mode = self.micInputMode
            // Boost the tap buffer before archive + resample. Returns false when the
            // buffer layout can't be mutated in place (rare); fall back to boosting
            // the float samples used by ASR/meters so Room mode still has an effect.
            let boostedBuffer = MicInputGain.apply(to: buffer, mode: mode)

            currentArchiver?.append(buffer)
            if var floats = currentResampler?.resample(buffer), !floats.isEmpty {
                if mode == .room, !boostedBuffer {
                    floats = MicInputGain.apply(floats, mode: .room)
                }
                floats.withUnsafeBufferPointer { self.ringBuffer.write($0) }
                self.meter.update(floats)
            }
        }
    }

    // MARK: - Watchdog

    private static let watchdogInterval: TimeInterval = 1.0
    private static let silenceThreshold: TimeInterval = 3.0

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: rebuildQueue)
        timer.schedule(deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval)
        timer.setEventHandler { [weak self] in
            self?.checkWatchdog()
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func checkWatchdog() {
        guard isRunning, !isRebuilding else { return }

        os_unfair_lock_lock(&tapLock)
        let last = lastBufferDate
        os_unfair_lock_unlock(&tapLock)

        let staleness = Date().timeIntervalSince(last)
        guard staleness >= Self.silenceThreshold else { return }

        AppLog.log("mic watchdog: no buffer for \(String(format: "%.1f", staleness))s — triggering rebuild", category: "audio")
        rebuildEngine()
    }

    // MARK: - Config-change observer

    private func startObserver() {
        // Use object: nil to observe all engines; we filter for our current engine.
        // After a rebuild we get a new engine instance, so filtering by value avoids
        // stale-engine events from firing a second rebuild.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            // Filter: only react to our current engine's notification.
            // The comparison is captured once; if we rebuild before the notification
            // arrives, the new engine is already in self.engine and won't match this
            // stale object — so we safely ignore it.
            // (Debounce: the rebuild itself is re-entrancy-guarded by isRebuilding.)
            guard let notifyingEngine = notification.object as? AVAudioEngine,
                  notifyingEngine === self.engine else { return }
            AppLog.log("mic: AVAudioEngineConfigurationChange received", category: "audio")
            self.rebuildQueue.async { [weak self] in
                self?.rebuildEngine()
            }
        }
        configObserver = observer
    }

    private func stopObserver() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
    }

    // MARK: - Rebuild routine (always runs on rebuildQueue)

    private func rebuildEngine() {
        guard isRunning, !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }

        // 1. Tear down the current engine (stop, remove tap).
        tearDownEngine()

        // 2. Build a fresh engine.
        let freshEngine = AVAudioEngine()
        engine = freshEngine

        // 3. Read the new input format. This is a synchronous IPC into
        //    `coreaudiod`, and when the audio device is mid-reconfiguration it can
        //    block for tens of seconds — 57s was observed on 2026-08-12. Treat
        //    everything below as running at an unknown later time.
        let format = freshEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            AppLog.log("mic rebuild: input unavailable (rate=0) — watchdog will retry", category: "audio")
            return
        }

        // 4. Build new capture resources.
        let newResampler = AudioResampler(inputFormat: format)

        // 5. Update the archiver's converter and pad the silence gap.
        //    Must happen AFTER teardown (no concurrent tap writes) and BEFORE
        //    the new tap starts writing.
        //
        //    Measure the outage HERE rather than on entry: step 3 may have blocked
        //    for a minute, and padding a figure sampled before it leaves `mic.caf`
        //    short by however long CoreAudio stalled — which desynchronizes it from
        //    `system.caf` for the rest of the recording.
        os_unfair_lock_lock(&tapLock)
        let outageSeconds = max(0, Date().timeIntervalSince(lastBufferDate))
        os_unfair_lock_unlock(&tapLock)

        if let archiver {
            archiver.updateSourceFormat(format)
            if outageSeconds > 0 {
                archiver.appendSilence(seconds: outageSeconds)
            }
        }

        // 6. If a stop landed while step 3 was blocked, quit now — but only after
        //    the padding above, so the archive stays wall-clock aligned. Bailing any
        //    earlier would drop the padding on exactly the path that needs it most.
        //    `stop()`'s own teardown is already queued behind us on `rebuildQueue`.
        guard isRunning else {
            AppLog.log(
                "mic rebuild: stopped while CoreAudio was blocked — padded \(String(format: "%.2f", outageSeconds))s and abandoned the rebuild",
                category: "audio"
            )
            return
        }

        // 7. Swap resampler reference under the lock, then install new tap.
        os_unfair_lock_lock(&tapLock)
        resampler = newResampler
        // archiver is unchanged (same object, updated format)
        lastBufferDate = Date()   // reset so the watchdog doesn't re-fire immediately
        os_unfair_lock_unlock(&tapLock)

        installTap(on: freshEngine, format: format)
        freshEngine.prepare()

        do {
            try freshEngine.start()
        } catch {
            AppLog.log("mic rebuild: engine.start() failed: \(error.localizedDescription) — watchdog will retry", category: "audio")
            return
        }

        // Re-register the config observer for the new engine.
        stopObserver()
        startObserver()

        AppLog.log(
            "Mic recovered — input changed to \(format.sampleRate)Hz/\(format.channelCount)ch, padded \(String(format: "%.2f", outageSeconds))s gap",
            category: "audio"
        )
    }

    // MARK: - Teardown helper

    private func tearDownEngine() {
        // removeTap is safe to call even if no tap is installed.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
