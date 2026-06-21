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
final class MicCapture {
    // MARK: - Engine & state (rebuildable)

    private var engine = AVAudioEngine()

    /// True after `start()` and false after `stop()`. Guards rebuilds.
    private var isRunning = false
    /// Guards against overlapping rebuild attempts (set on `rebuildQueue`).
    private var isRebuilding = false

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

        AppLog.log("mic capture started — \(format.sampleRate)Hz/\(format.channelCount)ch", category: "audio")
    }

    func stop() {
        guard isRunning else { return }
        // Set isRunning = false first so any queued rebuild bails out.
        isRunning = false

        stopWatchdog()
        stopObserver()

        // Serialize teardown with any in-flight rebuild.
        rebuildQueue.sync {
            tearDownEngine()
        }

        // Flush any staged frames that haven't been written to disk yet.
        // Must happen after teardown (tap is gone, no concurrent writes).
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

            currentArchiver?.append(buffer)
            if let floats = currentResampler?.resample(buffer), !floats.isEmpty {
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

        let outageStart = Date()

        // 1. Measure outage from the last known buffer arrival.
        os_unfair_lock_lock(&tapLock)
        let lastBuffer = lastBufferDate
        os_unfair_lock_unlock(&tapLock)
        let outageSeconds = max(0, outageStart.timeIntervalSince(lastBuffer))

        // 2. Tear down the current engine (stop, remove tap).
        tearDownEngine()

        // 3. Build a fresh engine.
        let freshEngine = AVAudioEngine()
        engine = freshEngine

        // 4. Read the new input format.
        let format = freshEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            AppLog.log("mic rebuild: input unavailable (rate=0) — watchdog will retry", category: "audio")
            return
        }

        // 5. Build new capture resources.
        let newResampler = AudioResampler(inputFormat: format)

        // 6. Update the archiver's converter and pad the silence gap.
        //    Must happen AFTER teardown (no concurrent tap writes) and BEFORE
        //    the new tap starts writing.
        if let archiver {
            archiver.updateSourceFormat(format)
            if outageSeconds > 0 {
                archiver.appendSilence(seconds: outageSeconds)
            }
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
