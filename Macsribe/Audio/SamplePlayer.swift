import Foundation
import AVFoundation

/// Plays a short slice of a recording's archived audio so the user can recognise a
/// speaker before naming them. Uses an `AVAudioEngine` with one player node per
/// track (mic + system), scheduling an exact frame range — robust for arbitrary
/// PCM `.caf` formats, and it simply skips a track that's empty or has no audio at
/// the requested time.
@MainActor
final class SamplePlayer {
    private let engine = AVAudioEngine()
    private var nodes: [AVAudioPlayerNode] = []
    private var stopTimer: Timer?
    private var running = false

    /// Play `files` together from `start` seconds for `(end - start)` seconds.
    func play(files: [URL], start: TimeInterval, end: TimeInterval) {
        stop()
        let duration = max(0.5, end - start)
        var scheduled = 0
        for url in files {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let file = try? AVAudioFile(forReading: url) else {
                AppLog.log("SamplePlayer: cannot open \(url.lastPathComponent)", category: "record"); continue
            }
            let sampleRate = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(max(0, start) * sampleRate)
            guard startFrame < file.length else { continue }   // past end / empty track
            let frames = AVAudioFrameCount(min(Double(file.length - startFrame), duration * sampleRate))
            guard frames > 0 else { continue }

            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            node.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil)
            nodes.append(node)
            scheduled += 1
        }
        guard scheduled > 0 else {
            AppLog.log("SamplePlayer: no audio to play at \(Int(start))s", category: "record"); return
        }
        do {
            try engine.start()
            running = true
            nodes.forEach { $0.play() }
        } catch {
            AppLog.log("SamplePlayer: engine failed to start: \(error.localizedDescription)", category: "record")
            stop(); return
        }
        stopTimer = Timer.scheduledTimer(withTimeInterval: duration + 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Play a raw in-memory mono clip (e.g. a retained voiceprint sample).
    func play(samples: [Float], sampleRate: Double = 16_000) {
        stop()
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) }
        }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        node.scheduleBuffer(buffer, at: nil)
        nodes.append(node)
        do {
            try engine.start()
            running = true
            node.play()
        } catch {
            AppLog.log("SamplePlayer: engine failed to start: \(error.localizedDescription)", category: "record")
            stop(); return
        }
        let duration = Double(samples.count) / sampleRate
        stopTimer = Timer.scheduledTimer(withTimeInterval: duration + 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        stopTimer?.invalidate(); stopTimer = nil
        for node in nodes { node.stop(); engine.detach(node) }
        nodes.removeAll()
        if running { engine.stop(); running = false }
    }
}
