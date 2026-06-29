import Foundation
import AVFoundation

/// Concatenates multiple audio files into a single output file, inserting silence
/// gaps between legs. Used by `MergeService` to splice call-drop/rejoin legs before
/// running a fresh offline diarization pass over the combined audio.
///
/// Normalizes mixed sample rates and channel counts across legs (mic device changes
/// mid-meeting) to a common output format: PCM Float32 non-interleaved at the
/// maximum sample rate and maximum channel count found across all inputs.
///
/// All inputs are `.caf` files (ALAC or LPCM — `AVAudioFile` decodes both
/// transparently). Output is written as a `.caf`.
enum AudioConcatenator {

    // MARK: - Chunk size

    /// Frames read per chunk when consuming an input file. ~16 k frames at 48 kHz
    /// ≈ 0.34 s — enough to keep the converter's tail flush healthy without loading
    /// a whole meeting into memory.
    private static let chunkFrames: AVAudioFrameCount = 16_384

    // MARK: - Public API

    /// Concatenate `inputs` into a single file at `output`, inserting `gaps[i]`
    /// seconds of silence **before** `inputs[i]` (gaps[0] is ignored / treated as 0).
    ///
    /// - Requires: `gaps.count == inputs.count`
    /// - Returns: `true` on success, `false` on any open / read / convert / write
    ///   failure, or if `inputs` is empty.
    @discardableResult
    static func concatenate(_ inputs: [URL], gaps: [TimeInterval], output: URL) -> Bool {
        guard !inputs.isEmpty, gaps.count == inputs.count else { return false }

        // --- 1. Determine common output format ---------------------------------
        // Open all input files to measure max sample rate and channel count.
        var readers: [AVAudioFile] = []
        readers.reserveCapacity(inputs.count)
        for url in inputs {
            guard let f = try? AVAudioFile(forReading: url) else { return false }
            readers.append(f)
        }

        let maxRate = readers.map(\.fileFormat.sampleRate).max() ?? 48_000
        let maxChannels = readers.map { Int($0.fileFormat.channelCount) }.max() ?? 1

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: maxRate,
            AVNumberOfChannelsKey: maxChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]

        guard let writer = try? AVAudioFile(forWriting: output, settings: outputSettings) else {
            return false
        }

        // Use the writer's processingFormat (Float32 non-interleaved at maxRate/maxChannels)
        // as the canonical format for silence buffers and all converters.
        let outFmt = writer.processingFormat

        // --- 2. Process each leg -----------------------------------------------
        for (index, reader) in readers.enumerated() {
            // Insert silence gap before this leg (gaps[0] is treated as 0 per spec).
            let gap = index == 0 ? 0.0 : gaps[index]
            if gap > 0 {
                guard writeSilence(seconds: gap, format: outFmt, writer: writer) else {
                    return false
                }
            }

            // Copy the leg into the output, converting to outFmt on the fly.
            guard copyFile(reader, to: writer, outputFormat: outFmt) else {
                return false
            }
        }

        // writer flushes its CAF header on deinit — no explicit close needed.
        return true
    }

    // MARK: - Silence writer

    /// Writes `seconds` of silence (zero samples) to `writer` in `format`.
    private static func writeSilence(seconds: TimeInterval,
                                      format: AVAudioFormat,
                                      writer: AVAudioFile) -> Bool {
        let totalFrames = Int(round(seconds * format.sampleRate))
        guard totalFrames > 0 else { return true }

        // Write in bounded chunks to avoid allocating a giant buffer for long gaps.
        var remaining = totalFrames
        while remaining > 0 {
            let count = min(remaining, Int(chunkFrames))
            guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                              frameCapacity: AVAudioFrameCount(count)) else {
                return false
            }
            buf.frameLength = AVAudioFrameCount(count)
            // Zero every channel — AVAudioPCMBuffer does not guarantee zeroed memory.
            for ch in 0..<Int(format.channelCount) {
                if let ptr = buf.floatChannelData?[ch] {
                    ptr.initialize(repeating: 0, count: count)
                }
            }
            do {
                try writer.write(from: buf)
            } catch {
                return false
            }
            remaining -= count
        }
        return true
    }

    // MARK: - Chunked conversion + copy

    /// Reads `reader` in chunks, resamples/reformats to `outputFormat` via a single
    /// stateful `AVAudioConverter`, and writes to `writer`. The converter's internal
    /// state accumulates across `convert()` calls so the resampler tail is flushed
    /// correctly on `.endOfStream` — the same pattern used by AudioArchiver to avoid
    /// cumulative frame loss at cross-rate boundaries.
    private static func copyFile(_ reader: AVAudioFile,
                                  to writer: AVAudioFile,
                                  outputFormat: AVAudioFormat) -> Bool {
        let inFmt = reader.processingFormat
        guard let converter = AVAudioConverter(from: inFmt, to: outputFormat) else {
            return false
        }
        reader.framePosition = 0

        // Input buffer fed to the converter block.
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt,
                                            frameCapacity: chunkFrames) else { return false }

        // Output buffer receives converted frames each iteration.
        // Size the output capacity for the ratio, with a small headroom.
        let outCapacity = AVAudioFrameCount(
            Double(chunkFrames) * (outputFormat.sampleRate / inFmt.sampleRate)
        ) + 4_096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                             frameCapacity: outCapacity) else { return false }

        var reachedEnd = false

        while true {
            // Reset output frame count so the converter fills from zero each call.
            outBuf.frameLength = 0
            var convErr: NSError?

            let status = converter.convert(to: outBuf, error: &convErr) { _, inStatus in
                if reachedEnd {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                // Try to read the next chunk from the source file.
                do {
                    try reader.read(into: inBuf)
                } catch {
                    inStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }
                if inBuf.frameLength == 0 {
                    inStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }
                inStatus.pointee = .haveData
                return inBuf
            }

            if status == .error { return false }

            if outBuf.frameLength > 0 {
                do {
                    try writer.write(from: outBuf)
                } catch {
                    return false
                }
            }

            if status == .endOfStream { break }
        }

        return true
    }
}
