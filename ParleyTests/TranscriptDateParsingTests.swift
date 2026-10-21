import XCTest
@testable import Parley

final class TranscriptDateParsingTests: XCTestCase {
    private func components(_ date: Date?) -> DateComponents? {
        date.map { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0) }
    }

    func testParsesEveryFrontmatterDateShape() {
        XCTAssertEqual(components(TranscriptWriter.parseISODate("2026-03-04 09:15:30")),
                       DateComponents(year: 2026, month: 3, day: 4, hour: 9, minute: 15, second: 30))
        XCTAssertEqual(components(TranscriptWriter.parseISODate("2026-03-04T09:15:30")),
                       DateComponents(year: 2026, month: 3, day: 4, hour: 9, minute: 15, second: 30))
        XCTAssertEqual(components(TranscriptWriter.parseISODate(" 2026-03-04 09:15 ")),
                       DateComponents(year: 2026, month: 3, day: 4, hour: 9, minute: 15, second: 0))
        XCTAssertEqual(components(TranscriptWriter.parseISODate("2026-03-04")),
                       DateComponents(year: 2026, month: 3, day: 4, hour: 0, minute: 0, second: 0))
    }

    func testRejectsNonDates() {
        XCTAssertNil(TranscriptWriter.parseISODate("next tuesday"))
        XCTAssertNil(TranscriptWriter.parseISODate(""))
    }

    func testRoundTripsTheWrittenTimestamp() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let parsed = TranscriptWriter.parseISODate(TranscriptWriter.isoDateTime(date))
        XCTAssertEqual(parsed?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 1)
    }
}
