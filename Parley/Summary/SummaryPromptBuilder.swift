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
        let annotatedAttendees = attendees.isEmpty
            ? "(none provided)"
            : annotate(attendees: attendees, contactsText: contacts)
        let prompt = template
            .replacingOccurrences(of: "{{contacts}}", with: contacts.isEmpty ? "(no contacts file found)" : contacts)
            .replacingOccurrences(of: "{{attendees}}", with: annotatedAttendees)
            .replacingOccurrences(of: "{{destination}}", with: destination.isEmpty ? "(unspecified)" : destination)
            .replacingOccurrences(of: "{{transcript}}", with: transcript)
        return Built(prompt: prompt, transcriptChars: transcript.count)
    }

    /// Annotate each attendee name with its company and side from the contacts file.
    ///
    /// Format:
    ///   - Internal contact:  "Alice Smith (Intellias)"      -- no extra label
    ///   - Customer contact:  "Anna Krylova (IG Group, customer)"  -- ", customer" appended
    ///   - Other / unknown:   "Dave Brown"                   -- bare, no annotation
    ///
    /// Company comes from the rolodex parse, NOT fuzzy matching, so the summarizer is
    /// told the affiliation rather than guessing it.
    ///
    /// Collision rule (mirrors VaultDirectory.companyIndex): if a name appears under two
    /// or more DIFFERENT company sections, it is left bare (ambiguous = treat as unknown).
    /// Both canonical names AND aliases are registered so Teams/Zoom display names resolve.
    static func annotate(attendees: String, contactsText: String) -> String {
        // Build name -> (company, side) index from the parsed rolodex.
        // Uses Set<String> for company to detect collisions; side is stored per-entry.
        struct Entry { var companies: Set<String>; var side: Side }
        var index: [String: Entry] = [:]

        for contact in VaultDirectory.parseContacts(contactsText) {
            guard let company = contact.company, !company.isEmpty else { continue }
            let keys = [contact.name.lowercased()] + contact.aliases.map { $0.lowercased() }
            for key in keys {
                if index[key] == nil {
                    index[key] = Entry(companies: [company], side: contact.side)
                } else {
                    index[key]!.companies.insert(company)
                    // If companies still agree, side is stable; on collision we discard anyway.
                }
            }
        }

        let tokens = attendees
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let annotated = tokens.map { token -> String in
            let key = token.lowercased()
            guard let entry = index[key],
                  entry.companies.count == 1,
                  let company = entry.companies.first else {
                return token  // bare: unknown, Other, or ambiguous
            }
            if entry.side == .customer {
                return "\(token) (\(company), customer)"
            } else {
                return "\(token) (\(company))"
            }
        }

        return annotated.joined(separator: ", ")
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
