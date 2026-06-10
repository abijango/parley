import XCTest
@testable import Parley

/// Regression coverage for the offline-processing decoupling: the transcript-overwrite
/// safety guard, the manifest's new offline-status fields, the attendee-merge reconciler,
/// and the queue's name-union helper.
final class OfflineQueueTests: XCTestCase {

    // MARK: TranscriptCoverage — the Bug-A data-loss guard

    private func seg(_ start: Double, _ end: Double) -> Segment {
        Segment(track: .me, start: start, end: end, text: "x", confirmed: true)
    }

    /// Write a transcript file with `count` timestamped lines spanning up to `lastSec`.
    private func writeTranscript(lines count: Int, lastSec: Int) -> URL {
        var body = "---\ntitle: T\n---\n# T\n\n## Transcript\n\n"
        for i in 0..<count {
            let sec = count <= 1 ? lastSec : lastSec * i / (count - 1)
            let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
            body += String(format: "**[%02d:%02d:%02d] Me:** line %d\n\n", h, m, s, i)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cov-\(UUID().uuidString).md")
        try! body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testThinOfflinePassIsRejected() {
        // The incident: a 43-minute transcript (~672 lines) vs a 3-minute offline result.
        let existing = writeTranscript(lines: 672, lastSec: 43 * 60)
        defer { try? FileManager.default.removeItem(at: existing) }
        let offline = (0..<10).map { seg(Double($0) * 12, Double($0) * 12 + 11) }   // ~2 min, 10 segs
        XCTAssertFalse(TranscriptCoverage.isSafeReplacement(
            offline: offline, existingFile: existing, audioDuration: 43 * 60))
    }

    func testFullOfflinePassIsAccepted() {
        let existing = writeTranscript(lines: 100, lastSec: 40 * 60)
        defer { try? FileManager.default.removeItem(at: existing) }
        let offline = (0..<100).map { seg(Double($0) * 24, Double($0) * 24 + 20) }   // ~40 min, 100 segs
        XCTAssertTrue(TranscriptCoverage.isSafeReplacement(
            offline: offline, existingFile: existing, audioDuration: 40 * 60))
    }

    func testCoarserOfflineWithFullSpanIsAccepted() {
        // The Andre regression: live transcript = 888 fine segments; offline diarization
        // attributes the SAME 35 min into far fewer, coarser segments. Span is full, so it
        // must be accepted (else the speaker names never land and the note stays stuck).
        let existing = writeTranscript(lines: 888, lastSec: 35 * 60)
        defer { try? FileManager.default.removeItem(at: existing) }
        let offline = (0..<140).map { seg(Double($0) * 15, Double($0) * 15 + 14) }   // ~35 min, 140 segs
        XCTAssertTrue(TranscriptCoverage.isSafeReplacement(
            offline: offline, existingFile: existing, audioDuration: 35 * 60),
            "A coarser-but-full-span offline pass must be accepted")
    }

    func testEmptyOfflinePassIsRejected() {
        let existing = writeTranscript(lines: 50, lastSec: 600)
        defer { try? FileManager.default.removeItem(at: existing) }
        XCTAssertFalse(TranscriptCoverage.isSafeReplacement(
            offline: [], existingFile: existing, audioDuration: 600))
    }

    func testFirstPassWithNoExistingFileIsAccepted() {
        // No existing transcript (lines 0) and offline covers the audio → accept.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID()).md")
        let offline = (0..<30).map { seg(Double($0) * 20, Double($0) * 20 + 18) }   // ~10 min
        XCTAssertTrue(TranscriptCoverage.isSafeReplacement(
            offline: offline, existingFile: empty, audioDuration: 600))
    }

    func testSpanFromTextParsesLastTimestamp() {
        let (span, lines) = TranscriptCoverage.spanFromText(
            "**[00:00:05] Me:** a\n\n**[00:10:00] Remote:** b\n")
        XCTAssertEqual(span, 600, accuracy: 0.5)
        XCTAssertEqual(lines, 2)
    }

    // MARK: SessionManifest — new offline fields + legacy decode

    func testManifestOfflineFieldsRoundTrip() throws {
        var m = SessionManifest(
            id: "2026-06-08-160310", title: "T", attendees: "A, B", filing: "",
            model: "m", computeMode: "c", startedAt: Date(timeIntervalSince1970: 1),
            lastHeartbeat: Date(timeIntervalSince1970: 2), status: .finalized,
            startedByDetection: true, callBundleID: nil, callDisplayName: nil,
            manualNotes: "", audioTracks: ["mic.caf"], titleSource: nil, suggestedAttendees: nil)
        m.offlineStatus = .pending
        m.offlineAttempts = 1
        m.transcriptPath = "/tmp/x.md"
        m.presentReviewWhenDone = true
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(SessionManifest.self, from: try enc.encode(m))
        XCTAssertEqual(back.offlineStatus, .pending)
        XCTAssertEqual(back.offlineAttempts, 1)
        XCTAssertEqual(back.transcriptPath, "/tmp/x.md")
        XCTAssertEqual(back.presentReviewWhenDone, true)
    }

    func testLegacyManifestDecodesWithNilOfflineFields() throws {
        // A manifest JSON written before this feature must still decode.
        let legacy = """
        {"id":"s","title":"T","attendees":"","filing":"","model":"m","computeMode":"c",
         "startedAt":"2026-06-08T10:00:00Z","lastHeartbeat":"2026-06-08T10:05:00Z",
         "status":"finalized","startedByDetection":false,"manualNotes":"","audioTracks":[]}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let m = try dec.decode(SessionManifest.self, from: Data(legacy.utf8))
        XCTAssertNil(m.offlineStatus)
        XCTAssertNil(m.transcriptPath)
        XCTAssertNil(m.presentReviewWhenDone)
    }

    // (The old TokenField delta-merge tests were removed with the AppKit bridge — the
    //  pure-SwiftUI TokenField has no sync logic; its commit classification is covered
    //  in TokenFieldTests.)

    // MARK: OfflineProcessingService.merge

    func testAttendeeMergeIsCaseInsensitiveAndOrdered() {
        XCTAssertEqual(OfflineProcessingService.merge("Naufal Mir", with: ["naufal mir", "Vitalii Yuryev"]),
                       "Naufal Mir, Vitalii Yuryev")
        XCTAssertEqual(OfflineProcessingService.merge("", with: ["Solo"]), "Solo")
    }
}
