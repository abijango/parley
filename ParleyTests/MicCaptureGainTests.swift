import XCTest
import AVFoundation
@testable import Parley

final class MicCaptureGainTests: XCTestCase {

    private func makeBuffer(frames: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: value, count: Int(frames))
        return buffer
    }

    func testRegularMode_isPassThrough() {
        let input: [Float] = [0.1, -0.2, 0.5]
        let output = MicInputGain.apply(input, mode: .regular)
        XCTAssertEqual(output, input)
    }

    func testRoomMode_doublesWithinClamp() {
        let input: [Float] = [0.1, -0.2, 0.25]
        let output = MicInputGain.apply(input, mode: .room)
        XCTAssertEqual(output, [0.2, -0.4, 0.5])
    }

    func testRoomMode_clampsPositivePeak() {
        let input: [Float] = [0.8, 0.9]
        let output = MicInputGain.apply(input, mode: .room)
        XCTAssertEqual(output, [1.0, 1.0])
    }

    func testRoomMode_clampsNegativePeak() {
        let input: [Float] = [-0.8, -0.9]
        let output = MicInputGain.apply(input, mode: .room)
        XCTAssertEqual(output, [-1.0, -1.0])
    }

    func testRoomMode_bufferMatchesSamplePath() {
        let buffer = makeBuffer(frames: 4, value: 0.15)
        XCTAssertTrue(MicInputGain.apply(to: buffer, mode: .room))
        let ptr = buffer.floatChannelData![0]
        XCTAssertEqual(ptr[0], 0.3)
        XCTAssertEqual(ptr[1], 0.3)
    }

    func testRoomMode_int16BufferIsBoosted() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        buffer.int16ChannelData![0][0] = 1000
        buffer.int16ChannelData![0][1] = -2000
        XCTAssertTrue(MicInputGain.apply(to: buffer, mode: .room))
        XCTAssertEqual(buffer.int16ChannelData![0][0], 2000)
        XCTAssertEqual(buffer.int16ChannelData![0][1], -4000)
    }

    func testRegularMode_bufferIsUnchanged() {
        let buffer = makeBuffer(frames: 2, value: 0.25)
        XCTAssertFalse(MicInputGain.apply(to: buffer, mode: .regular))
        XCTAssertEqual(buffer.floatChannelData![0][0], 0.25)
    }

    func testModeToggle_midStream_noCrash() {
        let regular = MicInputGain.apply([0.1], mode: .regular)
        let room = MicInputGain.apply([0.1], mode: .room)
        XCTAssertEqual(regular, [0.1])
        XCTAssertEqual(room, [0.2])
        // Simulate mid-recording flip: second buffer uses the new mode.
        let afterToggle = MicInputGain.apply([0.1], mode: .regular)
        XCTAssertEqual(afterToggle, [0.1])
    }
}
