import XCTest
import SQLite3
@testable import Parley

final class SummaryRunStoreMetricsTests: XCTestCase {

    func testV1RunRoundTripsWithMetrics() {
        let db = KnowledgeDatabase.openTemporary()
        let store = SummaryRunStore(database: db)
        let metrics = SummaryRunMetrics(wallClock: 12.5, inputTokens: 4000, outputTokens: 800,
                                        reportedCostUSD: 0.042, model: "sonnet")
        let run = SummaryRunRecord(
            id: "run-v1",
            transcriptID: "/tmp/transcript.md",
            transcriptPath: "/tmp/transcript.md",
            createdAt: Date(timeIntervalSince1970: 1_000),
            pipeline: .classic,
            writerBackend: "claude",
            checkerBackend: "",
            draftMarkdown: "## Summary\nBody",
            writerMetrics: metrics
        )
        store.insertRun(run, hunks: [])
        let loaded = store.runs(forTranscriptID: "/tmp/transcript.md")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].pipeline, .classic)
        XCTAssertEqual(loaded[0].writerMetrics, metrics)
        XCTAssertNil(loaded[0].checkerMetrics)
    }

    func testExistingRowsDefaultToV2Pipeline() throws {
        let db = KnowledgeDatabase.openTemporary()
        db.withDB { sqlite in
            sqlite3_exec(sqlite, """
                INSERT INTO summary_runs(id, transcript_id, transcript_path, created_at,
                    writer_backend, checker_backend, draft_markdown, checker_raw, checker_parse_ok)
                VALUES ('legacy', '/t.md', '/t.md', 1000, 'claude', 'grok', 'draft', '', 0);
                """, nil, nil, nil)
        }
        let store = SummaryRunStore(database: db)
        let run = try XCTUnwrap(store.run(id: "legacy"))
        XCTAssertEqual(run.pipeline, .v2)
        XCTAssertNil(run.writerMetrics)
    }

    func testRunPickerExcludesV1Runs() {
        let db = KnowledgeDatabase.openTemporary()
        let store = SummaryRunStore(database: db)
        store.insertRun(SummaryRunRecord(
            id: "v1", transcriptID: "/t.md", transcriptPath: "/t.md",
            createdAt: Date(), pipeline: .classic,
            writerBackend: "claude", checkerBackend: "", draftMarkdown: "d"), hunks: [])
        store.insertRun(SummaryRunRecord(
            id: "v2", transcriptID: "/t.md", transcriptPath: "/t.md",
            createdAt: Date().addingTimeInterval(1), pipeline: .v2,
            writerBackend: "claude", checkerBackend: "grok", draftMarkdown: "d"), hunks: [])
        let v2Only = store.runs(forTranscriptID: "/t.md").filter { $0.pipeline == .v2 }
        XCTAssertEqual(v2Only.map(\.id), ["v2"])
    }
}
