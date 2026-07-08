import XCTest
@testable import Parley

final class TranscriptMergerTests: XCTestCase {

    private func seg(_ track: SpeakerTrack, _ start: Double, _ text: String, confirmed: Bool = true) -> Segment {
        Segment(track: track, start: start, end: start + 1, text: text, confirmed: confirmed)
    }

    func testMergeInterleavesTracksByStart() {
        let merger = TranscriptMerger()
        merger.update(track: .me, confirmed: [seg(.me, 0, "a"), seg(.me, 4, "c")], unconfirmed: [])
        merger.update(track: .remote, confirmed: [seg(.remote, 2, "b")], unconfirmed: [])

        let merged = merger.finalTimeline()
        XCTAssertEqual(merged.map(\.text), ["a", "b", "c"])
    }

    func testUnconfirmedTailIncludedInFinalTimeline() {
        let merger = TranscriptMerger()
        merger.update(track: .me, confirmed: [seg(.me, 0, "done")], unconfirmed: [seg(.me, 2, "tail", confirmed: false)])

        XCTAssertEqual(merger.confirmedTimeline().map(\.text), ["done"])
        XCTAssertEqual(merger.finalTimeline().map(\.text), ["done", "tail"])
    }
}