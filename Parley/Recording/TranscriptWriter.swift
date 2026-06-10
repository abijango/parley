import Foundation

/// Frontmatter metadata embedded at the top of every transcript `.md`.
///
/// Obsidian renders this as note properties; the History tab reads it directly.
/// YAML at the top of the file is inert to the downstream skill (which reads the body).
struct TranscriptMeta {
    var title: String
    var date: Date
    var attendees: [String]
    var filing: String
    var status: String        // "unprocessed" | "processed"
    var note: String?         // path to the produced polished note, once processed
    var audio: String?        // path to the session audio (.caf), if archived
    var type: String          // "recording" | "manual"
}

/// Writes the final transcript to the app-owned vault folder as Markdown.
///
/// Emits a YAML frontmatter block (read by the History tab and shown as Obsidian
/// properties) followed by a human-readable header and the speaker-labeled,
/// timestamped transcript body the downstream `process-meeting-transcript` skill expects.
enum TranscriptWriter {
    struct Result {
        let url: URL
    }

    // MARK: Body assembly

    /// Builds the full markdown document: frontmatter + header + transcript (+ manual notes).
    static func makeBody(title: String,
                         date: Date,
                         attendees: String,
                         destination: String,
                         segments: [Segment],
                         manualNotes: String? = nil,
                         meta metaOverride: TranscriptMeta? = nil) -> String {
        let attendeeList = splitAttendees(attendees)
        let meta = metaOverride ?? TranscriptMeta(
            title: title.isEmpty ? "Untitled Meeting" : title,
            date: date,
            attendees: attendeeList,
            filing: destination,
            status: "unprocessed",
            note: nil,
            audio: nil,
            type: "recording"
        )

        var out: [String] = []
        out.append(renderFrontmatter(meta))

        // Human header — joined by hard line breaks so each is its own line.
        var headerMeta = ["**Date:** \(isoDate(date))"]
        if !destination.trimmingCharacters(in: .whitespaces).isEmpty {
            headerMeta.append("**Filing:** \(destination)")
        }
        if !attendees.trimmingCharacters(in: .whitespaces).isEmpty {
            headerMeta.append("**Attendees:** \(attendees)")
        }

        out.append("# \(meta.title)")
        out.append("")
        out.append(headerMeta.joined(separator: "  \n"))   // "  \n" = Markdown hard break
        out.append("")

        if let notes = manualNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            out.append("## Notes (manual)")
            out.append("")
            out.append(notes)
            out.append("")
        }

        out.append("## Transcript")
        out.append("")
        // Blank line between segments so each renders as its own line/paragraph.
        out.append(segments.map(\.markdownLine).joined(separator: "\n\n"))
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Combining

    /// One source recording feeding into a combined transcript.
    struct CombinePart {
        let title: String
        let date: Date
        let manualNotes: String?
        let transcript: String
    }

    /// Splits a transcript document's body into its manual-notes and transcript
    /// sections, so several can be stitched into one combined note. Lenient: a file
    /// with no `## Transcript` (e.g. a manual note) yields an empty transcript.
    static func extractBodySections(text: String) -> (manualNotes: String?, transcript: String) {
        let lines = text.components(separatedBy: "\n")

        // Transcript: everything after the "## Transcript" header to EOF.
        var transcript = ""
        if let tIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Transcript" }) {
            transcript = lines[(tIdx + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Manual notes: between a "## Notes…" header and the next "## " header (or EOF).
        var notes: String?
        if let nIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## Notes") }) {
            var end = lines.count
            var j = nIdx + 1
            while j < lines.count {
                if lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("## ") { end = j; break }
                j += 1
            }
            let body = lines[(nIdx + 1)..<end].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            notes = body.isEmpty ? nil : body
        }
        return (notes, transcript)
    }

    /// Assembles one combined document from several source recordings, ordered as
    /// given. Each part's transcript sits under a `### Part N` header carrying its
    /// real start time (timelines restart at 00:00:00 per recording, so they're kept
    /// per-part rather than re-based). Manual notes, if any, are gathered up front.
    static func makeCombinedBody(meta: TranscriptMeta, parts: [CombinePart]) -> String {
        var out: [String] = []
        out.append(renderFrontmatter(meta))

        var headerMeta = ["**Date:** \(isoDate(meta.date))"]
        if !meta.filing.trimmingCharacters(in: .whitespaces).isEmpty {
            headerMeta.append("**Filing:** \(meta.filing)")
        }
        if !meta.attendees.isEmpty {
            headerMeta.append("**Attendees:** \(meta.attendees.joined(separator: ", "))")
        }
        out.append("# \(meta.title)")
        out.append("")
        out.append(headerMeta.joined(separator: "  \n"))
        out.append("")
        out.append("> Combined from \(parts.count) recordings.")
        out.append("")

        let noted = parts.filter { !($0.manualNotes ?? "").isEmpty }
        if !noted.isEmpty {
            out.append("## Notes (manual)")
            out.append("")
            for p in noted {
                out.append("### \(p.title) — \(sectionStamp(p.date))")
                out.append("")
                out.append(p.manualNotes ?? "")
                out.append("")
            }
        }

        out.append("## Transcript")
        out.append("")
        for (i, p) in parts.enumerated() {
            out.append("### Part \(i + 1): \(p.title) — \(sectionStamp(p.date))")
            out.append("")
            out.append(p.transcript.isEmpty ? "_(no transcript text)_" : p.transcript)
            out.append("")
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    /// Builds a manual-only document (no recorded segments).
    static func makeManualBody(meta: TranscriptMeta, notes: String) -> String {
        var out: [String] = []
        out.append(renderFrontmatter(meta))
        var headerMeta = ["**Date:** \(isoDate(meta.date))"]
        if !meta.filing.trimmingCharacters(in: .whitespaces).isEmpty {
            headerMeta.append("**Filing:** \(meta.filing)")
        }
        if !meta.attendees.isEmpty {
            headerMeta.append("**Attendees:** \(meta.attendees.joined(separator: ", "))")
        }
        out.append("# \(meta.title)")
        out.append("")
        out.append(headerMeta.joined(separator: "  \n"))
        out.append("")
        out.append("## Notes")
        out.append("")
        out.append(notes.trimmingCharacters(in: .whitespacesAndNewlines))
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Writing

    /// Writes the transcript and returns its URL. Creates the folder if needed.
    /// Defaults the body to a `recording`/`unprocessed` document built from the args.
    @discardableResult
    static func write(title rawTitle: String,
                      date: Date,
                      attendees: String,
                      destination: String,
                      segments: [Segment],
                      manualNotes: String? = nil,
                      audioPath: String? = nil,
                      folderURL: URL,
                      type: String = "recording",
                      status: String = "unprocessed") throws -> Result {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled Meeting" : rawTitle
        let meta = TranscriptMeta(
            title: title, date: date, attendees: splitAttendees(attendees),
            filing: destination, status: status, note: nil, audio: audioPath, type: type
        )
        let filename = "\(fileStamp(date)) - \(sanitize(title)).md"
        let url = folderURL.appendingPathComponent(filename)
        let body = makeBody(title: title, date: date, attendees: attendees,
                            destination: destination, segments: segments,
                            manualNotes: manualNotes, meta: meta)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return Result(url: url)
    }

    /// Snapshot-based transcript rewrite for the offline queue and speaker review —
    /// the `self`-free sibling of `RecordingController.rewriteLastTranscript`. Takes its
    /// metadata explicitly (never reads live controller state), preserves any manual
    /// notes already in the file, and regenerates the body from `segments`. Callers MUST
    /// gate this with `TranscriptCoverage.isSafeReplacement` so a thin offline pass can
    /// never overwrite a fuller transcript.
    static func rewriteTranscriptFile(at url: URL, segments: [Segment],
                                      title: String, filing: String, attendees: String) {
        guard var meta = parseFrontmatter(url) else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { meta.title = t }
        let f = filing.trimmingCharacters(in: .whitespaces)
        if !f.isEmpty { meta.filing = f }
        meta.attendees = splitAttendees(attendees)

        if segments.isEmpty {
            // Metadata-only re-stamp (no body to regenerate).
            updateFrontmatter(at: url) { m in
                m.title = meta.title; m.filing = meta.filing; m.attendees = meta.attendees
            }
            return
        }
        // Keep any manual notes the file already carries (they're not in `segments`).
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let (notes, _) = extractBodySections(text: existing)
        let body = makeBody(title: meta.title, date: meta.date, attendees: attendees,
                            destination: meta.filing, segments: segments,
                            manualNotes: notes, meta: meta)
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Frontmatter — render / parse / update

    /// Renders a `--- ... ---` YAML frontmatter block (without a trailing newline beyond the block).
    static func renderFrontmatter(_ meta: TranscriptMeta) -> String {
        var lines: [String] = ["---"]
        lines.append("title: \(yamlScalar(meta.title))")
        lines.append("date: \(isoDateTime(meta.date))")
        if meta.attendees.isEmpty {
            lines.append("attendees: []")
        } else {
            lines.append("attendees:")
            for a in meta.attendees { lines.append("  - \(yamlScalar(a))") }
        }
        lines.append("filing: \(yamlScalar(meta.filing))")
        lines.append("status: \(yamlScalar(meta.status))")
        if let note = meta.note { lines.append("note: \(yamlScalar(note))") }
        if let audio = meta.audio { lines.append("audio: \(yamlScalar(audio))") }
        lines.append("type: \(yamlScalar(meta.type))")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// Leniently parses the leading YAML frontmatter block of a file.
    static func parseFrontmatter(_ url: URL) -> TranscriptMeta? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseFrontmatter(text: text)
    }

    /// Parses frontmatter from in-memory text. Returns nil if no leading block.
    static func parseFrontmatter(text: String) -> TranscriptMeta? {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        // Find the closing fence.
        var closeIdx: Int?
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closeIdx = i; break
        }
        guard let close = closeIdx else { return nil }

        var title = ""
        var date = Date()
        var attendees: [String] = []
        var filing = ""
        var status = ""
        var note: String?
        var audio: String?
        var type = ""

        var i = 1
        while i < close {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // attendees list item
            if trimmed.hasPrefix("- ") {
                let item = unquote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                if !item.isEmpty { attendees.append(item) }
                i += 1
                continue
            }
            guard let colon = raw.firstIndex(of: ":") else { i += 1; continue }
            let key = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            switch key {
            case "title": title = value
            case "date": date = parseISODate(value) ?? date
            case "filing": filing = value
            case "status": status = value
            case "note": note = value.isEmpty ? nil : value
            case "audio": audio = value.isEmpty ? nil : value
            case "type": type = value
            case "attendees":
                // Inline form: "attendees: [a, b]" or single value; list-form handled above.
                if value.hasPrefix("[") {
                    let inner = value.dropFirst().dropLast(value.hasSuffix("]") ? 1 : 0)
                    attendees = inner.split(separator: ",")
                        .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                        .filter { !$0.isEmpty }
                } else if !value.isEmpty {
                    attendees = [value]
                }
            default: break
            }
            i += 1
        }

        return TranscriptMeta(title: title, date: date, attendees: attendees,
                              filing: filing, status: status, note: note,
                              audio: audio, type: type.isEmpty ? "recording" : type)
    }

    /// Rewrites just the frontmatter block in place, preserving the body.
    static func updateFrontmatter(at url: URL, _ mutate: (inout TranscriptMeta) -> Void) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard var meta = parseFrontmatter(text: text) else {
            // No frontmatter: prepend a fresh block.
            var seed = TranscriptMeta(title: "", date: Date(), attendees: [], filing: "",
                                      status: "", note: nil, audio: nil, type: "recording")
            mutate(&seed)
            let combined = renderFrontmatter(seed) + "\n" + text
            try? combined.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        mutate(&meta)

        // Split off the existing frontmatter block and keep the body after it.
        let lines = text.components(separatedBy: "\n")
        var close = 0
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            close = i; break
        }
        let body = lines[(close + 1)...].joined(separator: "\n")
        let combined = renderFrontmatter(meta) + "\n" + body
        try? combined.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: YAML helpers

    /// Quotes a scalar when it could be misread as YAML.
    private static func yamlScalar(_ s: String) -> String {
        let needsQuote = s.isEmpty
            || s.contains(":") || s.contains("#") || s.contains("\"")
            || s.hasPrefix("[") || s.hasPrefix("{") || s.hasPrefix("- ")
            || s.first == " " || s.last == " "
        if needsQuote {
            let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return s
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
            v = v.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return v
    }

    static func splitAttendees(_ attendees: String) -> [String] {
        attendees.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Date formatting

    /// The `YYYY-MM-DD-HHMM` filename prefix (shared with crash recovery so a
    /// recovered note matches a normally-written one).
    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: date)
    }

    /// The standard transcript filename for a title/date: `YYYY-MM-DD-HHMM - <title>.md`.
    static func filename(title: String, date: Date) -> String {
        let safe = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled Meeting" : title
        return "\(fileStamp(date)) - \(sanitize(safe)).md"
    }

    static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Date + time for a combined transcript's per-part header (so each part shows
    /// the real wall-clock time it was recorded).
    static func sectionStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// Full timestamp for the frontmatter `date:` field, so the History tab shows the
    /// real recording time and sorts same-day items correctly. The human-readable
    /// `**Date:**` header line stays date-only via `isoDate`.
    static func isoDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    /// Parses either the full `yyyy-MM-dd HH:mm:ss` timestamp or a legacy date-only
    /// `yyyy-MM-dd` value (older transcripts).
    static func parseISODate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    /// Removes characters illegal in filenames (notably `/` and `:` on macOS).
    static func sanitize(_ title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return title.components(separatedBy: illegal).joined(separator: "-")
    }
}

/// Decides whether an offline-pass result is a *safe* replacement for an already-saved
/// transcript. The offline batch ASR can silently truncate (e.g. a long recording under
/// memory pressure, or audio that was itself truncated) and return only the first couple
/// of minutes. Without this guard, that thin result overwrites a complete transcript —
/// the 2026-06-08 incident where a 3-minute pass destroyed a 43-minute meeting. The rule:
/// only replace when the offline result covers most of the recording AND has a comparable
/// number of lines to what's already there.
enum TranscriptCoverage {
    /// Latest segment end time across a timeline (seconds).
    static func span(_ segments: [Segment]) -> TimeInterval { segments.map(\.end).max() ?? 0 }

    /// Parse a saved transcript's body for its last `[HH:MM:SS]` timestamp and the number
    /// of timestamped speaker lines — the baseline to compare an offline result against.
    static func spanFromTranscriptFile(_ url: URL) -> (span: TimeInterval, lines: Int) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (0, 0) }
        return spanFromText(text)
    }

    static func spanFromText(_ text: String) -> (span: TimeInterval, lines: Int) {
        var maxSec: TimeInterval = 0
        var lines = 0
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("**[") || line.hasPrefix("[") else { continue }
            guard let open = line.firstIndex(of: "["),
                  let close = line[open...].firstIndex(of: "]") else { continue }
            let stamp = line[line.index(after: open)..<close]
            let parts = stamp.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            maxSec = max(maxSec, TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2]))
            lines += 1
        }
        return (maxSec, lines)
    }

    /// True when `offline` may safely overwrite the transcript at `existingFile`.
    /// Coverage is measured by **span** (how many seconds of the recording the offline
    /// pass spans), NOT segment count: live-streaming ASR and batch ASR chunk audio at
    /// very different granularities, so comparing counts spuriously rejects a perfectly
    /// good — just coarser — offline result and strands the diarized speaker names. Span
    /// still catches the real failure mode (a truncated pass, e.g. 3 min of a 43-min
    /// call → 7% span). An empty result is always rejected (handled upstream too).
    static func isSafeReplacement(offline: [Segment], existingFile: URL,
                                  audioDuration: TimeInterval, minRatio: Double = 0.8) -> Bool {
        guard !offline.isEmpty else { return false }
        let (existingSpan, _) = spanFromTranscriptFile(existingFile)
        let reference = max(audioDuration, existingSpan)
        guard reference > 0 else { return true }   // no baseline to compare → accept
        return span(offline) >= minRatio * reference
    }
}
