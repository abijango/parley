import XCTest
@testable import Parley

final class SummaryDurationFormatTests: XCTestCase {
    func testMicros() {
        XCTAssertEqual(SummaryDurationFormat.string(from: 0.000812), "812µs")
    }

    func testSeconds() {
        let s = SummaryDurationFormat.string(from: 1.234567)
        XCTAssertTrue(s.hasPrefix("1."), s)
        XCTAssertTrue(s.hasSuffix("s"), s)
    }

    func testMinutes() {
        let s = SummaryDurationFormat.string(from: 125.5)
        XCTAssertTrue(s.hasPrefix("2m "), s)
    }

    func testStripFiledNoteForCompare() {
        let filed = """
        ---
        title: Test
        source: parley-summary
        ---

        ## Attendees

        | Name | Role | Company |
        |------|------|---------|
        | Alice | Eng | Acme |

        ## Executive Summary
        Hello.

        ---

        ## Raw Transcript

        **[00:00:01] Alice:** hi
        """
        let body = SummaryComparison.summaryBodyForCompare(fromFiledNote: filed)
        XCTAssertTrue(body.contains("## Attendees"))
        XCTAssertTrue(body.contains("Hello."))
        XCTAssertFalse(body.contains("## Raw Transcript"))
        XCTAssertFalse(body.contains("**[00:00:01]"))
        XCTAssertFalse(body.hasPrefix("---"))
    }

    func testClaudeSeedPrefersFiledNoteOverStaging() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-claude-seed-\(UUID().uuidString)", isDirectory: true)
        let staging = dir.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript = dir.appendingPathComponent("2026-07-23-1100 - Meeting.md")
        try "transcript".write(to: transcript, atomically: true, encoding: .utf8)

        let filed = dir.appendingPathComponent("filed.md")
        try "## Executive Summary\nFiled body".write(to: filed, atomically: true, encoding: .utf8)

        let staged = SummaryService.stagingURL(for: transcript, backend: .claude, stagingDir: staging)
        try "## Executive Summary\nStaging body".write(to: staged, atomically: true, encoding: .utf8)

        let candidate = SummaryComparison.claudeSeedCandidate(
            filedNoteURL: filed,
            transcriptURL: transcript,
            stagingDir: staging)
        XCTAssertEqual(candidate?.source, .filedNote)
        XCTAssertEqual(candidate?.url, filed)
    }

    func testClaudeSeedUsesStagingWhenNoFiledNote() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-claude-seed-\(UUID().uuidString)", isDirectory: true)
        let staging = dir.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript = dir.appendingPathComponent("2026-07-23-1100 - Meeting.md")
        try "transcript".write(to: transcript, atomically: true, encoding: .utf8)

        let staged = SummaryService.stagingURL(for: transcript, backend: .claude, stagingDir: staging)
        try "## Executive Summary\nStaging body".write(to: staged, atomically: true, encoding: .utf8)

        let candidate = SummaryComparison.claudeSeedCandidate(
            filedNoteURL: nil,
            transcriptURL: transcript,
            stagingDir: staging)
        XCTAssertEqual(candidate?.source, .stagingDraft)
        XCTAssertEqual(candidate?.url, staged)
    }

    func testClaudeSeedUsesLegacyStagingWhenNoDualBackendFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-claude-seed-\(UUID().uuidString)", isDirectory: true)
        let staging = dir.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript = dir.appendingPathComponent("2026-07-23-1100 - Meeting.md")
        try "transcript".write(to: transcript, atomically: true, encoding: .utf8)

        let legacy = SummaryService.legacyStagingURL(for: transcript, stagingDir: staging)
        try "## Executive Summary\nLegacy".write(to: legacy, atomically: true, encoding: .utf8)

        let candidate = SummaryComparison.claudeSeedCandidate(
            filedNoteURL: nil,
            transcriptURL: transcript,
            stagingDir: staging)
        XCTAssertEqual(candidate?.source, .stagingDraft)
        XCTAssertEqual(candidate?.url, legacy)
    }

    func testClaudeSeedIgnoresOtherBackendStaging() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-claude-seed-\(UUID().uuidString)", isDirectory: true)
        let staging = dir.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript = dir.appendingPathComponent("2026-07-23-1100 - Meeting.md")
        try "transcript".write(to: transcript, atomically: true, encoding: .utf8)

        let composer = SummaryService.stagingURL(for: transcript, backend: .composer25, stagingDir: staging)
        try "## Executive Summary\nComposer".write(to: composer, atomically: true, encoding: .utf8)

        let candidate = SummaryComparison.claudeSeedCandidate(
            filedNoteURL: nil,
            transcriptURL: transcript,
            stagingDir: staging)
        XCTAssertNil(candidate)
    }
}
