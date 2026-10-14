import XCTest
@testable import Parley

final class HistorySelectionTests: XCTestCase {
    func testRemovingMiddleRowSelectsFollowingRow() {
        XCTAssertEqual(
            HistoryView.selectionAfterRemoving("second", from: ["first", "second", "third"]),
            "third"
        )
    }

    func testRemovingLastRowSelectsPreviousRow() {
        XCTAssertEqual(
            HistoryView.selectionAfterRemoving("third", from: ["first", "second", "third"]),
            "second"
        )
    }

    func testRemovingOnlyRowClearsSelection() {
        XCTAssertNil(HistoryView.selectionAfterRemoving("only", from: ["only"]))
    }
}
