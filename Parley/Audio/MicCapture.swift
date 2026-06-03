import Foundation
import AVFoundation

/// Captures the local microphone via `AVAudioEngine` → the "Me" track.
///
/// The tap block runs on a real-time audio thread: it only archives the raw
/// buffer and pushes resampled 16 kHz mono floats into the ring buffer. No
/// allocation-heavy or blocking work belongs here.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let ringBuffer: AudioRingBuffer
    private var resampler: AudioResampler?
    private var archiver: AudioArchiver?
    private let archiveURL: URL?
    private var isRunning = false

    let meter = LevelMeter()
    var level: Float { meter.level }

    init(ringBuffer: AudioRingBuffer, archiveURL: URL?) {
        self.ringBuffer = ringBuffer
        self.archiveURL = archiveURL
    }

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "MicCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input format available"])
        }

        resampler = AudioResampler(inputFormat: format)
        if let archiveURL {
            archiver = try? AudioArchiver(url: archiveURL, format: format)
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.archiver?.append(buffer)
            if let floats = self.resampler?.resample(buffer), !floats.isEmpty {
                floats.withUnsafeBufferPointer { self.ringBuffer.write($0) }
                self.meter.update(floats)
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        archiver = nil
        resampler = nil
        isRunning = false
    }
}
