import XCTest
@testable import Parley

/// The Intellias / SpaceX UKI call (`Fixtures/intellias-spacex-uki-*.md`). The original
/// note matched the bare attendee "Jason" to an unrelated Monument Hobbies contact,
/// spelt Intellias "Intellius", and never resolved Lucy or Kadir/"Khadir". The v2 note
/// is the reference for what the resolved context should let the summarizer produce.
final class MeetingContextPromptTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    /// The raw transcript section of the original note.
    private func transcript() throws -> String {
        let note = try fixture("intellias-spacex-uki-original.md")
        let marker = try XCTUnwrap(note.range(of: "## Raw Transcript"))
        return String(note[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func person(_ name: String, title: String? = nil, company: String?,
                        aliases: [String] = []) -> PersonRecord {
        let id = UUID().uuidString
        let roles = company.map {
            [PersonRole(id: UUID().uuidString, personId: id, company: $0, title: title, team: nil,
                        side: .other, startedAt: nil, endedAt: nil, sortIndex: 0)]
        } ?? []
        return PersonRecord(id: id, name: name, linkedin: nil, notes: "", aliases: aliases,
                            createdAt: Date(), updatedAt: Date(), roles: roles, origin: nil)
    }

    private var peopleDB: [PersonRecord] {
        [
            person("Naufal Mir", title: "Director of AI, FS&I", company: "Intellias", aliases: ["Naufal"]),
            person("Andre Nedelcoux", title: "VP Delivery, FSI", company: "Intellias"),
            person("Lucy Willoughby", title: "VP", company: "Intellias"),
            person("Jason Creane", company: "SpaceX AI"),
            person("Kadir Erol", company: "SpaceX AI", aliases: ["Khadir", "Kir Kadir"]),
            person("Jason", company: "Monument Hobbies"),
            person("Priya Raman", title: "CTO", company: "Unrelated Co"),
        ]
    }

    private let attendees = ["Naufal Mir", "Jason", "Andre Nedelcoux", "Jason Creane"]

    private var extras: SummaryPromptBuilder.Extras {
        SummaryPromptBuilder.Extras(
            me: "Naufal Mir", myCompany: "Intellias",
            invitees: [MeetingInvitee(name: "Kadir Erol", response: .declined),
                       MeetingInvitee(name: "Lucy Willoughby", response: nil)])
    }

    // MARK: Contact scoping

    func testBareFirstNameNeverPullsInAnUnrelatedContact() throws {
        let scoped = SummaryPromptBuilder.scopedContacts(
            records: peopleDB, attendees: attendees, transcript: try transcript(), extras: extras)
        XCTAssertFalse(scoped.text.contains("Monument Hobbies"))
        XCTAssertFalse(scoped.text.contains("Unrelated Co"))
        XCTAssertTrue(scoped.text.contains("Jason Creane | | SpaceX AI |"))
        XCTAssertTrue(scoped.text.contains("Kadir Erol | | SpaceX AI | Khadir, Kir Kadir"))
        XCTAssertTrue(scoped.text.contains("Lucy Willoughby | VP | Intellias |"))
        let annotated = SummaryPromptBuilder.annotate(
            attendees: attendees.joined(separator: ", "), contacts: scoped.contacts)
        XCTAssertFalse(annotated.contains("Monument"))
        XCTAssertTrue(annotated.contains("Jason Creane (SpaceX AI)"))
    }

    func testOneContactPerLineInTheDocumentedFormat() {
        XCTAssertEqual(
            PeoplePromptRenderer.line(for: person("Kadir Erol", title: "Partner Manager",
                                                  company: "SpaceX AI", aliases: ["Khadir"])),
            "Kadir Erol | Partner Manager | SpaceX AI | Khadir")
    }

    /// Room mode / ad hoc: no invitees, no attendees, no owner configured. Only people
    /// whose full name or alias is spoken are sent — never a bare first-name match.
    func testNoInviteesFallsBackToTranscriptMentions() throws {
        let scoped = SummaryPromptBuilder.scopedContacts(
            records: peopleDB, attendees: [], transcript: try transcript(), extras: .init())
        XCTAssertTrue(scoped.text.contains("Kadir Erol"), "alias Khadir is spoken")
        XCTAssertTrue(scoped.text.contains("Jason Creane"), "full name is spoken")
        XCTAssertFalse(scoped.text.contains("Monument Hobbies"))
        XCTAssertFalse(scoped.text.contains("Lucy Willoughby"), "only her first name is spoken")
    }

    func testEmptyMeetingKeepsThePlaceholder() {
        let scoped = SummaryPromptBuilder.scopedContacts(
            records: peopleDB, attendees: [], transcript: "", extras: .init())
        XCTAssertEqual(scoped.text, "(no matching people for this meeting)")
    }

    // MARK: Prompt variables

    private func writeTranscript(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-context-\(UUID().uuidString).md")
        try "---\ntitle: Intellias - SpaceX UKI Partnership\n---\n\(body)".write(
            to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private let glossary = """
    - LSEG (also heard as: Elseg, L Seg, LSEC)
    - Intellias (also heard as: Intellius)
    """

    @MainActor func testDefaultTemplateFillsEveryVariable() throws {
        let built = SummaryPromptBuilder.build(
            template: AppSettings.defaultSummaryPrompt,
            transcriptURL: try writeTranscript(try transcript()),
            attendees: attendees.joined(separator: ", "),
            destination: "Work/Partners/Cursor/Partnership",
            contactsURL: nil,
            peopleRecords: peopleDB,
            terminologyBlock: glossary,
            attachmentUnderstanding: .off,
            extras: extras)
        let prompt = built.prompt
        XCTAssertFalse(prompt.contains("{{"), "no unrendered tokens")
        XCTAssertTrue(prompt.contains("Recording owner: Naufal Mir."))
        XCTAssertTrue(prompt.contains("always spell it exactly like this): Intellias"))
        XCTAssertTrue(prompt.contains("Kadir Erol | declined"))
        XCTAssertTrue(prompt.contains("Lucy Willoughby | no response"))
        XCTAssertEqual(prompt.components(separatedBy: "LSEG (also heard as").count - 1, 1,
                       "glossary rendered once via {{glossary}}, not injected again")
        XCTAssertFalse(prompt.contains("Monument Hobbies"))
        XCTAssertTrue(prompt.contains("STEP 1 — RESOLVE"))
        for section in ["## Attendees", "## Executive Summary", "## Key Topics Discussed",
                        "## Decisions Made", "## Action Items", "## Questions & Open Issues",
                        "## Key Metrics or Data Points", "## Next Steps", "## Attachments", "## Diagrams"] {
            XCTAssertTrue(prompt.contains(section), section)
        }
        XCTAssertTrue(prompt.contains("Do NOT include a Raw Transcript section"))
        XCTAssertTrue(prompt.contains("(invited, not present)"))
    }

    /// A template customised before the new tokens existed still works and still gets
    /// the glossary, exactly as before.
    func testLegacyCustomTemplateKeepsWorking() throws {
        let built = SummaryPromptBuilder.build(
            template: "My prompt.\n{{contacts}}\nAttendees: {{attendees}}\n\nTRANSCRIPT:\n{{transcript}}",
            transcriptURL: try writeTranscript("**[00:00:01] Me:** hi"),
            attendees: "", destination: "", contactsURL: nil,
            peopleRecords: [], terminologyBlock: glossary)
        XCTAssertTrue(built.prompt.hasPrefix("My prompt."))
        XCTAssertTrue(built.prompt.contains("Terminology glossary"))
        XCTAssertTrue(built.prompt.contains("LSEG (also heard as"))
    }

    func testMissingValuesRenderPlaceholders() throws {
        let built = SummaryPromptBuilder.build(
            template: "{{me}}|{{my_company}}|{{invitees}}|{{glossary}}",
            transcriptURL: try writeTranscript("hello"),
            attendees: "", destination: "", contactsURL: nil, peopleRecords: [])
        XCTAssertTrue(built.prompt.hasPrefix("(not set)|(not set)|(no invite list available)|(none)"))
    }

    @MainActor func testAgentCommandDefaultDocumentsTheNewTokens() {
        for token in ["{{file}}", "{{destination}}", "{{attendees}}", "{{invitees}}", "{{me}}", "{{my_company}}"] {
            XCTAssertTrue(AppSettings.defaultClaudePrompt.contains(token), token)
        }
    }

    /// The reference note keeps the attendee shape the new prompt asks for.
    func testReferenceNoteHasNoDuplicateFirstNameAttendee() throws {
        let v2 = try fixture("intellias-spacex-uki-v2.md")
        XCTAssertTrue(v2.contains("| Kadir Erol (invited, not present) |"))
        XCTAssertFalse(v2.contains("Monument Hobbies"))
        XCTAssertFalse(v2.contains("Intellius"))
    }
}
