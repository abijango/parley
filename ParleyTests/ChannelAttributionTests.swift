import XCTest
@testable import Parley

final class ChannelAttributionTests: XCTestCase {
    private let frame = ChannelAttribution.Config().frameSeconds

    /// `count` frames of `level`, with `spans` (frame ranges) raised to `speech`.
    private func envelope(_ count: Int, level: Float, speech: Float = 0,
                          _ spans: [Range<Int>] = []) -> [Float] {
        var out = [Float](repeating: level, count: count)
        for span in spans { for i in span { out[i] = speech } }
        return out
    }

    func testEnvelopeIsRMSPerFrame() {
        let env = ChannelAttribution.envelope([Float](repeating: 0.5, count: 1_600))
        XCTAssertEqual(env.count, 2)
        XCTAssertEqual(env[0], 0.5, accuracy: 0.0001)
    }

    func testMicSpeechWithSilentCallAudioIsTheOwner() {
        let mic = envelope(200, level: 0.001, speech: 0.1, [20..<60])
        let sys = envelope(200, level: 0)
        let turns = ChannelAttribution.selfTurns(mic: mic, system: sys)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].start, 20 * frame - 0.1, accuracy: 0.001)
        XCTAssertEqual(turns[0].end, 60 * frame + 0.1, accuracy: 0.001)
    }

    /// Laptop speakers: the far side leaks into the mic, but the system track is louder.
    func testSpeakerBleedIsNotTheOwner() {
        let mic = envelope(200, level: 0.001, speech: 0.05, [100..<160])
        let sys = envelope(200, level: 0, speech: 0.2, [100..<160])
        XCTAssertTrue(ChannelAttribution.selfTurns(mic: mic, system: sys).isEmpty)
    }

    func testShortPausesAreBridgedAndBlipsDropped() {
        let mic = envelope(300, level: 0.001, speech: 0.1, [10..<30, 34..<60, 200..<203])
        let turns = ChannelAttribution.selfTurns(mic: mic, system: envelope(300, level: 0))
        XCTAssertEqual(turns.count, 1, "a 0.2 s pause is one turn; a 0.15 s blip is dropped")
    }

    func testContinuousSpeechStillCountsAsSpeech() {
        XCTAssertTrue(ChannelAttribution.systemHasSpeech(envelope(400, level: 0.1)))
        let turns = ChannelAttribution.selfTurns(mic: envelope(400, level: 0.1), system: envelope(400, level: 0))
        XCTAssertEqual(turns.count, 1)
    }

    /// An in-person meeting left in Regular mode has a near-silent call track.
    func testRemoteSpeechGate() {
        XCTAssertTrue(ChannelAttribution.systemHasSpeech(envelope(400, level: 0, speech: 0.1, [0..<200])))
        XCTAssertFalse(ChannelAttribution.systemHasSpeech(envelope(400, level: 0, speech: 0.1, [0..<20])))
        XCTAssertFalse(ChannelAttribution.systemHasSpeech([]))
    }

    func testMergeCutsOwnerSpansOutOfRemoteTurns() {
        let merged = ChannelAttribution.merge(
            selfTurns: [.init(start: 2, end: 4)],
            remote: [.init(speakerId: "1", start: 0, end: 10), .init(speakerId: "2", start: 3, end: 3.9)])
        XCTAssertEqual(merged, [
            .init(speakerId: "1", start: 0, end: 2),
            .init(speakerId: ChannelAttribution.selfSpeakerId, start: 2, end: 4),
            .init(speakerId: "1", start: 4, end: 10),
        ])
    }

    func testSelfLabelIsMe() {
        XCTAssertEqual(ChannelAttribution.selfLabel, "Me")
    }
}
