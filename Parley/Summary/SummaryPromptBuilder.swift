import Foundation

/// Builds the single shared prompt fed to every comparison engine, so Claude / Apple /
/// Qwen are evaluated on identical input. Injects the transcript (frontmatter stripped),
/// the Rolodex contacts, the supplied attendees, and the intended filing location into
/// `settings.summaryPromptTemplate`. The same builder is used for every engine — the only
/// variable in the comparison is the model, not the prompt.
enum SummaryPromptBuilder {

    /// Result of building a prompt, plus whether the transcript could be read.
    struct Built {
        let prompt: String
        let transcriptChars: Int
    }

    static func build(template: String,
                      transcriptURL: URL,
                      attendees: String,
                      destination: String,
                      contactsURL: URL?) -> Built {
        let transcript = readTranscript(transcriptURL)
        let contacts = readContacts(contactsURL)
        let prompt = template
            .replacingOccurrences(of: "{{contacts}}", with: contacts.isEmpty ? "(no contacts file found)" : contacts)
            .replacingOccurrences(of: "{{attendees}}", with: attendees.isEmpty ? "(none provided)" : attendees)
            .replacingOccurrences(of: "{{destination}}", with: destination.isEmpty ? "(unspecified)" : destination)
            .replacingOccurrences(of: "{{transcript}}", with: transcript)
        return Built(prompt: prompt, transcriptChars: transcript.count)
    }

    /// Reads the transcript and drops its YAML frontmatter block (the metadata isn't useful
    /// to the summarizer and just wastes context). Mirrors `TranscriptPreviewView`'s strip.
    static func readTranscript(_ url: URL) -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return strippingFrontmatter(raw)
    }

    /// The Rolodex contents, used for name resolution. Returns "" if absent.
    static func readContacts(_ url: URL?) -> String {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func strippingFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return text }
        let lines = text.components(separatedBy: "\n")
        if let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            return lines[(closing + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
