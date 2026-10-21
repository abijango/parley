import XCTest
@testable import Parley

final class MeetingRosterTests: XCTestCase {

    private func name(_ s: String) -> DisplayName { DisplayName(raw: s)! }

    func testUnreadableDoesNotChangeRoster() {
        var roster = MeetingRoster()
        roster.apply(.unreadable(at: Date()))
        XCTAssertTrue(roster.people.isEmpty)
    }

    func testCompleteMarksMissingPeopleLeftButKeepsThem() {
        var roster = MeetingRoster()
        let t0 = Date()
        roster.apply(RosterSnapshot(
            observedAt: t0, coverage: .complete, isFirstSighting: true,
            participants: [
                Participant(name: name("Ada"), presence: .inCall(.listedInCall), role: nil),
                Participant(name: name("Bob"), presence: .inCall(.listedInCall), role: nil),
            ]))
        let t1 = t0.addingTimeInterval(10)
        roster.apply(RosterSnapshot(
            observedAt: t1, coverage: .complete, isFirstSighting: false,
            participants: [
                Participant(name: name("Ada"), presence: .inCall(.listedInCall), role: nil),
            ]))
        XCTAssertTrue(roster.person(named: name("Ada"))!.isPresentNow)
        XCTAssertEqual(roster.person(named: name("Bob"))!.presence, .left(at: t1))
        XCTAssertEqual(roster.people.count, 2)
    }

    func testSightingsDoNotMarkLeft() {
        var roster = MeetingRoster()
        let t0 = Date()
        roster.apply(RosterSnapshot(
            observedAt: t0, coverage: .sightings, isFirstSighting: true,
            participants: [
                Participant(name: name("Ada"), presence: .inCall(.participantTile), role: nil),
            ]))
        roster.apply(RosterSnapshot(
            observedAt: t0.addingTimeInterval(5), coverage: .sightings, isFirstSighting: false,
            participants: []))
        XCTAssertTrue(roster.person(named: name("Ada"))!.isPresentNow)
    }

    func testInvitedNotAdmitted() {
        var roster = MeetingRoster()
        roster.apply(RosterSnapshot(
            observedAt: Date(), coverage: .complete, isFirstSighting: true,
            participants: [
                Participant(name: name("Ada"), presence: .inCall(.listedInCall), role: nil),
                Participant(name: name("Invited Person"), presence: .invited(.tentative), role: nil),
            ]))
        XCTAssertEqual(AttendeePolicy.admissions(in: roster).map(\.value), ["Ada"])
        XCTAssertTrue(AttendeePolicy.uncertainChips(in: roster).isEmpty)
        XCTAssertEqual(roster.invited.map(\.name.value), ["Invited Person"])
    }

    func testDeviceLabelIsUncertainChip() {
        var roster = MeetingRoster()
        roster.apply(RosterSnapshot(
            observedAt: Date(), coverage: .complete, isFirstSighting: true,
            participants: [
                Participant(name: name("Naufal's MacBook"), presence: .inCall(.listedInCall), role: nil),
            ]))
        XCTAssertTrue(AttendeePolicy.admissions(in: roster).isEmpty)
        XCTAssertEqual(AttendeePolicy.uncertainChips(in: roster).map(\.name.value), ["Naufal's MacBook"])
    }

    func testFirstSightingIsNotAJoinTime() {
        var roster = MeetingRoster()
        let t0 = Date()
        roster.apply(RosterSnapshot(
            observedAt: t0, coverage: .complete, isFirstSighting: true,
            participants: [Participant(name: name("Ada"), presence: .inCall(.listedInCall), role: nil)]))
        XCTAssertEqual(roster.person(named: name("Ada"))!.arrival, .presentBeforeFirstSight(noticedAt: t0))
        let t1 = t0.addingTimeInterval(30)
        roster.apply(RosterSnapshot(
            observedAt: t1, coverage: .complete, isFirstSighting: false,
            participants: [
                Participant(name: name("Ada"), presence: .inCall(.listedInCall), role: nil),
                Participant(name: name("Late Joiner"), presence: .inCall(.listedInCall), role: nil),
            ]))
        XCTAssertEqual(roster.person(named: name("Late Joiner"))!.arrival, .joined(at: t1))
    }

    func testTeamsSeeMoreIsNotAdmitted() {
        var roster = MeetingRoster()
        roster.apply(RosterSnapshot(
            observedAt: Date(), coverage: .complete, isFirstSighting: true,
            participants: [
                Participant(name: name("Ada"), presence: .inCall(.listedInCall), role: nil),
                Participant(name: name("See more"), presence: .inCall(.listedInCall), role: nil),
            ]))
        XCTAssertEqual(AttendeePolicy.admissions(in: roster).map(\.value), ["Ada"])
        XCTAssertTrue(NameClassifier.isChromeLabel(name("See more")))
        XCTAssertTrue(AttendeePolicy.uncertainChips(in: roster).isEmpty)
    }

    @MainActor
    func testAttendeeFieldAppendsJoinersAndKeepsLeavers() {
        let meeting = MeetingSessionState()
        let admission = MeetingAdmission(meeting: meeting)
        let t0 = Date()
        func reading(_ names: [String], at date: Date) -> SourceReading {
            SourceReading(
                title: nil,
                roster: RosterSnapshot(
                    observedAt: date, coverage: .complete, isFirstSighting: date == t0,
                    participants: names.map {
                        Participant(name: name($0), presence: .inCall(.listedInCall), role: nil)
                    }))
        }
        admission.ingest(reading(["Ada", "Bob"], at: t0))
        XCTAssertEqual(meeting.attendees, "Ada, Bob")
        admission.ingest(reading(["Ada"], at: t0.addingTimeInterval(10)))
        XCTAssertEqual(meeting.attendees, "Ada, Bob")
        admission.ingest(reading(["Ada", "Cara"], at: t0.addingTimeInterval(20)))
        XCTAssertEqual(meeting.attendees, "Ada, Bob, Cara")
    }
}
