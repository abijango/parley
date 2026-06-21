import XCTest
@testable import Parley

/// Unit tests for PeopleJoin.build — pure logic, no live objects, no MainActor.
final class PeopleJoinTests: XCTestCase {

    // MARK: - Fixtures

    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// Make a minimal Voiceprint without going through VoiceprintStore.
    private func makeVP(
        name: String,
        model: String = "wespeaker_v2",
        id: UUID = UUID(),
        createdAt: Date = PeopleJoinTests.epoch,
        audioSample: Data? = nil
    ) -> Voiceprint {
        let e: [Float] = Array(repeating: 0.1, count: 256)
        return Voiceprint(
            id: id,
            name: name,
            embeddings: [e],
            centroid: e,
            sampleCount: 1,
            createdAt: createdAt,
            updatedAt: createdAt,
            embeddingModel: model,
            embeddingDim: 256,
            schemaVersion: Voiceprint.currentSchemaVersion,
            audioSample: audioSample
        )
    }

    /// Make a Contact with sensible defaults.
    private func makeContact(
        name: String,
        company: String? = nil,
        side: Side = .other,
        aliases: [String] = []
    ) -> Contact {
        Contact(name: name, company: company, side: side, title: nil, linkedin: nil, aliases: aliases)
    }

    // MARK: - Happy path: contact + voiceprint

    func testContactAndVoiceprintJoin() {
        let contact = makeContact(name: "Alice Foo", company: "Acme", side: .customer)
        let vp = makeVP(name: "Alice Foo")
        let people = PeopleJoin.build(contacts: [contact], voiceprints: [vp])
        XCTAssertEqual(people.count, 1)
        let p = people[0]
        XCTAssertEqual(p.displayName, "Alice Foo")
        XCTAssertNotNil(p.contact)
        XCTAssertEqual(p.voiceprints.count, 1)
        XCTAssertEqual(p.enrolledEngines, ["FluidAudio"])
        XCTAssertEqual(p.anchorID, vp.id)
    }

    // MARK: - Contact only (no voiceprint)

    func testContactOnly() {
        let contact = makeContact(name: "Bob Bar", company: "Acme")
        let people = PeopleJoin.build(contacts: [contact], voiceprints: [])
        XCTAssertEqual(people.count, 1)
        let p = people[0]
        XCTAssertEqual(p.displayName, "Bob Bar")
        XCTAssertNotNil(p.contact)
        XCTAssertTrue(p.voiceprints.isEmpty)
        XCTAssertTrue(p.enrolledEngines.isEmpty)
        XCTAssertNil(p.anchorID)
    }

    // MARK: - Voiceprint only (no contact)

    func testVoiceprintOnly() {
        let vp = makeVP(name: "Charlie Baz")
        let people = PeopleJoin.build(contacts: [], voiceprints: [vp])
        XCTAssertEqual(people.count, 1)
        let p = people[0]
        XCTAssertEqual(p.displayName, "Charlie Baz")
        XCTAssertNil(p.contact)
        XCTAssertEqual(p.voiceprints.count, 1)
        XCTAssertEqual(p.anchorID, vp.id)
    }

    // MARK: - Alias join

    func testAliasJoin() {
        // Contact "Andre Nedelcoux" with alias "Andre" matches vp named "Andre".
        let contact = makeContact(name: "Andre Nedelcoux", aliases: ["Andre"])
        let vp = makeVP(name: "Andre")
        let people = PeopleJoin.build(contacts: [contact], voiceprints: [vp])
        XCTAssertEqual(people.count, 1)
        let p = people[0]
        XCTAssertEqual(p.displayName, "Andre Nedelcoux")
        XCTAssertNotNil(p.contact)
        XCTAssertEqual(p.voiceprints.count, 1)
        XCTAssertEqual(p.anchorID, vp.id)
    }

    // MARK: - Case-insensitive ALIAS match

    func testCaseInsensitiveAliasJoin() {
        // Voiceprint name matches an alias with different capitalisation.
        let contact = makeContact(name: "Christina Wharf-Bulsara", aliases: ["Christina Wharf"])
        let vp = makeVP(name: "CHRISTINA WHARF")
        let people = PeopleJoin.build(contacts: [contact], voiceprints: [vp])
        XCTAssertEqual(people.count, 1, "Case-insensitive alias match must claim the print")
        XCTAssertEqual(people[0].displayName, "Christina Wharf-Bulsara")
        XCTAssertEqual(people[0].voiceprints.count, 1)
    }

    // MARK: - Case-insensitive match

    func testCaseInsensitiveMatch() {
        let contact = makeContact(name: "Diana Prince")
        let vp = makeVP(name: "diana prince")  // lowercase in voiceprint store
        let people = PeopleJoin.build(contacts: [contact], voiceprints: [vp])
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].displayName, "Diana Prince")
        XCTAssertEqual(people[0].voiceprints.count, 1)
    }

    // MARK: - Two prints, both engines -> enrolledEngines has both, anchorID = first by createdAt

    func testTwoPrintsBothEngines() {
        let id1 = UUID()
        let id2 = UUID()
        let t1 = Date(timeIntervalSinceReferenceDate: 100)
        let t2 = Date(timeIntervalSinceReferenceDate: 200)
        let vpFluid    = makeVP(name: "Eve", model: "wespeaker_v2", id: id1, createdAt: t1)
        let vpWhisper  = makeVP(name: "Eve", model: "pyannote_v3",  id: id2, createdAt: t2)
        let contact = makeContact(name: "Eve")

        let people = PeopleJoin.build(contacts: [contact], voiceprints: [vpFluid, vpWhisper])
        XCTAssertEqual(people.count, 1)
        let p = people[0]
        XCTAssertEqual(p.voiceprints.count, 2)
        XCTAssertEqual(p.enrolledEngines, ["FluidAudio", "WhisperKit"])
        // anchorID = first by createdAt = id1
        XCTAssertEqual(p.anchorID, id1)
    }

    // MARK: - Multiple voiceprint-only prints with same name grouped into one Person

    func testVoiceprintOnlySameNameGrouped() {
        let id1 = UUID()
        let id2 = UUID()
        let t1 = Date(timeIntervalSinceReferenceDate: 10)
        let t2 = Date(timeIntervalSinceReferenceDate: 20)
        let vp1 = makeVP(name: "Frank", model: "wespeaker_v2", id: id1, createdAt: t1)
        let vp2 = makeVP(name: "Frank", model: "pyannote_v3",  id: id2, createdAt: t2)

        let people = PeopleJoin.build(contacts: [], voiceprints: [vp1, vp2])
        XCTAssertEqual(people.count, 1, "Two prints for the same voiceprint-only name should merge into one Person")
        let p = people[0]
        XCTAssertEqual(p.displayName, "Frank")
        XCTAssertNil(p.contact)
        XCTAssertEqual(p.voiceprints.count, 2)
        XCTAssertEqual(p.enrolledEngines, ["FluidAudio", "WhisperKit"])
        XCTAssertEqual(p.anchorID, id1)  // earliest by createdAt
    }

    // MARK: - engineLabel helper

    func testEngineLabelFluidAudio() {
        XCTAssertEqual(engineLabel(for: "wespeaker_v2"), "FluidAudio")
    }

    func testEngineLabelWhisperKit() {
        XCTAssertEqual(engineLabel(for: "pyannote_v3"), "WhisperKit")
    }

    func testEngineLabelUnknownReturnsNil() {
        XCTAssertNil(engineLabel(for: "wespeaker_v1"))
        XCTAssertNil(engineLabel(for: ""))
    }

    // MARK: - Sort order

    func testSortedByDisplayName() {
        let contacts = [
            makeContact(name: "Zelda"),
            makeContact(name: "Alice"),
            makeContact(name: "Mallory"),
        ]
        let people = PeopleJoin.build(contacts: contacts, voiceprints: [])
        XCTAssertEqual(people.map(\.displayName), ["Alice", "Mallory", "Zelda"])
    }

    // MARK: - Voiceprint consumed by contact match; does not also appear as voiceprint-only

    func testConsumedVoiceprintNotDuplicated() {
        let contact = makeContact(name: "Grace", aliases: ["G"])
        let vpMatched    = makeVP(name: "grace")  // matches case-insensitively
        let vpUnmatched  = makeVP(name: "Heidi")
        let people = PeopleJoin.build(contacts: [contact], voiceprints: [vpMatched, vpUnmatched])
        XCTAssertEqual(people.count, 2)
        let grace = people.first { $0.displayName == "Grace" }
        let heidi = people.first { $0.displayName == "Heidi" }
        XCTAssertNotNil(grace)
        XCTAssertNotNil(heidi)
        XCTAssertEqual(grace?.voiceprints.count, 1)
        XCTAssertNil(heidi?.contact)
    }
}
