import Foundation

/// Builds the single shared prompt fed to every comparison engine, so Claude / Grok /
/// Cursor are evaluated on identical input. Injects the transcript (frontmatter stripped),
/// the Rolodex contacts, the supplied attendees, and the intended filing location into
/// `settings.summaryPromptTemplate`. The same builder is used for every engine — the only
/// variable in the comparison is the model, not the prompt.
enum SummaryPromptBuilder {

    /// Result of building a prompt, plus whether the transcript could be read.
    struct Built {
        let prompt: String
        let transcriptChars: Int
    }

    /// Owner identity and invite list for `{{me}}`, `{{my_company}}`, `{{invitees}}`.
    /// Every field may be empty; the tokens then render a placeholder, never `{{…}}`.
    struct Extras: Sendable {
        var me: String = ""
        var myCompany: String = ""
        var invitees: [MeetingInvitee] = []
    }

    static func build(template: String,
                      transcriptURL: URL,
                      attendees: String,
                      destination: String,
                      contactsURL: URL?,
                      contactsFromDB: [Contact]? = nil,
                      peopleRecords: [PersonRecord]? = nil,
                      terminologyBlock: String? = nil,
                      visionDigest: String? = nil,
                      attachmentUnderstanding: AttachmentUnderstanding = .captionsOnly,
                      speakerHints: String? = nil,
                      extras: Extras = Extras()) -> Built {
        let transcript = readTranscript(transcriptURL)
        let dbContacts = contactsFromDB ?? peopleRecords?.map { $0.asContact() }
        let attendeeNames = attendees
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let contacts: String
        let annotationContacts: [Contact]
        if let peopleRecords {
            let scoped = scopedContacts(records: peopleRecords, attendees: attendeeNames,
                                        transcript: transcript, extras: extras)
            contacts = scoped.text
            annotationContacts = scoped.contacts
        } else {
            contacts = readContacts(contactsURL, dbContacts: dbContacts)
            annotationContacts = dbContacts ?? parseContactsList(contacts)
        }
        let annotatedAttendees = attendees.isEmpty
            ? "(none provided)"
            : annotate(attendees: attendees, contacts: annotationContacts)
        let glossary = terminologyBlock?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let templateHasGlossary = template.contains("{{glossary}}")
        var prompt = template
            .replacingOccurrences(of: "{{contacts}}", with: contacts.isEmpty ? "(no contacts file found)" : contacts)
            .replacingOccurrences(of: "{{attendees}}", with: annotatedAttendees)
            .replacingOccurrences(of: "{{invitees}}", with: renderInvitees(extras.invitees))
            .replacingOccurrences(of: "{{me}}", with: orPlaceholder(extras.me))
            .replacingOccurrences(of: "{{my_company}}", with: orPlaceholder(extras.myCompany))
            .replacingOccurrences(of: "{{glossary}}", with: glossary.isEmpty ? "(none)" : glossary)
            .replacingOccurrences(of: "{{destination}}", with: destination.isEmpty ? "(unspecified)" : destination)
            .replacingOccurrences(of: "{{transcript}}", with: transcript)
        // Custom templates written before `{{glossary}}` existed still get the glossary.
        if !templateHasGlossary, !glossary.isEmpty {
            prompt = injectTerminology(glossary, into: prompt)
        }
        let attachments = TranscriptWriter.parseFrontmatter(transcriptURL)?.attachments ?? []
        if attachmentUnderstanding != .off, !attachments.isEmpty {
            let attachmentBlock = MeetingAttachmentStore.promptBlock(attachments: attachments)
            if !attachmentBlock.isEmpty {
                prompt = injectAttachments(attachmentBlock, into: prompt)
            }
        }
        if let visionDigest, !visionDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt = injectVisionDigest(visionDigest, into: prompt)
        }
        if let speakerHints, !speakerHints.isEmpty {
            prompt = injectSpeakerHints(speakerHints, into: prompt)
        }
        if let roster = attendeeAuthorityBlock(attendees: attendeeNames, transcript: transcript) {
            prompt = insertBeforeTranscript(roster, into: prompt)
        }
        return Built(prompt: prompt, transcriptChars: transcript.count)
    }

    /// The meeting-relevant slice of the People DB as `{{contacts}}` text, plus the same
    /// people as `Contact`s for attendee annotation.
    static func scopedContacts(records: [PersonRecord], attendees: [String], transcript: String,
                               extras: Extras) -> (text: String, contacts: [Contact]) {
        let selected = PeoplePromptRenderer.select(
            records: records,
            context: MeetingContactContext(
                attendees: attendees,
                invitees: extras.invitees.map(\.name),
                transcript: transcript,
                ownerName: extras.me,
                ownerCompany: extras.myCompany))
        let text = selected.isEmpty
            ? "(no matching people for this meeting)"
            : selected.map(PeoplePromptRenderer.line(for:)).joined(separator: "\n")
        return (text, selected.map { $0.asContact() })
    }

    /// `Name | RSVP` per invitee, for `{{invitees}}`.
    static func renderInvitees(_ invitees: [MeetingInvitee]) -> String {
        let lines = invitees
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.name) | \($0.rsvpLabel)" }
        return lines.isEmpty ? "(no invite list available)" : lines.joined(separator: "\n")
    }

    private static func orPlaceholder(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? "(not set)" : v
    }

    /// Repair an existing note after speaker renames — keeps structure and user edits.
    static func buildRepair(template: String,
                            previousNote: String,
                            renames: [String: String],
                            transcriptURL: URL,
                            attendees: String,
                            destination: String,
                            contactsURL: URL?,
                            contactsFromDB: [Contact]? = nil,
                            peopleRecords: [PersonRecord]? = nil,
                            terminologyBlock: String? = nil,
                            visionDigest: String? = nil,
                            attachmentUnderstanding: AttachmentUnderstanding = .captionsOnly,
                            speakerHints: String? = nil,
                            extras: Extras = Extras()) -> Built {
        let renameLines = renames.map { old, new in "- \(old) → \(new)" }.sorted().joined(separator: "\n")
        let body = template
            .replacingOccurrences(of: "{{previous_note}}", with: previousNote)
            .replacingOccurrences(of: "{{rename_map}}", with: renameLines.isEmpty ? "(none)" : renameLines)
        let built = build(
            template: body,
            transcriptURL: transcriptURL,
            attendees: attendees,
            destination: destination,
            contactsURL: contactsURL,
            contactsFromDB: contactsFromDB,
            peopleRecords: peopleRecords,
            terminologyBlock: terminologyBlock,
            visionDigest: visionDigest,
            attachmentUnderstanding: attachmentUnderstanding,
            speakerHints: speakerHints,
            extras: extras)
        return built
    }

    static func injectSpeakerHints(_ block: String, into prompt: String) -> String {
        insertBeforeTranscript(block.trimmingCharacters(in: .whitespacesAndNewlines), into: prompt)
    }

    /// Makes the user-edited attendee list the source of truth for the note's Attendees.
    /// The body keeps the speaker labels the voiceprint pass wrote, so a chip the user
    /// removed (a misidentified speaker) still names whole stretches of the transcript —
    /// and the template's "list who spoke" rule would put it straight back. Labels that
    /// aren't on the list are called out as misidentifications. Nil when no attendees.
    static func attendeeAuthorityBlock(attendees: [String], transcript: String) -> String? {
        guard !attendees.isEmpty else { return nil }
        let listed = Set(attendees.map { $0.lowercased() })
        let unlisted = speakerLabels(in: transcript).filter { !listed.contains($0.lowercased()) }
        var lines = [
            "ATTENDEE LIST (authoritative — confirmed by the user, overrides the transcript's speaker labels):",
            "The Attendees section must list exactly these people: \(attendees.joined(separator: ", ")).",
            "If the list holds both a bare first name and a full name for the same person, they are one attendee under the full name.",
            "Do not add anyone else, except invitees who never speak as \"(invited, not present)\" rows. Keep a row for each listed person even if they barely speak; mark one \"(invited, not present)\" only when the transcript clearly shows they were absent.",
        ]
        if !unlisted.isEmpty {
            lines.append("These transcript speaker labels are misidentifications the user removed: \(unlisted.joined(separator: ", ")). They are NOT attendees — never list them or attribute statements to them by name. Treat those lines as an unidentified speaker (or a listed attendee when the context makes it clear).")
        }
        return lines.joined(separator: "\n")
    }

    /// Distinct named speaker labels (`**[HH:MM:SS] Name:**`) in first-seen order, skipping
    /// the generic `Me` / `Remote` / `Speaker N` labels.
    static func speakerLabels(in transcript: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("**["), let close = line.range(of: "] "),
                  let colon = line[close.upperBound...].firstIndex(of: ":") else { continue }
            let name = line[close.upperBound..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 60, name != "Me", name != "Remote",
                  !name.hasPrefix("Speaker "), !name.contains("*") else { continue }
            if seen.insert(name.lowercased()).inserted { out.append(name) }
        }
        return out
    }

    /// Inserts `section` just before the last TRANSCRIPT section, or appends it.
    private static func insertBeforeTranscript(_ section: String, into prompt: String) -> String {
        guard let range = prompt.range(of: "\nTRANSCRIPT:", options: .backwards) else {
            return prompt + "\n\n" + section
        }
        var out = prompt
        out.insert(contentsOf: "\n\n" + section, at: range.lowerBound)
        return out
    }

    /// Injects model-analyzed attachment descriptions before TRANSCRIPT.
    static func injectVisionDigest(_ block: String, into prompt: String) -> String {
        let section = """
        ATTACHMENT VISION (model-analyzed from images — authoritative for visual content):
        \(block.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        return insertBeforeTranscript(section, into: prompt)
    }

    /// Injects attachment captions/paths before the TRANSCRIPT section (or at end).
    static func injectAttachments(_ block: String, into prompt: String) -> String {
        insertBeforeTranscript(block, into: prompt)
    }

    /// Injects a terminology glossary block before the TRANSCRIPT section (or at end).
    static func injectTerminology(_ block: String, into prompt: String) -> String {
        let section = """
        Terminology glossary (use these spellings/forms consistently):
        \(block)
        """
        return insertBeforeTranscript(section, into: prompt)
    }

    /// Terminology block for prompt injection from the knowledge DB.
    static func terminologyBlock(from store: TerminologyStore = TerminologyStore(),
                                 filingScope: String? = nil) -> String {
        store.promptBlock(forScope: filingScope)
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
        annotate(attendees: attendees, contacts: VaultDirectory.parseContacts(contactsText))
    }

    static func annotate(attendees: String, contacts: [Contact]) -> String {
        // Build name -> (company, side) index from the parsed rolodex.
        // Uses Set<String> for company to detect collisions; side is stored per-entry.
        struct Entry { var companies: Set<String>; var side: Side }
        var index: [String: Entry] = [:]

        for contact in contacts {
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
    static func readContacts(_ url: URL?, dbContacts: [Contact]? = nil) -> String {
        if let dbContacts, !dbContacts.isEmpty {
            return renderContactsForPrompt(dbContacts)
        }
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseContactsList(_ contactsText: String) -> [Contact] {
        VaultDirectory.parseContacts(contactsText)
    }

    /// Compact rolodex text from DB contacts for prompt injection.
    static func renderContactsForPrompt(_ contacts: [Contact]) -> String {
        VaultDirectory.renderCanonical(contacts)
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
