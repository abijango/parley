import Foundation

/// One approved meeting used to compare summarizers when a new model ships.
///
/// Picked 2026-09-25 from the Obsidian vault: `2026-08-12-1430 - Cursor Survey Feedback`.
/// Fourteen minutes, every turn attributed to a named speaker, almost no
/// surname-substitution, and a filed note with decisions, an action table, and
/// concrete metrics. The transcript and note stay in the vault; this type only
/// records where to find them.
enum SummaryGroundTruth {
    static let transcriptRelativePath = "Parley/Processed/2026-08-12-1430 - Cursor Survey Feedback.md"
    static let displayTitle = "Cursor Survey Feedback"

    static let rationale = "14-minute call, every turn attributed to a named speaker. The filed note has decisions, an action table, and concrete metrics."

    struct Fixture: Equatable {
        var title: String
        var transcriptURL: URL
        var noteURL: URL
        var attendees: String
        var destination: String
        var goldSummary: String
    }

    static func load(vault: URL) -> Fixture? {
        let transcriptURL = vault.appendingPathComponent(transcriptRelativePath)
        guard FileManager.default.fileExists(atPath: transcriptURL.path),
              let meta = TranscriptWriter.parseFrontmatter(transcriptURL),
              let notePath = meta.note, !notePath.isEmpty else { return nil }
        let noteURL = URL(fileURLWithPath: notePath)
        guard let noteText = try? String(contentsOf: noteURL, encoding: .utf8) else { return nil }
        let gold = SummaryAccuracy.summaryBody(noteText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gold.isEmpty else { return nil }
        return Fixture(
            title: meta.title.isEmpty ? transcriptURL.deletingPathExtension().lastPathComponent : meta.title,
            transcriptURL: transcriptURL,
            noteURL: noteURL,
            attendees: meta.attendees.joined(separator: ", "),
            destination: meta.filing,
            goldSummary: gold)
    }
}

/// Outcome of one ground-truth generation, including the metrics the queue already records.
enum SummaryEvalRunResult: Sendable {
    case success(String, SummaryRunMetrics)
    case failed(String)
}
