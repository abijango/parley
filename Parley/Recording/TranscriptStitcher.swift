import Foundation

/// Pure text-level "transcript stitch" (C1 backend for call merge).
///
/// Combines two or more Parley meeting notes that were produced by a single
/// dropped-and-rejoined call into one note.  Each later leg's `[HH:MM:SS]`
/// timestamps are shifted forward by the running sum of the preceding legs'
/// durations so the combined timeline reads as continuous.  A
/// `**\u{2014} reconnected \u{2014}**` (em-dash) seam marker separates each
/// leg's transcript block.
///
/// This is intentionally free of I/O and side-effects — the caller owns reading
/// and writing files.
enum TranscriptStitcher {

    // MARK: - Public API

    /// Stitch `notes` into one combined Parley meeting note.
    ///
    /// - Parameters:
    ///   - notes: Full note text (frontmatter + header + body) for each leg,
    ///     ordered by recording start time.  `notes[0]` is the base leg.
    ///   - durations: Wall-clock length in seconds for each leg.
    ///     `durations.count` must equal `notes.count`.
    /// - Returns: A single Parley-format note whose timestamps are re-based so
    ///   the first leg starts at 00:00:00 and every subsequent leg continues
    ///   from where the previous ended.  When `notes.count < 2` the first note
    ///   is returned verbatim.
    static func stitch(notes: [String], durations: [TimeInterval]) -> String {
        precondition(notes.count == durations.count,
                     "TranscriptStitcher.stitch: notes and durations must have the same count")
        guard notes.count >= 2 else { return notes.first ?? "" }

        // --- Parse note[0] as the canonical base ---
        guard var meta0 = TranscriptWriter.parseFrontmatter(text: notes[0]) else {
            // Malformed base — fall back to naive concatenation.
            return notes[0]
        }

        // Collect per-leg transcript bodies (trimmed, ready to stitch).
        var legTranscripts: [String] = []
        var allAttendees: [String] = Array(meta0.attendees)   // start from base

        for (k, note) in notes.enumerated() {
            let (_, transcriptBody) = TranscriptWriter.extractBodySections(text: note)

            if k == 0 {
                // Leg 0: keep as-is (no offset shift needed).
                legTranscripts.append(transcriptBody)
            } else {
                // Leg k: shift all timestamps by the running sum of durations[0..<k].
                let offset = durations[0..<k].reduce(0, +)
                let shifted = shiftTimestamps(in: transcriptBody, by: offset)
                legTranscripts.append(shifted)
            }

            // Union attendees from every leg (case-insensitive, order-preserving).
            if k > 0, let metaK = TranscriptWriter.parseFrontmatter(text: note) {
                for attendee in metaK.attendees {
                    let lower = attendee.lowercased()
                    if !allAttendees.contains(where: { $0.lowercased() == lower }) {
                        allAttendees.append(attendee)
                    }
                }
            }
        }

        // Update the base meta with the unioned attendee list.
        meta0.attendees = allAttendees

        // Keep note[0]'s manual notes only.
        let (manualNotes0, _) = TranscriptWriter.extractBodySections(text: notes[0])

        // --- Assemble output ---
        var out: [String] = []

        // Frontmatter with unioned attendees.
        out.append(TranscriptWriter.renderFrontmatter(meta0))

        // Human-readable header (mirrors TranscriptWriter.makeBody layout).
        var headerMeta = ["**Date:** \(TranscriptWriter.isoDate(meta0.date))"]
        if !meta0.filing.trimmingCharacters(in: .whitespaces).isEmpty {
            headerMeta.append("**Filing:** \(meta0.filing)")
        }
        if !allAttendees.isEmpty {
            headerMeta.append("**Attendees:** \(allAttendees.joined(separator: ", "))")
        }
        out.append("# \(meta0.title)")
        out.append("")
        out.append(headerMeta.joined(separator: "  \n"))
        out.append("")

        // Optional manual notes (note[0] only).
        if let notes0 = manualNotes0, !notes0.isEmpty {
            out.append("## Notes (manual)")
            out.append("")
            out.append(notes0)
            out.append("")
        }

        // Transcript section.
        out.append("## Transcript")
        out.append("")

        // The seam marker (U+2014 em-dash on both sides, bold).
        let seam = "**\u{2014} reconnected \u{2014}**"

        // Stitch leg transcripts together separated by seam markers.
        for (k, body) in legTranscripts.enumerated() {
            if k > 0 {
                out.append("")
                out.append(seam)
                out.append("")
            }
            if !body.isEmpty {
                out.append(body)
            }
        }

        // Final trailing newline (matches TranscriptWriter.makeBody).
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Timestamp shifting

    /// Shifts every `[HH:MM:SS]` timestamp in `text` forward by `offset` seconds.
    ///
    /// Only lines that begin with a Parley transcript timestamp are modified;
    /// all other lines pass through unchanged.  The replacement preserves the
    /// full line including leading `**` bold markers and trailing text.
    private static func shiftTimestamps(in text: String, by offset: TimeInterval) -> String {
        let lines = text.components(separatedBy: "\n")
        let shifted = lines.map { line -> String in
            shiftTimestampInLine(line, offset: offset) ?? line
        }
        return shifted.joined(separator: "\n")
    }

    /// Returns a new version of `line` with its leading `[HH:MM:SS]` timestamp
    /// shifted by `offset` seconds, or `nil` if the line has no such timestamp.
    private static func shiftTimestampInLine(_ line: String, offset: TimeInterval) -> String? {
        // Both bold (`**[HH:MM:SS]`) and plain (`[HH:MM:SS]`) forms are supported.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("**[") || trimmed.hasPrefix("[") else { return nil }

        // Locate the opening `[` in the *original* (untrimmed) line so we can
        // do a range replacement that preserves any leading indentation.
        guard let openIdx = line.firstIndex(of: "["),
              let closeIdx = line[openIdx...].firstIndex(of: "]") else { return nil }

        // Parse the existing stamp.
        let stampContent = line[line.index(after: openIdx)..<closeIdx]  // "HH:MM:SS"
        let parts = stampContent.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }

        let originalSeconds = TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        let newSeconds = Int((originalSeconds + offset).rounded())
        let h = newSeconds / 3600
        let m = (newSeconds % 3600) / 60
        let s = newSeconds % 60
        let newStamp = String(format: "[%02d:%02d:%02d]", h, m, s)

        // Replace the `[HH:MM:SS]` range in the original line (keeps `**` prefix and tail).
        let stampRange = openIdx...closeIdx
        var result = line
        result.replaceSubrange(stampRange, with: newStamp)
        return result
    }
}
