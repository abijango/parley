import XCTest
@testable import Parley

final class LiveSpeakerRosterTests: XCTestCase {

    private func seg(_ speaker: String?, _ name: String? = nil, _ text: String = "x",
                     start: TimeInterval = 0, end: TimeInterval = 1) -> Segment {
        Segment(track: .remote, start: start, end: end, text: text, confirmed: true,
                speakerId: speaker, speakerName: name)
    }

    func testUnnamedFirstThenNamedInAppearanceOrder() {
        let speakers = LiveSpeakerRoster.speakers(from: [
            seg("1", "Alex"), seg("2"), seg("3", "Sam"), seg("4"),
        ])
        XCTAssertEqual(speakers.map(\.id), ["2", "4", "1", "3"])
    }

    func testTalkTimeAndRecentLines() {
        let speakers = LiveSpeakerRoster.speakers(from: [
            seg("1", nil, "a", start: 0, end: 2), seg("1", nil, "b", start: 2, end: 5),
            seg("1", nil, "c", start: 5, end: 6), seg("1", nil, "d", start: 6, end: 7),
            seg(nil, nil, "track-only"),
        ])
        XCTAssertEqual(speakers.count, 1)
        XCTAssertEqual(speakers[0].talkSeconds, 7, accuracy: 0.001)
        XCTAssertEqual(speakers[0].recentLines, ["b", "c", "d"])
    }
}
