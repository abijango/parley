import XCTest
@testable import Parley

final class LiveTranscriptTableDiffTests: XCTestCase {

    func testEmptyStaysNone() {
        XCTAssertEqual(LiveTranscriptTableDiff.edit(from: [], to: []), .none)
    }

    func testFirstSnapshotReloads() {
        let a = Segment(track: .me, start: 0, end: 1, text: "hi", confirmed: true)
        XCTAssertEqual(LiveTranscriptTableDiff.edit(from: [], to: [a]), .reloadAll)
    }

    func testClearReloads() {
        let a = Segment(track: .me, start: 0, end: 1, text: "hi", confirmed: true)
        XCTAssertEqual(LiveTranscriptTableDiff.edit(from: [a], to: []), .reloadAll)
    }

    func testVolatileTailReloadsLastRow() {
        let id = UUID()
        let v1 = Segment(id: id, track: .remote, start: 0, end: 1, text: "hel", confirmed: false)
        let v2 = Segment(id: id, track: .remote, start: 0, end: 1.2, text: "hello", confirmed: false)
        XCTAssertEqual(
            LiveTranscriptTableDiff.edit(from: [v1], to: [v2]),
            .reload(IndexSet(integer: 0)))
    }

    func testUnchangedSnapshotIsNone() {
        let a = Segment(track: .me, start: 0, end: 1, text: "hi", confirmed: true)
        XCTAssertEqual(LiveTranscriptTableDiff.edit(from: [a], to: [a]), .none)
    }

    func testConfirmAppendsNewVolatileAndReloadsPromotedRow() {
        let confirmed = Segment(track: .remote, start: 0, end: 1, text: "a", confirmed: true)
        let tailID = UUID()
        let volatile = Segment(id: tailID, track: .remote, start: 1, end: 2, text: "hel", confirmed: false)
        let promoted = Segment(id: tailID, track: .remote, start: 1, end: 2, text: "hello", confirmed: true)
        let next = Segment(track: .remote, start: 2, end: 3, text: "w", confirmed: false)
        XCTAssertEqual(
            LiveTranscriptTableDiff.edit(from: [confirmed, volatile], to: [confirmed, promoted, next]),
            .reloadAndAppend(reload: IndexSet(integer: 1), append: IndexSet(integer: 2)))
    }

    func testPureAppend() {
        let a = Segment(track: .me, start: 0, end: 1, text: "one", confirmed: true)
        let b = Segment(track: .remote, start: 1, end: 2, text: "two", confirmed: true)
        XCTAssertEqual(
            LiveTranscriptTableDiff.edit(from: [a], to: [a, b]),
            .append(IndexSet(integer: 1)))
    }

    func testIdentityChurnReloadsAll() {
        let a = Segment(track: .remote, start: 0, end: 1, text: "a", confirmed: true, speakerId: "1")
        let b = Segment(track: .remote, start: 0, end: 1, text: "a", confirmed: true, speakerId: "2")
        XCTAssertEqual(LiveTranscriptTableDiff.edit(from: [a], to: [b]), .reloadAll)
    }
}
