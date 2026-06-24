import XCTest
@testable import Parley

/// Fixtures below are verbatim captures from live conferencing apps, recorded
/// by tools/MeetingProbe on 2026-06-04 (see probe.log + the investigation doc).
/// When Teams/Zoom UI updates break parsing, re-run the probe during a meeting
/// and refresh these fixtures from the new dump.
final class MeetingParsersTests: XCTestCase {

    private func node(_ role: String, title: String? = nil, desc: String? = nil,
                      value: String? = nil, depth: Int = 0) -> AXNode {
        AXNode(role: role, title: title, desc: desc, value: value, depth: depth)
    }

    // MARK: Teams call-window title

    func testTeamsCallTitleParsesMeetingWindow() {
        XCTAssertEqual(
            MeetingParsers.teamsCallTitle(
                windowTitle: "test meeting for probe | Intellias | naufal.mir@intellias.com | Microsoft Teams"),
            "test meeting for probe")
    }

    func testTeamsCallTitleRejectsNavViews() {
        // Main window parked on Calendar / Chat — never a meeting title.
        XCTAssertNil(MeetingParsers.teamsCallTitle(
            windowTitle: "Calendar | Interview: ProAG Case Study | Intellias | naufal.mir@intellias.com | Microsoft Teams"))
        XCTAssertNil(MeetingParsers.teamsCallTitle(
            windowTitle: "Chat | #IntelliVoice Ambassador Program: Kick-off meeting | Intellias | naufal.mir@intellias.com | Microsoft Teams"))
    }

    func testTeamsCallTitleRejectsGenericUnsettledTitle() {
        // A freshly-opened call window is titled "Microsoft Teams" for ~5-10s.
        XCTAssertNil(MeetingParsers.teamsCallTitle(windowTitle: "Microsoft Teams"))
    }

    func testTeamsCallTitleKeepsPipesInsideMeetingName() {
        XCTAssertEqual(
            MeetingParsers.teamsCallTitle(
                windowTitle: "Q3 Review | Budget | Intellias | naufal.mir@intellias.com | Microsoft Teams"),
            "Q3 Review | Budget")
    }

    // MARK: Teams roster

    // New Teams (v26149, captured live 2026-06-24): row titles are "Name, status…"
    // with NO "Has context menu" marker; the clean name is the row's AXStaticText
    // value; section headers carry an "N total" count.
    func testTeamsAttendeesParsesRosterRows() {
        let nodes = [
            node("AXOutline", desc: "Attendees", depth: 18),
            node("AXRow", title: "In this meeting, 3 total Mute all", depth: 19),  // header — skipped
            node("AXGroup", desc: "In this meeting, 3 total", depth: 20),
            node("AXStaticText", value: "In this meeting (3)", depth: 21),
            node("AXRow", title: "Naufal Mir, Muted", depth: 19),
            node("AXGroup", desc: "Naufal Mir, Muted", depth: 20),
            node("AXStaticText", value: "Naufal Mir", depth: 22),
            node("AXImage", desc: "Muted", depth: 21),
            node("AXRow", title: "Oleksii Brodnikov, Unmuted", depth: 19),
            node("AXStaticText", value: "Oleksii Brodnikov", depth: 22),
            node("AXRow", title: "Others invited, 2 total", depth: 19),           // header — skipped
            node("AXStaticText", value: "Others invited (2)", depth: 21),
            node("AXRow", title: "Tetyana Nykologorska, Out of office, Tentative", depth: 19),
            node("AXStaticText", value: "Tetyana Nykologorska", depth: 22),
            node("AXStaticText", value: "Tentative", depth: 22),
            node("AXRow", title: "Olga Ditmarova, In a meeting, Organizer", depth: 19),
            node("AXStaticText", value: "Olga Ditmarova", depth: 22),
            node("AXStaticText", value: "Organizer", depth: 22),
            node("AXButton", desc: "Share invite", depth: 4),                     // outside the outline
        ]
        XCTAssertEqual(MeetingParsers.teamsAttendees(nodes), [
            RosterEntry(name: "Naufal Mir", role: nil),
            RosterEntry(name: "Oleksii Brodnikov", role: nil),
            RosterEntry(name: "Tetyana Nykologorska", role: nil),
            RosterEntry(name: "Olga Ditmarova", role: "Organizer"),
        ])
    }

    // Legacy Teams format (pre-2026): "Name, Has context menu, Role, …" still parses.
    func testTeamsAttendeesParsesLegacyRosterRows() {
        let nodes = [
            node("AXOutline", desc: "Attendees", depth: 5),
            node("AXRow", title: "In this meeting, 1 total", depth: 6),           // header — skipped
            node("AXRow", title: "Naufal Mir, Has context menu, Organizer, Muted", depth: 6),
            node("AXStaticText", value: "Naufal Mir", depth: 7),
            node("AXRow", title: "Jane Doe, Has context menu, Muted", depth: 6),  // no role segment
        ]
        XCTAssertEqual(MeetingParsers.teamsAttendees(nodes), [
            RosterEntry(name: "Naufal Mir", role: "Organizer"),
            RosterEntry(name: "Jane Doe", role: nil),
        ])
    }

    func testTeamsAttendeesIgnoresRowsOutsideAttendeesOutline() {
        let nodes = [
            node("AXRow", title: "Naufal Mir, Has context menu, Organizer", depth: 3),
        ]
        XCTAssertTrue(MeetingParsers.teamsAttendees(nodes).isEmpty)
    }

    // MARK: Zoom roster

    func testZoomAttendeesFromSpeakerTileAndPanel() {
        let nodes = [
            node("AXTabGroup", desc: "Naufal Mir, Computer audio unmuted", depth: 2),
            node("AXOutline", desc: "Participants list", depth: 3),
            node("AXStaticText", value: "Naufal Mir (Host, me)", depth: 5),
            node("AXStaticText", value: "Guest Person", depth: 5),
        ]
        let entries = MeetingParsers.zoomAttendees(nodes)
        XCTAssertEqual(entries, [
            RosterEntry(name: "Naufal Mir", role: nil),          // speaker tile
            RosterEntry(name: "Naufal Mir", role: "Host"),       // panel row
            RosterEntry(name: "Guest Person", role: nil),
        ])
    }

    // MARK: Outlook-web calendar (Teams Calendar tab)

    func testCalendarEventWithCommaInTitle() {
        // Real capture — naive comma-splitting would truncate this title.
        let nodes = [node("AXButton",
            desc: "Christina x Wes - Intellias catch up., 15:00 to 15:30, Tuesday, June 02, 2026, By Christina Wharf, Tentative")]
        let events = MeetingParsers.outlookCalendarEvents(nodes)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.title, "Christina x Wes - Intellias catch up.")
        XCTAssertEqual(events.first?.organizer, "Christina Wharf")
    }

    func testCalendarSkipsCanceledAndAllDayEvents() {
        let nodes = [
            node("AXButton", desc: "Canceled: AI OPS and AI Data platform, 12:00 to 12:30, Thursday, June 04, 2026, Microsoft Teams Meeting, By Alexander Kulinchenko, Free"),
            node("AXButton", desc: "andre on holiday, all day event, Monday, June 01, 2026 to Friday, June 05, 2026, somewhere nice, By Andre Nedelcoux, Free"),
        ]
        XCTAssertTrue(MeetingParsers.outlookCalendarEvents(nodes).isEmpty)
    }

    func testCurrentEventMatchesByTimeOverlapWithGrace() {
        let nodes = [node("AXButton",
            desc: "Modernization & Refactoring services for ISVs, 16:00 to 16:30, Thursday, June 04, 2026, Microsoft Teams Meeting, By Nathan Bender, Tentative")]
        let events = MeetingParsers.outlookCalendarEvents(nodes)
        let cal = Calendar.current
        func at(_ h: Int, _ m: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 6, day: 4, hour: h, minute: m))!
        }
        XCTAssertEqual(MeetingParsers.currentEvent(in: events, now: at(16, 5))?.title,
                       "Modernization & Refactoring services for ISVs")
        // 10-minute early-join grace.
        XCTAssertNotNil(MeetingParsers.currentEvent(in: events, now: at(15, 55)))
        XCTAssertNil(MeetingParsers.currentEvent(in: events, now: at(15, 40)))
        XCTAssertNil(MeetingParsers.currentEvent(in: events, now: at(16, 30)))
    }

    // MARK: Outlook native calendar

    func testOutlookNativeJoinableTitle() {
        // Real capture: only the currently-joinable event has a "Join" child.
        let nodes = [
            node("AXButton", desc: "Wickes Workshop", depth: 6),
            node("AXButton", desc: "testing for proble", depth: 6),
            node("AXButton", desc: "Join", depth: 7),
            node("AXButton", desc: "Modernization & Refactoring services for ISVs", depth: 6),
        ]
        XCTAssertEqual(MeetingParsers.outlookNativeJoinableTitle(nodes), "testing for proble")
    }

    func testOutlookNativeJoinableTitleNilWithoutJoinChild() {
        let nodes = [
            node("AXButton", desc: "Wickes Workshop", depth: 6),
            node("AXButton", desc: "Join", depth: 6),   // sibling, not a child
        ]
        XCTAssertNil(MeetingParsers.outlookNativeJoinableTitle(nodes))
    }

    // MARK: Zoom home "Now" entry

    func testZoomHomeNowTitle() {
        // Real capture (timer values masked by the probe; irrelevant to parsing).
        let nodes = [node("AXGroup",
            title: "zoom probe test\nNow MM:SS - MM:SS Host: Naufal Mir press Tab for more options, press Enter for detailed page",
            depth: 8)]
        let result = MeetingParsers.zoomHomeNowTitle(nodes)
        XCTAssertEqual(result?.title, "zoom probe test")
        XCTAssertEqual(result?.host, "Naufal Mir")
    }

    func testZoomHomeIgnoresNonNowEvents() {
        let nodes = [node("AXGroup",
            title: "tomorrow's meeting\n9:00 AM - 9:30 AM Host: Someone Else", depth: 8)]
        XCTAssertNil(MeetingParsers.zoomHomeNowTitle(nodes))
    }
}
