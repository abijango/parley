import XCTest
@testable import Parley

final class LiveTranscriptTableDiffTests: XCTestCase {

    private func seg(_ text: String, id: UUID = UUID(), confirmed: Bool = true, speaker: String? = nil) -> Segment {
        Segment(id: id, track: .remote, start: 0, end: 1, text: text, confirmed: confirmed, speakerId: speaker)
    }

    func testEmptyStaysNone() {
        XCTAssertEqual(LiveTranscriptTableDiff.edit(from: [], to: []), .none)
    }

    func testFirstSnapshotReloads() {
        XCTAssertEqual(LiveTranscriptTableDiff.edit(from: [], to: [seg("hi")]), .reloadAll)
    }

    func testClearReloads() {
        XCTAssertEqual(LiveTranscriptTableDiff.edit(from: [seg("hi")], to: []), .reloadAll)
    }

    func testUnchangedSnapshotIsNone() {
        let a = seg("hi")
        XCTAssertEqual(LiveTranscriptTableDiff.edit(from: [a], to: [a]), .none)
    }

    func testVolatileTailReloadsLastRow() {
        let id = UUID()
        XCTAssertEqual(
            LiveTranscriptTableDiff.edit(from: [seg("hel", id: id, confirmed: false)],
                                         to: [seg("hello", id: id, confirmed: false)]),
            .update(remove: [], insert: [], reload: IndexSet(integer: 0)))
    }

    func testPureAppend() {
        let a = seg("one")
        XCTAssertEqual(
            LiveTranscriptTableDiff.edit(from: [a], to: [a, seg("two")]),
            .update(remove: [], insert: IndexSet(integer: 1), reload: []))
    }

    func testConfirmPromotesTailAndAppends() {
        let a = seg("a"), tail = UUID()
        XCTAssertEqual(
            LiveTranscriptTableDiff.edit(
                from: [a, seg("hel", id: tail, confirmed: false)],
                to: [a, seg("hello", id: tail), seg("w", confirmed: false)]),
            .update(remove: [], insert: IndexSet(integer: 2), reload: IndexSet(integer: 1)))
    }

    /// Diarization re-splitting the open tail: one row becomes two, ids above it stay.
    func testTailResplitInsertsWithoutReloadAll() {
        let a = seg("locked"), b = UUID(), volatile = UUID()
        let old = [a, seg("one two three", id: b), seg("now", id: volatile, confirmed: false)]
        let new = [a, seg("one two", id: b), seg("three", speaker: "2"), seg("now", id: volatile, confirmed: false)]
        XCTAssertEqual(
            LiveTranscriptTableDiff.edit(from: old, to: new),
            .update(remove: [], insert: IndexSet(integer: 2), reload: IndexSet(integer: 1)))
    }

    /// The volatile row confirmed into the row above: removed, not a full reload.
    func testTailMergedUpIsRemoval() {
        let a = seg("a"), b = UUID(), volatile = UUID()
        let old = [a, seg("one", id: b), seg("two", id: volatile, confirmed: false)]
        let new = [a, seg("one two", id: b)]
        XCTAssertEqual(
            LiveTranscriptTableDiff.edit(from: old, to: new),
            .update(remove: IndexSet(integer: 2), insert: [], reload: IndexSet(integer: 1)))
    }

    func testNoSurvivingRowsReloadsAll() {
        XCTAssertEqual(LiveTranscriptTableDiff.edit(from: [seg("a")], to: [seg("a")]), .reloadAll)
    }
}
