import XCTest
import AVFoundation
@testable import Parley

/// Tests for `AudioConcatenator.concatenate(_:gaps:output:)`.
///
/// Covers:
/// - Basic duration arithmetic: Σ(legs) + Σ(gaps) ≈ expected total
/// - Cross-rate normalization: mixed 48 kHz + 24 kHz inputs collapse to 48 kHz output
/// - Edge cases: empty inputs, mismatched gaps array
final class AudioConcatenatorTests: XCTestCase {

    // MARK: - Setup / teardown

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioConcatenatorTests_\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Returns the duration in seconds of the audio file at `url`.
    private func fileDuration(_ url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.processingFormat.sampleRate
    }

    /// Returns the on-disk sample rate of the file (from `fileFormat`, not `processingFormat`).
    private func fileSampleRate(_ url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return f.fileFormat.sampleRate
    }

    /// Writes a short tone (constant non-zero value) to a `.caf` file.
    ///
    /// Using a non-zero fill value (0.1) ensures the tone is distinguishable from
    /// the silence gaps when debugging; the exact waveform doesn't matter for
    /// duration / readability assertions.
    ///
    /// The `AVAudioFile` writer is **scoped** inside this function so it deinits
    /// (flushing the CAF header) before the caller uses the URL.
    private func writeTone(url: URL,
                            sampleRate: Double,
                            channels: UInt32,
                            durationSeconds: Double,
                            value: Float = 0.1) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let writer = try AVAudioFile(forWriting: url, settings: settings)
        let fmt = writer.processingFormat
        let frameCount = AVAudioFrameCount(round(durationSeconds * sampleRate))
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        for ch in 0..<Int(channels) {
            if let ptr = buf.floatChannelData?[ch] {
                for i in 0..<Int(frameCount) { ptr[i] = value }
            }
        }
        try writer.write(from: buf)
        // writer deinits here, flushing the CAF header.
    }

    // MARK: - Tests

    /// Two mono legs at different sample rates with a 0.5 s gap:
    ///   leg0 @ 48 kHz, 1 s  +  0.5 s silence  +  leg1 @ 24 kHz, 1 s  ≈ 2.5 s
    ///
    /// Also asserts the output sample rate == 48 000 Hz (the max) — proving the
    /// cross-rate normalization path fired rather than falling through to the first
    /// input's rate.
    func testConcatenate_crossRateLegs_durationAndSampleRate() throws {
        let leg0 = tempDir.appendingPathComponent("leg0.caf")
        let leg1 = tempDir.appendingPathComponent("leg1.caf")
        let out  = tempDir.appendingPathComponent("out.caf")

        try writeTone(url: leg0, sampleRate: 48_000, channels: 1, durationSeconds: 1.0)
        try writeTone(url: leg1, sampleRate: 24_000, channels: 1, durationSeconds: 1.0)

        let result = AudioConcatenator.concatenate(
            [leg0, leg1],
            gaps: [0, 0.5],
            output: out
        )

        XCTAssertTrue(result, "concatenate should return true for valid inputs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path),
                      "output file should exist on success")

        let duration = try fileDuration(out)
        XCTAssertEqual(duration, 2.5, accuracy: 0.1,
                       "total duration should be leg0(1s) + gap(0.5s) + leg1(1s) = 2.5 s")

        let rate = try fileSampleRate(out)
        XCTAssertEqual(rate, 48_000,
                       "output sample rate should be the max across inputs (48 kHz)")
    }

    /// Two legs at the same rate (48 kHz) with a gap — sanity-checks the same-rate path.
    func testConcatenate_sameRateLegs_durationCorrect() throws {
        let leg0 = tempDir.appendingPathComponent("leg0.caf")
        let leg1 = tempDir.appendingPathComponent("leg1.caf")
        let out  = tempDir.appendingPathComponent("out.caf")

        try writeTone(url: leg0, sampleRate: 48_000, channels: 1, durationSeconds: 1.0)
        try writeTone(url: leg1, sampleRate: 48_000, channels: 1, durationSeconds: 1.0)

        let result = AudioConcatenator.concatenate(
            [leg0, leg1],
            gaps: [0, 0.5],
            output: out
        )

        XCTAssertTrue(result)
        let duration = try fileDuration(out)
        XCTAssertEqual(duration, 2.5, accuracy: 0.05)
    }

    /// gaps[0] must be ignored (treated as 0) — no leading silence.
    func testConcatenate_gapsZeroIndexIgnored_noLeadingSilence() throws {
        let leg0 = tempDir.appendingPathComponent("leg0.caf")
        let out  = tempDir.appendingPathComponent("out.caf")

        try writeTone(url: leg0, sampleRate: 48_000, channels: 1, durationSeconds: 1.0)

        // Pass gaps[0] = 99 — it should be ignored.
        let result = AudioConcatenator.concatenate(
            [leg0],
            gaps: [99.0],
            output: out
        )

        XCTAssertTrue(result)
        let duration = try fileDuration(out)
        // Should be just the leg's 1 s, not 100 s.
        XCTAssertEqual(duration, 1.0, accuracy: 0.05,
                       "gaps[0] must be ignored — no leading silence before the first leg")
    }

    /// Empty inputs must return false immediately.
    func testConcatenate_emptyInputs_returnsFalse() {
        let out = tempDir.appendingPathComponent("out.caf")
        let result = AudioConcatenator.concatenate([], gaps: [], output: out)
        XCTAssertFalse(result, "empty inputs should return false")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                       "no output file should be created for empty inputs")
    }

    /// Mismatched gaps count (gaps.count != inputs.count) must return false.
    func testConcatenate_mismatchedGapsCount_returnsFalse() throws {
        let leg0 = tempDir.appendingPathComponent("leg0.caf")
        let out  = tempDir.appendingPathComponent("out.caf")

        try writeTone(url: leg0, sampleRate: 48_000, channels: 1, durationSeconds: 1.0)

        let result = AudioConcatenator.concatenate(
            [leg0],
            gaps: [],          // wrong count
            output: out
        )
        XCTAssertFalse(result, "mismatched gaps array should return false")
    }

    /// Verify the output file is fully readable (not truncated / invalid header).
    func testConcatenate_outputIsReadable() throws {
        let leg0 = tempDir.appendingPathComponent("leg0.caf")
        let leg1 = tempDir.appendingPathComponent("leg1.caf")
        let out  = tempDir.appendingPathComponent("out.caf")

        try writeTone(url: leg0, sampleRate: 48_000, channels: 1, durationSeconds: 0.5)
        try writeTone(url: leg1, sampleRate: 48_000, channels: 1, durationSeconds: 0.5)

        XCTAssertTrue(AudioConcatenator.concatenate([leg0, leg1], gaps: [0, 0.25], output: out))

        // Re-open and read every sample — any truncation / corrupt header throws here.
        let reader = try AVAudioFile(forReading: out)
        let buf = AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                    frameCapacity: AVAudioFrameCount(reader.length))!
        XCTAssertNoThrow(try reader.read(into: buf),
                          "output file must be fully readable without throwing")
        XCTAssertGreaterThan(Int(buf.frameLength), 0, "output must contain samples")
    }
}
