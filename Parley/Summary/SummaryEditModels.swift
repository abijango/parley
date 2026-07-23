import Foundation

/// Checker edit operation applied to the writer draft.
enum SummaryEditOperation: String, Codable, CaseIterable, Sendable {
    case insert
    case replace
    case delete
}

/// Per-hunk review state in the markup UI.
enum SummaryHunkStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case rejected
}

/// One checker-proposed edit, stored in SQLite and reviewed in the markup pane.
struct SummaryHunk: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let runID: String
    let sortIndex: Int
    var op: SummaryEditOperation
    var target: String
    var afterAnchor: String
    var text: String
    var reason: String
    var status: SummaryHunkStatus
    var overrideText: String?

    /// Effective replacement/insert text after inline user edit.
    var effectiveText: String {
        let t = overrideText ?? text
        return t
    }

    static func pending(id: String = UUID().uuidString,
                        runID: String,
                        sortIndex: Int,
                        op: SummaryEditOperation,
                        target: String = "",
                        afterAnchor: String = "",
                        text: String = "",
                        reason: String = "") -> SummaryHunk {
        SummaryHunk(id: id, runID: runID, sortIndex: sortIndex, op: op, target: target,
                    afterAnchor: afterAnchor, text: text, reason: reason,
                    status: .pending, overrideText: nil)
    }
}

/// Persisted Summary v2 pipeline run (writer draft + checker output).
struct SummaryRunRecord: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let transcriptID: String
    let transcriptPath: String
    let createdAt: Date
    let writerBackend: String
    let checkerBackend: String
    let draftMarkdown: String
    let checkerRaw: String
    let checkerParseOK: Bool
}

/// Segment for markup decoration in the review pane.
enum SummaryMarkupSegment: Equatable, Sendable {
    case plain(String)
    case insertion(String, hunkID: String, reason: String)
    case deletion(String, hunkID: String, reason: String)
    case replacement(old: String, new: String, hunkID: String, reason: String)
}
