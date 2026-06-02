import Foundation
import WhisperKit

/// Streams one audio track (mic = "Me", system = "Remote") into incremental
/// transcription. Reimplements WhisperKit's confirmed/unconfirmed sliding
/// window so it can run on our own ring buffer rather than WhisperKit's mic.
///
/// Memory is bounded: once audio is confirmed, it's trimmed off the front of the
/// working buffer. A `windowOffset` (seconds dropped) keeps all timestamps
/// correct after a trim, and confirmed segments are stored as absolute times so
/// trimming never disturbs them.
actor TrackPipeline {
    private let track: SpeakerTrack
    private let ring: AudioRingBuffer
    private let service: TranscriptionService
    private let merger: TranscriptMerger
    /// Shared-clock seconds at which this track started — anchors every segment
    /// onto the same timeline as the other track (avoids cross-stream drift).
    private let startElapsed: TimeInterval

    private let sampleRate = Double(WhisperKit.sampleRate)
    private let requiredSegmentsForConfirmation = 2
    private let silenceThreshold: Float = 0.022   // RMS gate for our own simple VAD

    // Buffer bounding
    private let windowSeconds: Double = 40         // trim once the buffer exceeds this
    private let contextSeconds: Double = 2         // keep this much before the confirmed edge
    private let minTrimSeconds: Double = 10        // don't trim in tiny increments
    private let hardCapSeconds: Double = 90        // model-too-slow fallback: skip audio past this

    private var audioSamples: [Float] = []
    private var windowOffset: Double = 0           // seconds trimmed off the front
    private var lastDecodedCount = 0               // buffer-relative sample count at last decode
    private var lastConfirmedTrackEnd: Float = 0   // track-relative seconds
    private var confirmedOut: [Segment] = []       // absolute (shared-clock) confirmed segments
    private var running = false

    init(track: SpeakerTrack,
         ring: AudioRingBuffer,
         service: TranscriptionService,
         merger: TranscriptMerger,
         startElapsed: TimeInterval) {
        self.track = track
        self.ring = ring
        self.service = service
        self.merger = merger
        self.startElapsed = startElapsed
    }

    func run() async {
        running = true
        while running {
            drain()

            // Capture-first: a recording can start (or auto-start on a detected
            // call) while the model is still loading. Until it's ready, keep
            // pulling from the ring so nothing is dropped, but DON'T consume the
            // backlog — hold it so the model transcribes it on arrival and
            // catches up to live. (forceCap still bounds memory if the load is
            // unusually slow; the full audio remains in the .caf archive.)
            guard await service.isReady else {
                forceCapIfOverloaded()
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            forceCapIfOverloaded()
            let newSamples = audioSamples.count - lastDecodedCount
            let newSeconds = Double(newSamples) / sampleRate

            // Need at least ~1s of fresh audio before transcribing.
            guard newSeconds > 1 else {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            // Simple RMS voice gate: skip decoding near-silence.
            if !hasVoice(in: audioSamples.suffix(newSamples)) {
                lastDecodedCount = audioSamples.count
                maybeTrim()
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            lastDecodedCount = audioSamples.count
            let clipFrom = max(0, Float(Double(lastConfirmedTrackEnd) - windowOffset))
            let started = Date()
            do {
                let segments = try await service.transcribe(audioSamples, clipFrom: clipFrom)
                logLatencyIfBehind(decodeSeconds: Date().timeIntervalSince(started), newSeconds: newSeconds)
                await applyConfirmation(segments)
                maybeTrim()
            } catch {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    func stop() {
        running = false
    }

    // MARK: Buffer

    private func drain() {
        let available = ring.availableToRead
        guard available > 0 else { return }
        var buffer = [Float]()
        let count = ring.read(maxCount: available, into: &buffer)
        if count > 0 {
            audioSamples.append(contentsOf: buffer.prefix(count))
        }
    }

    /// Drop already-confirmed audio off the front once the buffer grows past the
    /// window, keeping a little context. Keeps memory flat over a long meeting.
    private func maybeTrim() {
        let bufferSeconds = Double(audioSamples.count) / sampleRate
        guard bufferSeconds > windowSeconds else { return }
        let keepFromTrack = max(0, Double(lastConfirmedTrackEnd) - contextSeconds)
        let dropSeconds = keepFromTrack - windowOffset
        guard dropSeconds >= minTrimSeconds else { return }

        let dropSamples = min(audioSamples.count, Int(dropSeconds * sampleRate))
        guard dropSamples > 0 else { return }
        audioSamples.removeFirst(dropSamples)
        windowOffset += Double(dropSamples) / sampleRate
        lastDecodedCount = max(0, lastDecodedCount - dropSamples)
        AppLog.log("perf [\(track.label)] trimmed \(Int(Double(dropSamples) / sampleRate))s; buffer now \(Int(Double(audioSamples.count) / sampleRate))s", category: "perf")
    }

    /// Real-time fallback: if the model can't keep up and the buffer balloons
    /// past the hard cap, drop the oldest *un-decoded* audio down to the window —
    /// trading a gap in the transcript for staying near real-time + bounded memory.
    private func forceCapIfOverloaded() {
        let bufferSeconds = Double(audioSamples.count) / sampleRate
        guard bufferSeconds > hardCapSeconds else { return }
        let dropSeconds = bufferSeconds - windowSeconds
        let dropSamples = min(audioSamples.count, Int(dropSeconds * sampleRate))
        guard dropSamples > 0 else { return }
        audioSamples.removeFirst(dropSamples)
        windowOffset += Double(dropSamples) / sampleRate
        lastDecodedCount = max(0, lastDecodedCount - dropSamples)
        // We skipped un-decoded audio; advance the confirmed edge to the new front.
        lastConfirmedTrackEnd = max(lastConfirmedTrackEnd, Float(windowOffset))
        AppLog.log("perf [\(track.label)] OVERLOADED — skipped \(Int(dropSeconds))s of un-decoded audio to keep up; the model is too slow for real-time. Use a smaller model.", category: "perf")
    }

    private func hasVoice<S: Sequence>(in samples: S) -> Bool where S.Element == Float {
        var sumSquares: Float = 0
        var n = 0
        for s in samples { sumSquares += s * s; n += 1 }
        guard n > 0 else { return false }
        let rms = (sumSquares / Float(n)).squareRoot()
        return rms > silenceThreshold
    }

    private func logLatencyIfBehind(decodeSeconds: TimeInterval, newSeconds: Double) {
        guard decodeSeconds > newSeconds else { return }   // only when not keeping up
        AppLog.log("perf [\(track.label)] behind real-time: \(String(format: "%.2f", decodeSeconds))s decode for \(String(format: "%.2f", newSeconds))s new audio (buffer \(Int(Double(audioSamples.count) / sampleRate))s)", category: "perf")
    }

    // MARK: Confirmation

    /// WhisperKit's rule: confirm all but the last `requiredSegmentsForConfirmation`
    /// segments; the tail stays tentative. Operates in track-relative time so it
    /// survives buffer trimming.
    private func applyConfirmation(_ segments: [TranscriptionSegment]) async {
        let unconfirmedSegs: [TranscriptionSegment]
        if segments.count > requiredSegmentsForConfirmation {
            let confirmCount = segments.count - requiredSegmentsForConfirmation
            let prefix = Array(segments.prefix(confirmCount))
            unconfirmedSegs = Array(segments.suffix(requiredSegmentsForConfirmation))

            var maxEnd = lastConfirmedTrackEnd
            for seg in prefix {
                let trackEnd = Float(windowOffset) + seg.end
                guard trackEnd > lastConfirmedTrackEnd else { continue }   // already confirmed
                if let converted = convert(seg, confirmed: true) { confirmedOut.append(converted) }
                maxEnd = max(maxEnd, trackEnd)
            }
            lastConfirmedTrackEnd = maxEnd
        } else {
            unconfirmedSegs = segments
        }

        let unconfirmedOut = unconfirmedSegs.compactMap { convert($0, confirmed: false) }
        await merger.update(track: track, confirmed: confirmedOut, unconfirmed: unconfirmedOut)
    }

    /// Maps a WhisperKit segment (buffer-relative) onto the shared clock:
    /// track time = buffer time + windowOffset; shared time = + startElapsed.
    private func convert(_ seg: TranscriptionSegment, confirmed: Bool) -> Segment? {
        let text = Self.cleanText(seg.text)
        guard !text.isEmpty else { return nil }
        return Segment(
            track: track,
            start: startElapsed + windowOffset + TimeInterval(seg.start),
            end: startElapsed + windowOffset + TimeInterval(seg.end),
            text: text,
            confirmed: confirmed
        )
    }

    /// Safety net: strip any residual Whisper special/timestamp tokens like
    /// `<|startoftranscript|>`, `<|en|>`, `<|transcribe|>`, `<|11.02|>`.
    private static func cleanText(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
