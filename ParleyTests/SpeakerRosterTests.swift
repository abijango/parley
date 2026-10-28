import XCTest
@testable import Parley

final class SpeakerRosterTests: XCTestCase {

    private func seg(_ speaker: String?, _ name: String? = nil, _ text: String = "x",
                     start: TimeInterval = 0, end: TimeInterval = 1) -> Segment {
        Segment(track: .remote, start: start, end: end, text: text, confirmed: true,
                speakerId: speaker, speakerName: name)
    }

    func testUnnamedFirstThenNamedInAppearanceOrder() {
        let speakers = SpeakerRoster.speakers(from: [
            seg("1", "Alex"), seg("2"), seg("3", "Sam"), seg("4"),
        ])
        XCTAssertEqual(speakers.map(\.id), ["2", "4", "1", "3"])
    }

    func testTalkTimeAndRecentLines() {
        let speakers = SpeakerRoster.speakers(from: [
            seg("1", nil, "a", start: 0, end: 2), seg("1", nil, "b", start: 2, end: 5),
            seg("1", nil, "c", start: 5, end: 6), seg("1", nil, "d", start: 6, end: 7),
            seg(nil, nil, "track-only"),
        ])
        XCTAssertEqual(speakers.count, 1)
        XCTAssertEqual(speakers[0].talkSeconds, 7, accuracy: 0.001)
        XCTAssertEqual(speakers[0].recentLines, ["b", "c", "d"])
    }

    func testCacheSpeakersCarryGuessAndClip() {
        let cache = SpeakerCache(embeddingModelID: "m", mixedCafName: "mixed.caf", speakers: [
            .init(id: "1", resolvedName: "Alex", guessedName: nil, talkSeconds: 30,
                  sampleStart: 1, sampleEnd: 5, firstLine: "hi", centroid: []),
            .init(id: "2", resolvedName: nil, guessedName: "Sam", talkSeconds: 12,
                  sampleStart: 8, sampleEnd: 12, firstLine: "hello there", centroid: []),
            .init(id: "3", resolvedName: "  ", guessedName: nil, talkSeconds: 2,
                  sampleStart: 0, sampleEnd: 0, firstLine: "", centroid: []),
        ])
        let speakers = SpeakerRoster.speakers(from: cache, clipsPlayable: true)
        XCTAssertEqual(speakers.map(\.id), ["2", "3", "1"])   // blank name counts as unnamed
        XCTAssertEqual(speakers[0].guessedName, "Sam")
        XCTAssertEqual(speakers[0].recentLines, ["hello there"])
        XCTAssertTrue(speakers[0].hasClip)
        XCTAssertFalse(speakers[1].hasClip)                      // empty sample range
        XCTAssertFalse(SpeakerRoster.speakers(from: cache, clipsPlayable: false)[0].hasClip)
    }

    func testClipCandidatesPickCleanestLongestTurnPerSpeaker() {
        let samples = (0..<(16_000 * 10)).map { Float($0) }
        let clips = FluidAudioEngine.clipCandidates(in: samples, turns: [
            ("1", 0, 1, 0.9),      // too short
            ("1", 1, 3, 0.9),      // 2 s clean
            ("1", 3, 9, 0.5),      // 6 s → trimmed to 4 s, score 2.0 beats 1.8
            ("2", 0, 5, 0.2),      // below quality gate
        ])
        XCTAssertEqual(clips.count, 1)
        let c = try! XCTUnwrap(clips.first)
        XCTAssertEqual(c.speakerId, "1")
        XCTAssertEqual(c.samples.count, 16_000 * 4)
        XCTAssertEqual(c.samples.first, Float(16_000 * 4))      // centred on 6 s
    }

    func testCacheMergeRelabelsAndCombines() {
        var cache = SpeakerCache(embeddingModelID: "m", mixedCafName: "mixed.caf", speakers: [
            .init(id: "1", resolvedName: nil, guessedName: nil, talkSeconds: 10,
                  sampleStart: 0, sampleEnd: 4, firstLine: "", centroid: []),
            .init(id: "2", resolvedName: nil, guessedName: nil, talkSeconds: 5,
                  sampleStart: 0, sampleEnd: 4, firstLine: "", centroid: []),
            .init(id: "10", resolvedName: "Ana", guessedName: nil, talkSeconds: 1,
                  sampleStart: 0, sampleEnd: 4, firstLine: "", centroid: []),
        ])
        let body = "**[00:00:01] Speaker 2:** hi\n**[00:00:02] Speaker 1:** yo\n**[00:00:03] Ana:** hey"
        let out = SpeakerCache.merge("2", into: "1", in: &cache, body: body)
        XCTAssertEqual(out, "**[00:00:01] Speaker 1:** hi\n**[00:00:02] Speaker 1:** yo\n**[00:00:03] Ana:** hey")
        XCTAssertEqual(cache.speakers.map(\.id), ["1", "10"])
        XCTAssertEqual(cache.speakers[0].talkSeconds, 15)

        let named = SpeakerCache.merge("1", into: "10", in: &cache, body: out)
        XCTAssertFalse(named.contains("Speaker 1:"))
        XCTAssertEqual(cache.speakers.map(\.id), ["10"])
        XCTAssertEqual(SpeakerCache.merge("x", into: "10", in: &cache, body: "b"), "b")
    }
}
