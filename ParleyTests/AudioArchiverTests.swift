import XCTest
import AVFoundation
@testable import Parley

/// Tests for `AudioArchiver.updateSourceFormat(_:)` and `appendSilence(seconds:)`.
///
/// These exercise the deterministic core of the mic device-change recovery:
/// the archive file must remain a single continuous file with the original
/// sample rate, with the gap between device A and device B silence-padded.
final class AudioArchiverTests: XCTestCase {

    // MARK: - Helpers

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioArchiverTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func archiveURL(_ name: String = "mic.caf") -> URL {
        tempDir.appendingPathComponent(name)
    }

    /// Builds an `AVAudioFormat` suitable for use as an engine's mic input format.
    /// Non-interleaved Float32 (AVAudioEngine's native processing format).
    private func makeFormat(sampleRate: Double, channels: UInt32 = 1) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }

    /// Creates a PCM buffer filled with a constant value.
    private func makeBuffer(format: AVAudioFormat, frames: AVAudioFrameCount, value: Float = 0.1) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            if let ptr = buf.floatChannelData?[ch] {
                for i in 0..<Int(frames) { ptr[i] = value }
            }
        }
        return buf
    }

    /// Returns the duration in seconds of the audio file at `url` by reading its
    /// processingFormat and length.
    private func fileDuration(_ url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.processingFormat.sampleRate
    }

    /// Returns the file's sample rate (from the file settings, not processingFormat).
    private func fileSampleRate(_ url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return f.fileFormat.sampleRate
    }

    // MARK: - Tests

    /// Writes audio at format A (48 kHz), switches to format B (44.1 kHz) via
    /// `updateSourceFormat`, pads 2 s of silence, writes more audio at B, closes,
    /// reopens and verifies:
    /// - total duration ≈ A audio + silence + B-resampled audio (within 0.1 s tolerance)
    /// - the file's on-disk sample rate is still A's (unchanged)
    func testUpdateSourceFormatAndSilencePad_roundTrip() throws {
        let formatA = makeFormat(sampleRate: 48_000)
        let formatB = makeFormat(sampleRate: 44_100)
        let url = archiveURL()

        let archiver = try AudioArchiver(url: url, format: formatA)

        // Write 1 s of audio at format A.
        archiver.append(makeBuffer(format: formatA, frames: AVAudioFrameCount(formatA.sampleRate)))

        // Device changes: switch to format B.
        archiver.updateSourceFormat(formatB)

        // Pad 2 s of silence for the outage.
        let silenceSeconds = 2.0
        archiver.appendSilence(seconds: silenceSeconds)

        // Write 1 s of audio at format B (gets resampled into the file's format A rate).
        archiver.append(makeBuffer(format: formatB, frames: AVAudioFrameCount(formatB.sampleRate), value: 0.2))

        // Flush staged frames before reading the file — staging holds non-power-of-2
        // frame counts to avoid AVAudioFile write-alignment loss; must be explicitly flushed.
        archiver.finalize()

        // Total expected: A(1s) + silence(2s) + B-resampled(~1s)
        let actualDuration = try fileDuration(url)
        XCTAssertEqual(actualDuration, 4.0, accuracy: 0.1,
                       "Total file duration should equal A audio + silence + B audio")

        let actualRate = try fileSampleRate(url)
        XCTAssertEqual(actualRate, formatA.sampleRate,
                       "File sample rate must stay at format A's rate after device switch")
    }

    /// A pure silence pad with no subsequent audio — verifies that appendSilence
    /// alone advances the file duration.
    func testAppendSilence_advancesFileDuration() throws {
        let format = makeFormat(sampleRate: 48_000)
        let url = archiveURL()
        let archiver = try AudioArchiver(url: url, format: format)

        archiver.appendSilence(seconds: 3.0)
        archiver.finalize()

        let actual = try fileDuration(url)
        XCTAssertEqual(actual, 3.0, accuracy: 0.05,
                       "appendSilence(3s) should produce ~3 s of audio")
    }

    /// Zero-second silence is a no-op — file length stays at 0.
    func testAppendSilence_zeroSecondsIsNoop() throws {
        let format = makeFormat(sampleRate: 48_000)
        let url = archiveURL()
        let archiver = try AudioArchiver(url: url, format: format)

        archiver.appendSilence(seconds: 0)
        archiver.finalize()

        let actual = try fileDuration(url)
        XCTAssertEqual(actual, 0, accuracy: 0.001, "appendSilence(0) must not write any frames")
    }

    /// Verifies that `framesWritten` stays accurate across an updateSourceFormat +
    /// appendSilence + append cycle.
    func testFramesWritten_tracksAcrossFormatSwitch() throws {
        let formatA = makeFormat(sampleRate: 48_000)
        let formatB = makeFormat(sampleRate: 44_100)
        let url = archiveURL()
        let archiver = try AudioArchiver(url: url, format: formatA)

        // 1 s at A.
        archiver.append(makeBuffer(format: formatA, frames: 48_000))

        // Switch + 2 s silence.
        archiver.updateSourceFormat(formatB)
        archiver.appendSilence(seconds: 2.0)

        // 1 s at B (resampled to A's rate in the file).
        archiver.append(makeBuffer(format: formatB, frames: 44_100, value: 0.3))
        archiver.finalize()

        // framesWritten is in the FILE's sample rate (48 kHz):
        // 48000 (A audio) + 96000 (2 s silence at 48 kHz) + ~48000 (B resampled) = ~192000
        let expectedFrames = AVAudioFramePosition(48_000 + 96_000 + 48_000)
        XCTAssertEqual(archiver.framesWritten, expectedFrames,
                       accuracy: 1000,
                       "framesWritten should reflect total frames in file units")
    }

    /// updateSourceFormat to the same format as the file's processing format
    /// clears the converter (no-op path) — subsequent appends should still work.
    func testUpdateSourceFormat_sameAsProcessingFormat_noConverter() throws {
        let formatA = makeFormat(sampleRate: 48_000)
        let url = archiveURL()
        let archiver = try AudioArchiver(url: url, format: formatA)

        archiver.updateSourceFormat(formatA)

        archiver.append(makeBuffer(format: formatA, frames: 48_000))
        archiver.finalize()

        let actual = try fileDuration(url)
        XCTAssertEqual(actual, 1.0, accuracy: 0.05,
                       "Writes must still work after updateSourceFormat to same format")
    }

    // MARK: - Streaming frame-fidelity tests (mirror real tap behavior)

    /// Mirrors real tap behavior: feed 200 x 4096-frame buffers through the cross-rate
    /// converter path (B=44100 -> file=48000) and verify total duration is preserved
    /// within 50 ms. This catches per-buffer frame loss in the block-based AVAudioConverter.
    ///
    /// The AVAudioConverter block-form with `.noDataNow` holds back a converter tail
    /// until the next call supplies data. A one-shot call of 4096 frames loses that tail,
    /// but a stream of 200 calls accumulates it correctly. This test verifies that.
    func testAppend_crossRateConverter_preservesFrames() throws {
        let formatA = makeFormat(sampleRate: 48_000)
        let formatB = makeFormat(sampleRate: 44_100)
        let url = archiveURL("cross_rate.caf")
        let archiver = try AudioArchiver(url: url, format: formatA)

        archiver.updateSourceFormat(formatB)

        let tapFrames = AVAudioFrameCount(4096)
        let bufferCount = 200
        for _ in 0..<bufferCount {
            archiver.append(makeBuffer(format: formatB, frames: tapFrames, value: 0.1))
        }

        // Expected: 200 * 4096 / 44100 = ~18.57 s
        archiver.finalize()

        let inputDuration = Double(tapFrames) * Double(bufferCount) / formatB.sampleRate
        let actual = try fileDuration(url)
        XCTAssertEqual(actual, inputDuration, accuracy: 0.05,
                       "Cross-rate converter must preserve total duration across \(bufferCount) buffers")
    }

    /// Same as testAppend_crossRateConverter_preservesFrames but with the input rate
    /// equal to the file rate (same-rate, layout-only converter path when starting
    /// from an interleaved format). Verifies no cumulative frame loss in the
    /// converter path when no resampling is needed.
    func testAppend_sameRateConverter_preservesFrames() throws {
        // Interleaved Float32 at 48 kHz: differs from processingFormat (non-interleaved)
        // so the archiver init picks up a converter, even though rates match.
        guard let formatInterleaved = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ) else {
            XCTFail("Could not build interleaved format"); return
        }
        let url = archiveURL("same_rate.caf")
        let archiver = try AudioArchiver(url: url, format: formatInterleaved)

        let tapFrames = AVAudioFrameCount(4096)
        let bufferCount = 200
        for _ in 0..<bufferCount {
            guard let buf = AVAudioPCMBuffer(pcmFormat: formatInterleaved, frameCapacity: tapFrames) else {
                XCTFail("Buffer alloc failed"); return
            }
            buf.frameLength = tapFrames
            // For mono Float32 interleaved, floatChannelData[0] gives the sample pointer.
            if let ptr = buf.floatChannelData?[0] {
                for i in 0..<Int(tapFrames) { ptr[i] = 0.1 }
            }
            archiver.append(buf)
        }

        archiver.finalize()

        let inputDuration = Double(tapFrames) * Double(bufferCount) / formatInterleaved.sampleRate
        let actual = try fileDuration(url)
        XCTAssertEqual(actual, inputDuration, accuracy: 0.05,
                       "Same-rate converter must preserve total duration across \(bufferCount) buffers")
    }
}

// MARK: - XCTAssertEqual for AVAudioFramePosition with accuracy

/// Custom overload so tests can write `XCTAssertEqual(a, b, accuracy: n)` for
/// integer frame positions without converting to Double first.
private func XCTAssertEqual(
    _ expression1: AVAudioFramePosition,
    _ expression2: AVAudioFramePosition,
    accuracy: AVAudioFramePosition,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let diff = abs(expression1 - expression2)
    XCTAssertTrue(diff <= accuracy,
                  "\(message) (expected \(expression2) ± \(accuracy), got \(expression1))",
                  file: file, line: line)
}
