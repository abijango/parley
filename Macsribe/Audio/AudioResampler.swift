import Foundation
import AVFoundation

/// Converts arbitrary PCM input (any sample rate / channel count) to the format
/// Whisper expects: 16 kHz, mono, Float32, non-interleaved. One instance per
/// audio source — the converter keeps internal state across the stream, so
/// reuse it for every buffer of the same source.
final class AudioResampler {
    static let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let inputSampleRate: Double

    init?(inputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.whisperFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = Self.whisperFormat
        self.inputSampleRate = inputFormat.sampleRate
    }

    /// Returns 16 kHz mono float samples for one input buffer, or nil on failure.
    func resample(_ input: AVAudioPCMBuffer) -> [Float]? {
        guard input.frameLength > 0 else { return [] }
        let ratio = outputFormat.sampleRate / inputSampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error, let channel = output.floatChannelData else { return nil }
        let count = Int(output.frameLength)
        return Array(UnsafeBufferPointer(start: channel[0], count: count))
    }
}
