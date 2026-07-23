import Foundation

/// Applies accepted checker hunks to a writer draft and builds markup preview segments.
enum SummaryHunkEngine {

    /// Merge accepted hunks into clean markdown (pending/rejected ignored).
    static func mergedMarkdown(draft: String, hunks: [SummaryHunk]) -> String {
        var text = draft
        let accepted = hunks.filter { $0.status == .accepted }.sorted { $0.sortIndex < $1.sortIndex }
        for hunk in accepted {
            text = apply(hunk, to: text)
        }
        return text
    }

    /// Preview with decorations for pending + accepted hunks (rejected omitted from markup).
    static func previewSegments(draft: String, hunks: [SummaryHunk]) -> [SummaryMarkupSegment] {
        var segments: [SummaryMarkupSegment] = []
        var cursor = draft.startIndex
        let active = hunks
            .filter { $0.status != .rejected }
            .sorted { $0.sortIndex < $1.sortIndex }

        for hunk in active {
            switch hunk.op {
            case .replace:
                guard !hunk.target.isEmpty,
                      let range = draft.range(of: hunk.target, range: cursor..<draft.endIndex) else { continue }
                if cursor < range.lowerBound {
                    segments.append(.plain(String(draft[cursor..<range.lowerBound])))
                }
                segments.append(.replacement(old: hunk.target, new: hunk.effectiveText, hunkID: hunk.id, reason: hunk.reason))
                cursor = range.upperBound
            case .delete:
                guard !hunk.target.isEmpty,
                      let range = draft.range(of: hunk.target, range: cursor..<draft.endIndex) else { continue }
                if cursor < range.lowerBound {
                    segments.append(.plain(String(draft[cursor..<range.lowerBound])))
                }
                segments.append(.deletion(hunk.target, hunkID: hunk.id, reason: hunk.reason))
                cursor = range.upperBound
            case .insert:
                let anchor = hunk.afterAnchor.isEmpty ? hunk.target : hunk.afterAnchor
                guard !anchor.isEmpty,
                      let range = draft.range(of: anchor, range: cursor..<draft.endIndex) else { continue }
                if cursor < range.lowerBound {
                    segments.append(.plain(String(draft[cursor..<range.lowerBound])))
                }
                segments.append(.plain(String(draft[range])))
                segments.append(.insertion(hunk.effectiveText, hunkID: hunk.id, reason: hunk.reason))
                cursor = range.upperBound
            }
        }
        if cursor < draft.endIndex {
            segments.append(.plain(String(draft[cursor...])))
        }
        if segments.isEmpty {
            segments.append(.plain(draft))
        }
        return segments
    }

    private static func apply(_ hunk: SummaryHunk, to text: String) -> String {
        switch hunk.op {
        case .replace:
            guard !hunk.target.isEmpty, let range = text.range(of: hunk.target) else { return text }
            return String(text[text.startIndex..<range.lowerBound]) + hunk.effectiveText + String(text[range.upperBound...])
        case .delete:
            guard !hunk.target.isEmpty, let range = text.range(of: hunk.target) else { return text }
            return String(text[text.startIndex..<range.lowerBound]) + String(text[range.upperBound...])
        case .insert:
            let anchor = hunk.afterAnchor.isEmpty ? hunk.target : hunk.afterAnchor
            guard !anchor.isEmpty, let range = text.range(of: anchor) else { return text }
            return String(text[text.startIndex..<range.upperBound]) + hunk.effectiveText + String(text[range.upperBound...])
        }
    }
}
