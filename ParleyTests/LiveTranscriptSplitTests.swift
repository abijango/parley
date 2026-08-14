import XCTest
@testable import Parley

final class LiveTranscriptSplitTests: XCTestCase {

    func testAllConfirmedStayTogether() {
        let segs = [
            Segment(track: .remote, start: 0, end: 1, text: "a", confirmed: true),
            Segment(track: .remote, start: 1, end: 2, text: "b", confirmed: true),
        ]
        XCTAssertEqual(LiveTranscriptSplit.confirmed(segs).map(\.text), ["a", "b"])
        XCTAssertNil(LiveTranscriptSplit.volatile(segs))
    }

    func testUnconfirmedTailIsSplitOff() {
        let segs = [
            Segment(track: .remote, start: 0, end: 1, text: "a", confirmed: true),
            Segment(track: .remote, start: 1, end: 2, text: "partial", confirmed: false),
        ]
        XCTAssertEqual(LiveTranscriptSplit.confirmed(segs).map(\.text), ["a"])
        XCTAssertEqual(LiveTranscriptSplit.volatile(segs)?.text, "partial")
    }

    func testEquatableIgnoresVolatileText() {
        let confirmed = Segment(track: .remote, start: 0, end: 1, text: "a", confirmed: true)
        let volatileID = UUID()
        let a = LiveTranscriptView(
            segments: [
                confirmed,
                Segment(id: volatileID, track: .remote, start: 1, end: 2, text: "hi", confirmed: false),
            ],
            isRecording: true)
        let b = LiveTranscriptView(
            segments: [
                confirmed,
                Segment(id: volatileID, track: .remote, start: 1, end: 2, text: "hello there", confirmed: false),
            ],
            isRecording: true)
        XCTAssertEqual(a, b)
    }
}
