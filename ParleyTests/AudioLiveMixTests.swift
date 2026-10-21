import XCTest
@testable import Parley

final class AudioLiveMixTests: XCTestCase {
    private func ring(_ samples: [Float]) -> AudioRingBuffer {
        let r = AudioRingBuffer(capacity: 64)
        samples.withUnsafeBufferPointer { r.write($0) }
        return r
    }

    func testNothingFromMicMeansNoMix() {
        XCTAssertNil(AudioRingBuffer.mixLive(mic: ring([]), system: ring([0.5, 0.5])))
    }

    func testMixLengthFollowsTheMicAndLeavesSystemExcessQueued() {
        let mic = ring([0.1, 0.2])
        let system = ring([0.3, 0.3, 0.9])
        let mixed = try? XCTUnwrap(AudioRingBuffer.mixLive(mic: mic, system: system))
        XCTAssertEqual(mixed?.count, 2)
        XCTAssertEqual(mixed?[0] ?? 0, 0.4, accuracy: 1e-6)
        XCTAssertEqual(mixed?[1] ?? 0, 0.5, accuracy: 1e-6)
        XCTAssertEqual(system.availableToRead, 1)
    }

    func testShortSystemSideIsTreatedAsSilenceAndSumIsClipped() {
        let mixed = AudioRingBuffer.mixLive(mic: ring([0.8, -0.3, 0.2]), system: ring([0.7]))
        XCTAssertEqual(mixed, [1, -0.3, 0.2])
    }

    func testPerTickCapLeavesTheBacklogForTheNextTick() {
        let mic = ring([Float](repeating: 0.1, count: 10))
        XCTAssertEqual(AudioRingBuffer.mixLive(mic: mic, system: ring([]), maxSamples: 4)?.count, 4)
        XCTAssertEqual(mic.availableToRead, 6)
    }
}
