import Foundation

/// Post-coverage-rejection speaker attribution using diarized turn data.
///
/// When the offline ASR pass fails the `TranscriptCoverage.isSafeReplacement` gate
/// (e.g. the 35-min incident where batch ASR only covered 29% of the recording), the
/// existing live transcript is kept — but it may be entirely generic ("Remote:") because
/// the live pipeline mixed mic + system into one stream. If diarization succeeded in the
/// same offline pass, those turns can be applied directly to the kept transcript body,
/// rewriting generic labels without touching the (correct, fuller) text.
///
/// This is a pure text transform: it reads timestamps already embedded in the transcript,
/// finds the diarized speaker at each line's midpoint, and substitutes the resolved name
/// (or "Speaker <id>" when unresolved — the exact form `SpeakerCache.relabel` matches
/// later if the user names them via the "Assign speakers" review).
enum TranscriptFallbackAttribution {

    // MARK: Public API

    /// Relabel generic speaker lines (`Me`, `Remote`, `Speaker <digits>`) in a transcript
    /// body using diarized turns, for the case where word-level offline ASR failed but
    /// diarization succeeded.
    ///
    /// - Parameters:
    ///   - body: The full transcript file contents (frontmatter + header + transcript body).
    ///   - turns: Diarized speaker turns from the offline pass.
    ///   - resolvedName: Maps a speaker id string to a display name; return nil to fall back
    ///     to `"Speaker <id>"`.
    /// - Returns: The rewritten text and a count of lines whose label changed. If `turns`
    ///   is empty, returns the original body unchanged with 0.
    static func relabel(body: String,
                        turns: [DiarizationAttribution.Turn],
                        resolvedName: (String) -> String?) -> (text: String, changedLines: Int) {
        guard !turns.isEmpty else { return (body, 0) }

        let lines = body.components(separatedBy: "\n")

        // Pre-collect the start timestamp of every transcript line so we can compute each
        // line's end time (= next line's start). We do one pass here, then rewrite below.
        // Index i → parsed start seconds (nil for non-transcript lines).
        var parsedStarts: [TimeInterval?] = Array(repeating: nil, count: lines.count)
        for (i, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // Both bold (`**[HH:MM:SS]`) and unbolded (`[HH:MM:SS]`) forms are accepted.
            guard trimmed.hasPrefix("**[") || trimmed.hasPrefix("[") else { continue }
            if let start = parseTimestamp(trimmed) {
                parsedStarts[i] = start
            }
        }

        var result: [String] = []
        var changed = 0

        for (i, raw) in lines.enumerated() {
            guard let lineStart = parsedStarts[i] else {
                // Not a timestamped transcript line — pass through unchanged.
                result.append(raw)
                continue
            }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Extract the label between the closing `]` of the timestamp and the `:`.
            guard let label = extractLabel(from: trimmed) else {
                result.append(raw)
                continue
            }

            // Only rewrite generic labels. Named lines (real people) are left alone.
            guard isGenericLabel(label) else {
                result.append(raw)
                continue
            }

            // Line's time range: [lineStart, nextLineStart or lineStart+15s].
            let lineEnd: TimeInterval
            if let next = nextTimestamp(after: i, in: parsedStarts) {
                lineEnd = next
            } else {
                lineEnd = lineStart + 15
            }
            let mid = (lineStart + lineEnd) / 2

            guard let speakerId = DiarizationAttribution.speakerAt(mid, turns: turns) else {
                result.append(raw)
                continue
            }

            let newLabel = resolvedName(speakerId) ?? "Speaker \(speakerId)"
            guard newLabel != label else {
                // Label wouldn't actually change — skip the rewrite.
                result.append(raw)
                continue
            }

            // Rewrite: replace the first occurrence of `] <label>:` in the line.
            // Using the full label ensures "Speaker 1" can't accidentally match
            // "Speaker 10" — both the leading `]` and trailing `:` are included.
            let rewritten = replaceLabel(in: raw, from: label, to: newLabel)
            result.append(rewritten)
            changed += 1
        }

        return (result.joined(separator: "\n"), changed)
    }

    // MARK: Parsing helpers

    /// Parse the `HH:MM:SS` timestamp from the start of a trimmed transcript line.
    /// Handles both `**[HH:MM:SS] Label:** text` and `[HH:MM:SS] Label: text`.
    private static func parseTimestamp(_ trimmed: String) -> TimeInterval? {
        // Strip optional leading `**`
        var s = trimmed
        if s.hasPrefix("**") { s = String(s.dropFirst(2)) }
        guard s.hasPrefix("["),
              let closeIdx = s.firstIndex(of: "]") else { return nil }
        let stamp = s[s.index(after: s.startIndex)..<closeIdx]
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
    }

    /// Extract the speaker label from a trimmed transcript line.
    /// Returns nil if the line doesn't match the expected pattern.
    ///
    /// The label is the text between the timestamp's `]` and the first `:` after it.
    /// Matches both bold and unbolded variants, and handles the `**` suffix after `]`
    /// in the bold form (`**[HH:MM:SS] Label:**`).
    private static func extractLabel(from trimmed: String) -> String? {
        // Strip leading `**` if present.
        var s = trimmed
        if s.hasPrefix("**") { s = String(s.dropFirst(2)) }
        guard let closeIdx = s.firstIndex(of: "]") else { return nil }
        // Text after `] ` (with optional `**` before the label in the bold variant).
        var rest = String(s[s.index(after: closeIdx)...])
        // Strip a leading space.
        if rest.hasPrefix(" ") { rest = String(rest.dropFirst()) }
        // Strip `**` prefix of the label portion in the bold variant (`**[…] **Label:**`
        // doesn't exist, but `**[…] Label:**` does — the `**` wraps the whole thing, not
        // just the label). In the actual format the `**` has already been stripped above.
        // Find the colon that terminates the label.
        guard let colonIdx = rest.firstIndex(of: ":") else { return nil }
        let label = String(rest[rest.startIndex..<colonIdx])
        return label.isEmpty ? nil : label
    }

    /// True when the label is one of the generic forms that should be relabeled:
    /// exactly `"Me"`, exactly `"Remote"`, or `"Speaker <digits>"`.
    ///
    /// The digit-only check (no partial match) is critical: "Speaker 1" must not match
    /// "Speaker 10". The colon is NOT part of the label string here — it was the delimiter
    /// used to extract it. The `SpeakerCache.relabel` substitution uses `"] Speaker \(id):"`,
    /// so new labels written here as `"Speaker <id>"` are fully compatible.
    private static func isGenericLabel(_ label: String) -> Bool {
        if label == "Me" || label == "Remote" { return true }
        // "Speaker <digits>" — no other text allowed.
        let prefix = "Speaker "
        guard label.hasPrefix(prefix) else { return false }
        let suffix = label.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// Find the start timestamp of the next timestamped line after index `i`.
    private static func nextTimestamp(after i: Int, in starts: [TimeInterval?]) -> TimeInterval? {
        for j in (i + 1)..<starts.count {
            if let t = starts[j] { return t }
        }
        return nil
    }

    /// Rewrite the label in `raw` from `oldLabel` to `newLabel`, preserving the bold
    /// markers and timestamp. Replaces the first occurrence of `] <oldLabel>:` (handles
    /// both `**[…] OldLabel:** text` and `[…] OldLabel: text`).
    private static func replaceLabel(in raw: String, from oldLabel: String, to newLabel: String) -> String {
        // The sentinel is `] <label>:` — present in both variants and unambiguous.
        let needle = "] \(oldLabel):"
        let replacement = "] \(newLabel):"
        // Only replace the first occurrence (the label itself); any label text that
        // coincidentally appears later in the spoken content is untouched.
        if let range = raw.range(of: needle) {
            return raw.replacingCharacters(in: range, with: replacement)
        }
        return raw
    }
}
