import Foundation

/// Parses checker JSON (`{ "edits": [ … ] }`) tolerant of markdown fences.
enum SummaryEditJSONParser {

    struct EditDTO: Decodable {
        var op: String?
        var target: String?
        var after: String?
        var after_anchor: String?
        var text: String?
        var reason: String?
    }

    struct RootDTO: Decodable {
        var edits: [EditDTO]?
    }

    struct ParseResult: Equatable, Sendable {
        var hunks: [SummaryHunk]
        var parseOK: Bool
    }

    static func parse(raw: String, runID: String) -> ParseResult {
        let trimmed = stripFences(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = trimmed.data(using: .utf8) else {
            return ParseResult(hunks: [], parseOK: false)
        }
        let dec = JSONDecoder()
        guard let root = try? dec.decode(RootDTO.self, from: data),
              let edits = root.edits else {
            return ParseResult(hunks: [], parseOK: false)
        }
        // Empty `edits` is a valid checker response ("draft already faithful").
        if edits.isEmpty {
            return ParseResult(hunks: [], parseOK: true)
        }
        var hunks: [SummaryHunk] = []
        for (i, edit) in edits.enumerated() {
            guard let op = mapOp(edit.op) else { continue }
            let hunk = SummaryHunk.pending(
                runID: runID,
                sortIndex: i,
                op: op,
                target: edit.target ?? "",
                afterAnchor: edit.after_anchor ?? edit.after ?? "",
                text: edit.text ?? "",
                reason: edit.reason ?? ""
            )
            hunks.append(hunk)
        }
        // Parsed JSON but every op was unknown → not OK.
        return ParseResult(hunks: hunks, parseOK: !hunks.isEmpty)
    }

    static func stripFences(_ text: String) -> String {
        var s = text
        if s.hasPrefix("```") {
            if let firstNL = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNL)...])
            }
            if let close = s.range(of: "\n```", options: .backwards) ?? s.range(of: "```", options: .backwards) {
                s = String(s[s.startIndex..<close.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mapOp(_ raw: String?) -> SummaryEditOperation? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "insert", "add", "insertion": return .insert
        case "replace", "substitute", "change": return .replace
        case "delete", "remove", "deletion": return .delete
        default: return nil
        }
    }
}
