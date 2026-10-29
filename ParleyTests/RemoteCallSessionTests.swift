import XCTest
@testable import Parley

/// Session plumbing for the "mic is Me on remote calls" split and the invite list.
final class RemoteCallSessionTests: XCTestCase {

    private func manifest(micInputMode: String?) -> SessionManifest {
        var m = SessionManifest(
            id: "2026-10-29-103207", title: "Intellias - SpaceX UKI Partnership", attendees: "",
            filing: "", model: "v3", computeMode: "fluid", startedAt: Date(), lastHeartbeat: Date(),
            status: .finalized, startedByDetection: true, callBundleID: nil, callDisplayName: nil,
            manualNotes: "", audioTracks: ["mic.caf", "system.caf"])
        m.micInputMode = micInputMode
        return m
    }

    func testOnlyRegularSessionsTreatTheMicAsTheOwner() {
        XCTAssertTrue(manifest(micInputMode: "regular").micIsOwner)
        XCTAssertFalse(manifest(micInputMode: "room").micIsOwner)
        XCTAssertFalse(manifest(micInputMode: nil).micIsOwner, "legacy sessions keep full diarization")
    }

    func testLegacyManifestDecodesWithoutTheNewFields() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: enc.encode(manifest(micInputMode: "regular"))) as? [String: Any])
        json["micInputMode"] = nil
        json["invitees"] = nil
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(SessionManifest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.micInputMode)
        XCTAssertNil(decoded.invitees)
    }

    func testInviteesRoundTripWithRSVP() throws {
        var m = manifest(micInputMode: "regular")
        m.invitees = [MeetingInvitee(name: "Kadir Erol", response: .declined),
                      MeetingInvitee(name: "Lucy Willoughby", response: nil)]
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(SessionManifest.self, from: enc.encode(m))
        XCTAssertEqual(decoded.invitees?.map(\.rsvpLabel), ["declined", "no response"])
    }

    func testRoomIsStickyForTheWholeSession() {
        XCTAssertEqual(RecordingController.stickyMicMode(nil, .regular), "regular")
        XCTAssertEqual(RecordingController.stickyMicMode("regular", .room), "room")
        XCTAssertEqual(RecordingController.stickyMicMode("room", .regular), "room")
    }

    func testMeIsTheOwnerNotAnUnnamedSpeaker() {
        XCTAssertFalse(TranscriptStore.hasGenericSpeakerLabels("**[00:00:01] Me:** hi\n**[00:00:03] Jason Creane:** hey"))
        XCTAssertTrue(TranscriptStore.hasGenericSpeakerLabels("**[00:00:01] Me:** hi\n**[00:00:03] Speaker 2:** hey"))
        XCTAssertTrue(TranscriptStore.hasGenericSpeakerLabels("**[00:00:01] Remote:** hey"))
    }

    func testGlossaryTermsGoThroughTheSameVocabularyGuards() {
        let candidates = FluidVocabularyBuilder.candidates(
            attendees: "", meetingTitle: "",
            glossary: ["London Stock Exchange Group", "Experian", "LSEG", "delivery"],
            enabled: true)
        func tier(_ text: String) -> FluidVocabularyBuilder.Tier? {
            candidates.first { $0.text == text }?.tier
        }
        XCTAssertEqual(tier("London Stock Exchange Group"), .fullName)
        XCTAssertEqual(tier("Experian"), .strictToken)
        XCTAssertFalse(candidates.first { $0.text == "LSEG" }?.isIncluded ?? true, "4 letters is too short to boost")
        XCTAssertFalse(candidates.first { $0.text == "delivery" }?.isIncluded ?? true, "ordinary English")
    }
}
