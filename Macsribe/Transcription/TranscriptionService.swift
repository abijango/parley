import Foundation
import WhisperKit

/// Serializes access to a single shared WhisperKit model. Both track pipelines
/// call `transcribe`; the `actor` guarantees one decode at a time, keeping
/// memory and Neural Engine contention down versus two model instances.
actor TranscriptionService {
    private var whisperKit: WhisperKit?

    func setModel(_ kit: WhisperKit) {
        whisperKit = kit
    }

    /// Releases the recording-time model reference so the only retained copy is
    /// `ModelManager`'s — letting a model switch actually free the old one.
    func clear() {
        whisperKit = nil
    }

    var isReady: Bool { whisperKit != nil }

    /// Transcribes `samples` (16 kHz mono float), decoding only from `clipFrom`
    /// seconds onward so already-confirmed audio isn't re-processed.
    func transcribe(_ samples: [Float], clipFrom: Float) async throws -> [TranscriptionSegment] {
        guard let whisperKit else { return [] }
        var options = DecodingOptions()
        options.clipTimestamps = [clipFrom]
        options.withoutTimestamps = false
        options.wordTimestamps = false
        options.skipSpecialTokens = true   // keep timing metadata, strip <|…|> markup from text
        let results: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap { $0.segments }
    }
}
