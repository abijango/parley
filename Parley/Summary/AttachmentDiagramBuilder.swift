import Foundation

/// Stage C — turns vision output into a filed-ready `## Diagrams` section with image embeds.
enum AttachmentDiagramBuilder {

    /// Whether the vision digest has diagram content worth merging into a summary.
    static func isActionable(_ digest: String) -> Bool {
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let body = bodyWithoutDiagramsHeading(trimmed)
        guard !body.isEmpty else { return false }
        let lower = body.lowercased()
        if lower == "none recorded" || lower == "none recorded." { return false }
        return body.contains("###") || body.contains("```mermaid")
    }

    /// Appends Obsidian image embeds under each matched `###` subsection.
    static func enrich(visionDigest: String,
                       attachments: [MeetingAttachment],
                       documentURL: URL,
                       vault: URL) -> String {
        var lines = normalizedDiagramsLines(visionDigest)
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### "),
               let att = matchingAttachment(forHeading: trimmed, attachments: attachments) {
                let rel = att.markdownRelativePath(from: documentURL, vault: vault)
                let alt = att.displayLabel.replacingOccurrences(of: "\"", with: "'")
                let embed = "![\(alt)](\(rel))"

                var end = i + 1
                while end < lines.count {
                    let t = lines[end].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("### ") || t.hasPrefix("## ") { break }
                    end += 1
                }

                let section = lines[(i + 1)..<end].joined(separator: "\n")
                if !embedAlreadyPresent(section, attachment: att, relativePath: rel) {
                    if end > i + 1, !lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                        lines.insert("", at: end)
                        end += 1
                    }
                    lines.insert(embed, at: end)
                }
                i = end + 1
                continue
            }
            i += 1
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Private

    private static func normalizedDiagramsLines(_ digest: String) -> [String] {
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("## diagrams") {
            return trimmed.components(separatedBy: "\n")
        }
        return ("## Diagrams\n\n" + trimmed).components(separatedBy: "\n")
    }

    private static func bodyWithoutDiagramsHeading(_ digest: String) -> String {
        var lines = digest.components(separatedBy: "\n")
        if let first = lines.first?.trimmingCharacters(in: .whitespaces).lowercased(),
           first == "## diagrams" {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchingAttachment(forHeading heading: String,
                                           attachments: [MeetingAttachment]) -> MeetingAttachment? {
        let h = heading.lowercased()
        return attachments.first { h.contains($0.filename.lowercased()) }
    }

    private static func embedAlreadyPresent(_ section: String,
                                            attachment: MeetingAttachment,
                                            relativePath: String) -> Bool {
        if section.contains("](\(relativePath))") { return true }
        if section.contains("](\(attachment.vaultRelativePath))") { return true }
        return section.contains("![") && section.lowercased().contains(attachment.filename.lowercased())
    }
}
