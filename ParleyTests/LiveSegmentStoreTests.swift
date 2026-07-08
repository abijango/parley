import XCTest
@testable import Parley

@MainActor
final class LiveSegmentStoreTests: XCTestCase {

    func testAppendOnlyUpdatesTail() {
        let store = LiveSegmentStore()
        let a = Segment(track: .me, start: 0, end: 1, text: "one", confirmed: true)
        let b = Segment(track: .remote, start: 1, end: 2, text: "two", confirmed: true)
        store.apply([a])
        store.apply([a, b])
        XCTAssertEqual(store.segments.count, 2)
        XCTAssertEqual(store.segments[1].text, "two")
    }

    func testVolatileTailUpdatesInPlace() {
        let store = LiveSegmentStore()
        let id = UUID()
        let v1 = Segment(id: id, track: .remote, start: 0, end: 1, text: "hel", confirmed: false)
        let v2 = Segment(id: id, track: .remote, start: 0, end: 1.2, text: "hello", confirmed: false)
        store.apply([v1])
        store.apply([v2])
        XCTAssertEqual(store.segments.count, 1)
        XCTAssertEqual(store.segments[0].text, "hello")
    }

    func testSameCountIdStableUpdatesChangedRow() {
        let store = LiveSegmentStore()
        let id = UUID()
        let before = Segment(id: id, track: .remote, start: 0, end: 1, text: "hi", confirmed: true, speakerId: "1")
        let after = Segment(id: id, track: .remote, start: 0, end: 1, text: "hi", confirmed: true,
                            speakerId: "1", speakerName: "Alex")
        store.apply([before])
        store.apply([after])
        XCTAssertEqual(store.segments[0].speakerName, "Alex")
    }

    func testResetClearsSegments() {
        let store = LiveSegmentStore()
        store.apply([Segment(track: .me, start: 0, end: 1, text: "x", confirmed: true)])
        store.reset()
        XCTAssertTrue(store.segments.isEmpty)
    }
}