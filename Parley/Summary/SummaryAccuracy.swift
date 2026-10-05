import Foundation

/// Lexical fact recall of a candidate summary against an approved note.
///
/// Claims are the approved note's bullets, numbered items, table rows, and
/// prose sentences — not the raw transcript appended under `## Raw Transcript`.
/// A claim counts as recalled when at least 60% of its significant tokens
/// (numbers, and content words of 4+ letters) appear in the candidate. This
/// measures whether approved facts survived, not whether the prose is better.
enum SummaryAccuracy {
    struct Score: Equatable {
        var matched: Int
        var total: Int
        var missedPreviews: [String]

        var recall: Double {
            guard total > 0 else { return 0 }
            return Double(matched) / Double(total)
        }
    }

    /// Fraction of a claim's significant tokens that must appear in the candidate.
    static let matchFraction = 0.6

    static func score(candidate: String, gold: String) -> Score {
        let claims = claims(from: summaryBody(gold))
        let haystack = tokenSet(summaryBody(candidate))
        var matched = 0
        var total = 0
        var missed: [String] = []
        for claim in claims {
            let keys = significantTokens(claim)
            guard keys.count >= 3 else { continue }
            total += 1
            let hits = keys.filter { haystack.contains($0) }.count
            if Double(hits) / Double(keys.count) >= matchFraction {
                matched += 1
            } else if missed.count < 8 {
                missed.append(preview(claim))
            }
        }
        return Score(matched: matched, total: total, missedPreviews: missed)
    }

    /// Note body used for scoring: frontmatter removed, raw transcript dropped.
    static func summaryBody(_ markdown: String) -> String {
        var body = markdown
        if body.hasPrefix("---") {
            let lines = body.components(separatedBy: "\n")
            if lines.count > 1 {
                if let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                    body = lines[(close + 1)...].joined(separator: "\n")
                }
            }
        }
        if let range = body.range(of: #"(?m)^## Raw Transcript\b"#, options: .regularExpression) {
            body = String(body[..<range.lowerBound])
        }
        return body
    }

    // MARK: Claims

    private static func claims(from body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") {
                let next = i + 1 < lines.count
                    ? lines[i + 1].trimmingCharacters(in: .whitespaces) : ""
                if isSeparator(next) {
                    i += 2
                    continue
                }
                if isSeparator(trimmed) {
                    i += 1
                    continue
                }
                let cells = tableCells(trimmed).filter { !$0.isEmpty }
                if !cells.isEmpty { out.append(cells.joined(separator: " — ")) }
                i += 1
                continue
            }
            if let item = listItem(trimmed) {
                out.append(item)
                i += 1
                continue
            }
            if !trimmed.hasPrefix("#"), trimmed.count > 40, !trimmed.hasPrefix("**") {
                out.append(contentsOf: sentences(trimmed))
            }
            i += 1
        }
        return out
    }

    private static func listItem(_ line: String) -> String? {
        if let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            let rest = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            let rest = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    private static func tableCells(_ line: String) -> [String] {
        line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func isSeparator(_ line: String) -> Bool {
        guard line.contains("|"), line.contains("-") else { return false }
        let stripped = line.unicodeScalars.filter {
            $0 != "|" && $0 != "-" && $0 != ":" && $0 != " "
        }
        return stripped.isEmpty
    }

    private static func sentences(_ line: String) -> [String] {
        line.components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 40 }
    }

    // MARK: Tokens

    private static let stopwords: Set<String> = [
        "about", "after", "again", "also", "and", "because", "been", "before", "being",
        "between", "both", "but", "could", "does", "doing", "during", "each", "from",
        "have", "having", "into", "just", "more", "most", "only", "other", "over",
        "same", "should", "some", "such", "than", "that", "their", "them", "then",
        "there", "these", "they", "this", "those", "through", "under", "very", "were",
        "what", "when", "where", "which", "while", "with", "would", "your"
    ]

    private static func significantTokens(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for token in tokenize(text) {
            let keep = token.contains(where: \.isNumber) || (token.count >= 4 && !stopwords.contains(token))
            guard keep, seen.insert(token).inserted else { continue }
            out.append(token)
        }
        return out
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        Set(tokenize(text))
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func preview(_ claim: String) -> String {
        let flat = claim.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if flat.count <= 110 { return flat }
        return String(flat.prefix(107)) + "…"
    }
}
