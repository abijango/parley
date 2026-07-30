import Foundation
import SQLite3

/// CRUD for summary run history and checker hunks.
final class SummaryRunStore: @unchecked Sendable {
    private let db: KnowledgeDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(database: KnowledgeDatabase = .shared) {
        self.db = database
    }

    // MARK: Runs

    func insertRun(_ run: SummaryRunRecord, hunks: [SummaryHunk]) {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(sqlite, """
                INSERT INTO summary_runs(id, transcript_id, transcript_path, created_at,
                    pipeline, writer_backend, checker_backend, draft_markdown, checker_raw,
                    checker_parse_ok, writer_metrics_json, checker_metrics_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, -1, &stmt, nil)
            KnowledgeSQL.bind(stmt, 1, run.id)
            KnowledgeSQL.bind(stmt, 2, run.transcriptID)
            KnowledgeSQL.bind(stmt, 3, run.transcriptPath)
            sqlite3_bind_double(stmt, 4, run.createdAt.timeIntervalSince1970)
            KnowledgeSQL.bind(stmt, 5, run.pipeline.rawValue)
            KnowledgeSQL.bind(stmt, 6, run.writerBackend)
            KnowledgeSQL.bind(stmt, 7, run.checkerBackend)
            KnowledgeSQL.bind(stmt, 8, run.draftMarkdown)
            KnowledgeSQL.bind(stmt, 9, run.checkerRaw)
            sqlite3_bind_int(stmt, 10, run.checkerParseOK ? 1 : 0)
            KnowledgeSQL.bind(stmt, 11, Self.encodeMetrics(run.writerMetrics, encoder: encoder))
            KnowledgeSQL.bind(stmt, 12, Self.encodeMetrics(run.checkerMetrics, encoder: encoder))
            sqlite3_step(stmt)
        }
        replaceHunks(runID: run.id, hunks: hunks)
    }

    func runs(forTranscriptID transcriptID: String) -> [SummaryRunRecord] {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(sqlite, """
                SELECT id, transcript_id, transcript_path, created_at, pipeline, writer_backend,
                       checker_backend, draft_markdown, checker_raw, checker_parse_ok,
                       writer_metrics_json, checker_metrics_json
                FROM summary_runs WHERE transcript_id = ? ORDER BY created_at DESC;
                """, -1, &stmt, nil) == SQLITE_OK else { return [] }
            KnowledgeSQL.bind(stmt, 1, transcriptID)
            var rows: [SummaryRunRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(runRow(stmt))
            }
            return rows
        }
    }

    func run(id: String) -> SummaryRunRecord? {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(sqlite, """
                SELECT id, transcript_id, transcript_path, created_at, pipeline, writer_backend,
                       checker_backend, draft_markdown, checker_raw, checker_parse_ok,
                       writer_metrics_json, checker_metrics_json
                FROM summary_runs WHERE id = ?;
                """, -1, &stmt, nil) == SQLITE_OK else { return nil }
            KnowledgeSQL.bind(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return runRow(stmt)
        }
    }

    func latestRun(forTranscriptID transcriptID: String) -> SummaryRunRecord? {
        runs(forTranscriptID: transcriptID).first
    }

    func hasRuns(forTranscriptID transcriptID: String) -> Bool {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(sqlite,
                "SELECT 1 FROM summary_runs WHERE transcript_id = ? LIMIT 1;",
                -1, &stmt, nil) == SQLITE_OK else { return false }
            KnowledgeSQL.bind(stmt, 1, transcriptID)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    // MARK: Hunks

    func hunks(forRunID runID: String) -> [SummaryHunk] {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(sqlite, """
                SELECT id, run_id, sort_index, op, target, after_anchor, text, reason, status, override_text
                FROM summary_hunks WHERE run_id = ? ORDER BY sort_index;
                """, -1, &stmt, nil) == SQLITE_OK else { return [] }
            KnowledgeSQL.bind(stmt, 1, runID)
            var rows: [SummaryHunk] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(hunkRow(stmt))
            }
            return rows
        }
    }

    func replaceHunks(runID: String, hunks: [SummaryHunk]) {
        db.withDB { sqlite in
            var del: OpaquePointer?
            defer { sqlite3_finalize(del) }
            sqlite3_prepare_v2(sqlite, "DELETE FROM summary_hunks WHERE run_id = ?;", -1, &del, nil)
            KnowledgeSQL.bind(del, 1, runID)
            sqlite3_step(del)
        }
        for hunk in hunks {
            insertHunkPrivate(hunk)
        }
    }

    func updateHunk(_ hunk: SummaryHunk) {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(sqlite, """
                UPDATE summary_hunks SET status = ?, override_text = ?, text = ?, reason = ?
                WHERE id = ?;
                """, -1, &stmt, nil)
            KnowledgeSQL.bind(stmt, 1, hunk.status.rawValue)
            KnowledgeSQL.bindOptional(stmt, 2, hunk.overrideText)
            KnowledgeSQL.bind(stmt, 3, hunk.text)
            KnowledgeSQL.bind(stmt, 4, hunk.reason)
            KnowledgeSQL.bind(stmt, 5, hunk.id)
            sqlite3_step(stmt)
        }
    }

    func updateDraftMarkdown(runID: String, markdown: String) {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(sqlite,
                "UPDATE summary_runs SET draft_markdown = ? WHERE id = ?;",
                -1, &stmt, nil)
            KnowledgeSQL.bind(stmt, 1, markdown)
            KnowledgeSQL.bind(stmt, 2, runID)
            sqlite3_step(stmt)
        }
    }

    func insertHunk(_ hunk: SummaryHunk) {
        // Public wrapper used when the reviewer adds a human correction hunk.
        insertHunkPrivate(hunk)
    }

    private func insertHunkPrivate(_ hunk: SummaryHunk) {
        db.withDB { sqlite in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(sqlite, """
                INSERT INTO summary_hunks(id, run_id, sort_index, op, target, after_anchor, text, reason, status, override_text)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, -1, &stmt, nil)
            KnowledgeSQL.bind(stmt, 1, hunk.id)
            KnowledgeSQL.bind(stmt, 2, hunk.runID)
            sqlite3_bind_int(stmt, 3, Int32(hunk.sortIndex))
            KnowledgeSQL.bind(stmt, 4, hunk.op.rawValue)
            KnowledgeSQL.bind(stmt, 5, hunk.target)
            KnowledgeSQL.bind(stmt, 6, hunk.afterAnchor)
            KnowledgeSQL.bind(stmt, 7, hunk.text)
            KnowledgeSQL.bind(stmt, 8, hunk.reason)
            KnowledgeSQL.bind(stmt, 9, hunk.status.rawValue)
            KnowledgeSQL.bindOptional(stmt, 10, hunk.overrideText)
            sqlite3_step(stmt)
        }
    }

    private func runRow(_ stmt: OpaquePointer?) -> SummaryRunRecord {
        let pipelineRaw = KnowledgeSQL.text(stmt, 4)
        let pipeline = SummaryPipeline(rawValue: pipelineRaw) ?? .v2
        return SummaryRunRecord(
            id: KnowledgeSQL.text(stmt, 0),
            transcriptID: KnowledgeSQL.text(stmt, 1),
            transcriptPath: KnowledgeSQL.text(stmt, 2),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
            pipeline: pipeline,
            writerBackend: KnowledgeSQL.text(stmt, 5),
            checkerBackend: KnowledgeSQL.text(stmt, 6),
            draftMarkdown: KnowledgeSQL.text(stmt, 7),
            checkerRaw: KnowledgeSQL.text(stmt, 8),
            checkerParseOK: sqlite3_column_int(stmt, 9) != 0,
            writerMetrics: Self.decodeMetrics(KnowledgeSQL.text(stmt, 10), decoder: decoder),
            checkerMetrics: Self.decodeMetrics(KnowledgeSQL.text(stmt, 11), decoder: decoder)
        )
    }

    private static func encodeMetrics(_ metrics: SummaryRunMetrics?, encoder: JSONEncoder) -> String {
        guard let metrics,
              let data = try? encoder.encode(metrics),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    private static func decodeMetrics(_ json: String, decoder: JSONDecoder) -> SummaryRunMetrics? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(SummaryRunMetrics.self, from: data)
    }

    private func hunkRow(_ stmt: OpaquePointer?) -> SummaryHunk {
        SummaryHunk(
            id: KnowledgeSQL.text(stmt, 0),
            runID: KnowledgeSQL.text(stmt, 1),
            sortIndex: Int(sqlite3_column_int(stmt, 2)),
            op: SummaryEditOperation(rawValue: KnowledgeSQL.text(stmt, 3)) ?? .replace,
            target: KnowledgeSQL.text(stmt, 4),
            afterAnchor: KnowledgeSQL.text(stmt, 5),
            text: KnowledgeSQL.text(stmt, 6),
            reason: KnowledgeSQL.text(stmt, 7),
            status: SummaryHunkStatus(rawValue: KnowledgeSQL.text(stmt, 8)) ?? .pending,
            overrideText: KnowledgeSQL.optionalText(stmt, 9)
        )
    }
}
