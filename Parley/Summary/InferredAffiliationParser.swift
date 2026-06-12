import Foundation

/// An attendee whose company affiliation was inferred from transcript context by Claude,
/// tagged `(inferred)` in the Attendees table of the generated meeting note.
struct InferredAffiliation: Equatable {
    let name: String
    let company: String
}

/// Parses a generated meeting note's Attendees table for `(inferred)` company tags, and
/// strips those tags from the committed body.
enum InferredAffiliationParser {

    // MARK: - Public API

    /// Parse a generated meeting note for company cells tagged "(inferred)".
    ///
    /// Locates the `## Attendees` Markdown section, reads the table, and returns one
    /// `InferredAffiliation` per attendee whose Company column ends with the literal tag
    /// "(inferred)" (case-insensitive, whitespace-tolerant). The tag is stripped from the
    /// returned `company` value. Returns an empty array if no such rows are found.
    static func parseInferred(markdown: String) -> [InferredAffiliation] {
        guard let tableLines = attendeeTableLines(in: markdown) else { return [] }
        let (companyIndex, dataRows) = splitTable(tableLines)
        var results: [InferredAffiliation] = []
        for row in dataRows {
            guard companyIndex < row.count else { continue }
            let rawCompany = row[companyIndex]
            guard let company = strippingInferredTag(rawCompany) else { continue }
            guard !company.isEmpty else { continue }
            let rawName = row[0]
            let name = cleanMarkdownName(rawName)
            guard !name.isEmpty else { continue }
            results.append(InferredAffiliation(name: name, company: company))
        }
        return results
    }

    /// Remove the "(inferred)" tag from Company cells in a committed note body.
    ///
    /// Operates line-by-line on the Attendees table: any Company cell that contains
    /// " (inferred)" (any casing, with optional leading spaces before the tag) has the tag
    /// removed. Lines outside the Attendees section are left unchanged.
    static func stripInferredTags(markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        var inAttendeesSection = false
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("##") {
                let heading = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                inAttendeesSection = heading.lowercased() == "attendees"
                continue
            }
            guard inAttendeesSection else { continue }
            guard trimmed.hasPrefix("|") else { continue }
            // Replace " (inferred)" in any cell of this row (case-insensitive).
            lines[i] = removeInferredTagFromRow(lines[i])
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    /// Returns the lines that belong to the Attendees table, or nil if the section is absent.
    private static func attendeeTableLines(in markdown: String) -> [String]? {
        let lines = markdown.components(separatedBy: "\n")
        var inSection = false
        var tableLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("##") {
                let heading = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if heading.lowercased() == "attendees" {
                    inSection = true
                    continue
                } else if inSection {
                    break   // hit the next ## section
                }
            }
            if inSection && trimmed.hasPrefix("|") {
                tableLines.append(line)
            }
        }
        return tableLines.isEmpty ? nil : tableLines
    }

    /// Split table lines into (companyColumnIndex, [[cell]]) — skipping the header and
    /// separator rows. Returns the last-column index as a fallback if no header is found.
    private static func splitTable(_ lines: [String]) -> (Int, [[String]]) {
        var headerCells: [String]? = nil
        var dataRows: [[String]] = []
        for line in lines {
            let cells = splitTableRow(line)
            if cells.isEmpty { continue }
            // Separator row: contains only `-`, `:`, `|`, spaces.
            let isSeparator = cells.allSatisfy { $0.trimmingCharacters(in: CharacterSet(charactersIn: "- :")).isEmpty }
            if isSeparator { continue }
            // Header row: any cell matches "name" or "company" (case-insensitive).
            let lowered = cells.map { $0.lowercased() }
            if headerCells == nil && (lowered.contains("name") || lowered.contains("company")) {
                headerCells = cells
                continue
            }
            dataRows.append(cells)
        }
        let companyIndex: Int
        if let header = headerCells {
            let ci = header.firstIndex(where: { $0.lowercased() == "company" })
            companyIndex = ci ?? (header.count - 1)
        } else {
            companyIndex = 2   // Name | Role | Company assumed
        }
        return (companyIndex, dataRows)
    }

    /// Split a Markdown table row on `|`, trim each cell. Drops empty leading/trailing cells.
    private static func splitTableRow(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Drop leading/trailing empty cells produced by `| ... |` borders.
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    /// If `cell` ends with "(inferred)" (case-insensitive, tolerant of surrounding whitespace),
    /// returns the company text with the tag stripped; otherwise returns nil.
    private static func strippingInferredTag(_ cell: String) -> String? {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        // Accept optional leading space before "(inferred)".
        for suffix in ["(inferred)", " (inferred)"] {
            if lower.hasSuffix(suffix) {
                let stripped = String(trimmed.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespaces)
                return stripped
            }
        }
        return nil
    }

    /// Strip Markdown bold markers `**` and link syntax `[text](url)` from a name cell.
    private static func cleanMarkdownName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        // Strip **bold**
        s = s.replacingOccurrences(of: "**", with: "")
        // Strip [text](url) -> text
        if let openBracket = s.firstIndex(of: "["),
           let closeBracket = s[s.index(after: openBracket)...].firstIndex(of: "]") {
            let inner = String(s[s.index(after: openBracket)..<closeBracket])
            s = inner
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Remove " (inferred)" (any casing) from all cells of a single table row string.
    private static func removeInferredTagFromRow(_ line: String) -> String {
        // Use a case-insensitive regex replacement on the full row.
        // Pattern: optional space + "(inferred)" literal (case-insensitive).
        guard let regex = try? NSRegularExpression(pattern: #" ?\(inferred\)"#, options: .caseInsensitive) else {
            return line
        }
        let ns = line as NSString
        return regex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }
}
