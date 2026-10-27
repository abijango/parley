import Foundation

/// Legacy flat roster row. Prefer `MeetingParsers.teamsRoster` / `zoomRosterSnapshot`,
/// which carry presence. Kept so older tests and call sites compile during the cutover.
struct RosterEntry: Equatable {
    let name: String
    let role: String?   // "Organizer" / "Host" / …
}

struct ParsedPerson: Equatable {
    let name: DisplayName
    let role: MeetingRole?
    let inviteResponse: InviteResponse?
}

struct ParsedTeamsRoster: Equatable {
    let inMeeting: [ParsedPerson]
    let othersInvited: [ParsedPerson]
}

/// Pure parsing of conferencing-app AX trees into meeting metadata — no AX
/// calls, no main actor, fully unit-testable. Every pattern here was captured
/// from live apps by `tools/MeetingProbe` (raw dumps in probe.log; analysis in
/// docs/MEETING_METADATA_INVESTIGATION.md). String anchors are English-only —
/// a v1 limitation; parse failures must degrade to "nothing found", never throw.
enum MeetingParsers {

    // MARK: Teams call-window title

    /// First pipe-segment titles of Teams' MAIN window views — a call window's
    /// first segment is never one of these.
    static let teamsNavViews: Set<String> = [
        "Microsoft Teams", "Calendar", "Chat", "Activity", "Teams", "Calls",
        "OneDrive", "Apps", "Files", "Copilot",
    ]

    /// Leading segment of a call popped out into its compact window.
    static let teamsCompactViewPrefix = "Meeting compact view"

    /// Parses a Teams window title of the call-window form
    /// `<meeting title> | <org> | <account>`, optionally followed by
    /// `| Microsoft Teams` (builds before 26276 appended it) and optionally
    /// led by `Meeting compact view |`.
    /// Returns nil for main-window/nav titles and for the generic
    /// `"Microsoft Teams"` a freshly-opened call window carries before its real
    /// title settles (caller should keep polling). The meeting title may itself
    /// contain " | ", so only the trailing org and account segments are stripped.
    static func teamsCallTitle(windowTitle: String) -> String? {
        var segments = windowTitle.components(separatedBy: " | ")
        if segments.last == "Microsoft Teams" { segments.removeLast() }
        // The account segment is the anchor now that the app-name suffix is optional.
        guard segments.count >= 3, segments.last?.contains("@") == true else { return nil }
        segments.removeLast(2)
        if segments.first?.trimmingCharacters(in: .whitespaces) == teamsCompactViewPrefix {
            segments.removeFirst()
        }
        // Main-window titles lead with a nav view ("Calendar | <selected event> |
        // …"), so the nav check must look at the FIRST segment, not the joined
        // title — a meeting name may legitimately contain " | ".
        guard let first = segments.first?.trimmingCharacters(in: .whitespaces),
              !teamsNavViews.contains(first) else { return nil }
        let title = segments.joined(separator: " | ")
            .trimmingCharacters(in: titleTrimSet)
        return title.isEmpty ? nil : title
    }

    /// Whitespace plus the zero-width characters Outlook leaves around subjects.
    static let titleTrimSet = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}"))

    /// Window titles seen on idle Webex (`Webex`, `Window`) and the app chrome
    /// names. A meeting window replaces these with the space or meeting name.
    static let webexGenericTitles: Set<String> = [
        "webex", "window", "webex meetings", "webexhelper", "cisco webex",
    ]

    static func webexCallTitle(windowTitle: String) -> String? {
        let title = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !webexGenericTitles.contains(title.lowercased()) else { return nil }
        return title
    }

    /// Teams bakes presence/relationship badges ("External", "unfamiliar", "Unverified",
    /// "Guest") into the SAME accessibility segment as the name (no comma), so a parsed
    /// name reads "Farhang Mehregani External unfamiliar". Strip those trailing badge
    /// words so the attendee is just the person's name. Only trims from the END and only
    /// known badge words, so real names are untouched.
    static func stripStatusBadges(_ name: String) -> String {
        let badges: Set<String> = ["external", "unfamiliar", "unverified", "guest"]
        var words = name.split(separator: " ").map(String.init)
        while let last = words.last, badges.contains(last.lowercased()), words.count > 1 {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// New Teams can render names surname-first ("Rosen, Adam"). Flip to natural
    /// order so no comma survives in a name — attendees are stored comma-delimited
    /// downstream (see `TranscriptWriter.splitAttendees`), and a comma would split
    /// one person into two chips. Only flips a clean two-part "Last, First"; anything
    /// else (no comma, extra commas, an empty side) is returned untouched.
    static func normalizeDisplayName(_ name: String) -> String {
        let parts = name.components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return name }
        return "\(parts[1]) \(parts[0])"
    }

    // MARK: Teams roster (People pane open)

    /// Rows under `AXOutline desc="Attendees"`, split by section. `nil` when the
    /// outline is absent (People pane closed) — that is *not* an empty meeting.
    static func teamsRoster(_ nodes: [AXNode]) -> ParsedTeamsRoster? {
        let roles: Set<String> = ["Organizer", "Co-organizer", "Presenter", "Attendee", "Guest", "External", "Host"]
        guard nodes.contains(where: { $0.role == "AXOutline" && $0.desc == "Attendees" }) else {
            return nil
        }
        let slice = subtree(of: nodes, anchor: { $0.role == "AXOutline" && $0.desc == "Attendees" })
        var inMeeting: [ParsedPerson] = []
        var invited: [ParsedPerson] = []
        var seen = Set<String>()
        var sectionIsInvited = false
        var i = slice.startIndex
        while i < slice.endIndex {
            let row = nodes[i]
            guard row.role == "AXRow" else { i += 1; continue }
            let rowDepth = row.depth
            let title = row.title ?? row.desc ?? ""
            if title.range(of: #"\d+\s+total"#, options: .regularExpression) != nil {
                let lower = title.lowercased()
                if lower.contains("others invited") {
                    sectionIsInvited = true
                } else if lower.contains("in this meeting") {
                    sectionIsInvited = false
                }
                i += 1
                continue
            }

            var j = i + 1
            var name: String?
            var roleRaw: String?
            var responseRaw: String?
            while j < slice.endIndex, nodes[j].depth > rowDepth {
                let d = nodes[j]
                if d.role == "AXStaticText", let v = d.value, !v.isEmpty {
                    if name == nil { name = v }
                    else if roleRaw == nil, roles.contains(v) { roleRaw = v }
                    else if responseRaw == nil, InviteResponse.parse(v) != nil { responseRaw = v }
                }
                j += 1
            }
            let parts = title.components(separatedBy: ", ").filter { $0 != "Has context menu" }
            if name == nil { name = parts.first }
            if roleRaw == nil { roleRaw = parts.dropFirst().first(where: roles.contains) }
            if responseRaw == nil {
                responseRaw = parts.dropFirst().first { InviteResponse.parse($0) != nil }
            }

            if let raw = name, let display = DisplayName(raw: raw),
               seen.insert(display.key).inserted {
                let person = ParsedPerson(
                    name: display,
                    role: MeetingRole.parse(roleRaw),
                    inviteResponse: InviteResponse.parse(responseRaw ?? ""))
                if sectionIsInvited {
                    invited.append(person)
                } else {
                    inMeeting.append(person)
                }
            }
            i = j
        }
        return ParsedTeamsRoster(inMeeting: inMeeting, othersInvited: invited)
    }

    /// Present-only names from the in-meeting section. Invite rows are excluded.
    static func teamsAttendees(_ nodes: [AXNode]) -> [RosterEntry] {
        guard let roster = teamsRoster(nodes) else { return [] }
        return roster.inMeeting.map { RosterEntry(name: $0.name.value, role: $0.role?.display) }
    }

    // MARK: Zoom roster

    /// Two sources, both observed live:
    /// - active-speaker tile (no panel needed): `AXTabGroup` desc
    ///   `"Naufal Mir, Computer audio unmuted"`
    /// - Participants panel: statics under `AXOutline desc="Participants list"`,
    ///   `"Naufal Mir (Host, me)"`.
    static func zoomAttendees(_ nodes: [AXNode]) -> [RosterEntry] {
        snapshotPeople(zoomRosterParts(nodes).people).map {
            RosterEntry(name: $0.name.value, role: $0.role?.display)
        }
    }

    /// Panel present → complete in-call list. Tiles only → sightings. Neither → nil (unreadable).
    static func zoomRosterSnapshot(_ nodes: [AXNode], at date: Date, isFirstSighting: Bool) -> RosterSnapshot? {
        let parts = zoomRosterParts(nodes)
        if parts.hasPanel {
            return RosterSnapshot(
                observedAt: date, coverage: .complete, isFirstSighting: isFirstSighting,
                participants: snapshotPeople(parts.people).map {
                    Participant(name: $0.name, presence: .inCall(.listedInCall), role: $0.role)
                })
        }
        if !parts.tilePeople.isEmpty {
            return RosterSnapshot(
                observedAt: date, coverage: .sightings, isFirstSighting: isFirstSighting,
                participants: snapshotPeople(parts.tilePeople).map {
                    Participant(name: $0.name, presence: .inCall(.participantTile), role: $0.role)
                })
        }
        return nil
    }

    private struct ZoomRosterParts {
        var hasPanel = false
        var tilePeople: [ParsedPerson] = []
        var people: [ParsedPerson] = []
    }

    private static func zoomRosterParts(_ nodes: [AXNode]) -> ZoomRosterParts {
        var parts = ZoomRosterParts()

        func add(_ raw: String, role: MeetingRole?, into bucket: inout [ParsedPerson], seen: inout Set<String>) {
            guard let name = DisplayName(raw: raw), seen.insert(name.key).inserted else { return }
            bucket.append(ParsedPerson(name: name, role: role, inviteResponse: nil))
        }

        var tileSeen = Set<String>()
        for node in nodes where node.role == "AXTabGroup" {
            guard let desc = node.desc,
                  let range = desc.range(of: ", Computer audio") else { continue }
            add(String(desc[..<range.lowerBound]), role: nil, into: &parts.tilePeople, seen: &tileSeen)
        }

        let panel = subtree(of: nodes, anchor: { $0.role == "AXOutline" && $0.desc == "Participants list" })
        parts.hasPanel = nodes.contains { $0.role == "AXOutline" && $0.desc == "Participants list" }
        var panelSeen = Set<String>()
        for node in panel where node.role == "AXStaticText" {
            guard let value = node.value else { continue }
            if let parenIdx = value.range(of: " (", options: .backwards), value.hasSuffix(")") {
                let name = String(value[..<parenIdx.lowerBound])
                let inParens = value[parenIdx.upperBound...].dropLast()
                let role = inParens.components(separatedBy: ", ")
                    .first { $0 == "Host" || $0 == "Co-host" }
                add(name, role: MeetingRole.parse(role), into: &parts.people, seen: &panelSeen)
            } else {
                add(value, role: nil, into: &parts.people, seen: &panelSeen)
            }
        }
        if parts.people.isEmpty { parts.people = parts.tilePeople }
        return parts
    }

    // MARK: Webex roster

    /// Video-grid tiles under `AXList title="<layout>, Video Grid Area"`, e.g.
    /// `AXGroup title="Petya Dimkina, , , muted, Video off, Sharing"`. The grid
    /// hides overflow participants, so tiles are sightings, never a complete list.
    static func webexRosterSnapshot(_ nodes: [AXNode], at date: Date, isFirstSighting: Bool) -> RosterSnapshot? {
        let isGrid: (AXNode) -> Bool = { $0.role == "AXList" && ($0.title?.hasSuffix("Video Grid Area") ?? false) }
        guard nodes.contains(where: isGrid) else { return nil }
        var seen = Set<String>()
        var people: [Participant] = []
        for node in subtree(of: nodes, anchor: isGrid) where node.role == "AXGroup" {
            guard let title = node.title, let comma = title.range(of: ", "),
                  let name = DisplayName(raw: String(title[..<comma.lowerBound])),
                  seen.insert(name.key).inserted else { continue }
            people.append(Participant(name: name, presence: .inCall(.participantTile), role: nil))
        }
        guard !people.isEmpty else { return nil }
        return RosterSnapshot(observedAt: date, coverage: .sightings, isFirstSighting: isFirstSighting,
                              participants: people)
    }

    private static func snapshotPeople(_ people: [ParsedPerson]) -> [ParsedPerson] {
        var seen = Set<String>()
        return people.filter { seen.insert($0.name.key).inserted }
    }

    // MARK: Calendar lookups

    struct CalendarEvent: Equatable {
        let title: String
        let start: Date?
        let end: Date?
        let organizer: String?
        var platform: MeetingPlatform?
    }

    /// Events from the Teams Calendar tab (an embedded Outlook web view), e.g.
    /// `"Wickes Workshop, 09:00 to 11:00, Monday, June 01, 2026, By Alexander
    /// Kulinchenko, Tentative"`. Titles can contain commas, so parsing anchors
    /// on the `, HH:MM to HH:MM, ` time pattern — never naive comma-splitting.
    /// `Canceled:` events and all-day events (no time anchor) are skipped.
    static func outlookCalendarEvents(_ nodes: [AXNode], calendar: Calendar = .current) -> [CalendarEvent] {
        // Capture groups: start time, end time. Local because `Regex` isn't Sendable.
        let timeAnchor = #/, (\d{1,2}:\d{2}) to (\d{1,2}:\d{2}), /#
        var events: [CalendarEvent] = []
        for node in nodes where node.role == "AXButton" {
            guard let desc = node.desc, !desc.hasPrefix("Canceled:"),
                  let match = desc.firstMatch(of: timeAnchor) else { continue }
            let title = String(desc[..<match.range.lowerBound]).trimmingCharacters(in: titleTrimSet)
            guard !title.isEmpty else { continue }
            let rest = String(desc[match.range.upperBound...])
            // rest: "Monday, June 01, 2026, Microsoft Teams Meeting, By X, Busy…"
            let organizer = rest.firstMatch(of: #/, By ([^,]+)/#).map { String($0.1) }
            var start: Date?, end: Date?
            if let dateMatch = rest.firstMatch(of: #/[A-Za-z]+ \d{1,2}, \d{4}/#) {
                let dateStr = String(dateMatch.0)
                start = Self.parse(date: dateStr, time: String(match.1), calendar: calendar)
                end = Self.parse(date: dateStr, time: String(match.2), calendar: calendar)
            }
            events.append(CalendarEvent(title: title, start: start, end: end, organizer: organizer,
                                        platform: MeetingPlatform.mentioned(in: rest)))
        }
        return events
    }

    /// Among parsed events, the one overlapping `now` (grace minutes early —
    /// people join meetings a little before the hour).
    static func currentEvent(in events: [CalendarEvent], now: Date = Date(),
                             graceMinutes: Double = 10) -> CalendarEvent? {
        events.first { e in
            guard let start = e.start, let end = e.end else { return false }
            return start.addingTimeInterval(-graceMinutes * 60) <= now && now < end
        }
    }

    /// Title from the Teams calendar view, then native Outlook's joinable event.
    /// Events whose location names another service belong to a different call.
    /// Callers prepare the Teams tree first. Electron apps stay blank until that prep.
    static func scheduleOverlapTitle(apps: RunningApps, tree: any MeetingUITree,
                                     platform: MeetingPlatform) -> TitleCandidate? {
        if let teamsPid = apps.pid(prefix: "com.microsoft.teams") {
            let events = outlookCalendarEvents(tree.nodes(pid: teamsPid))
                .filter { $0.platform == nil || $0.platform == platform }
            if let event = currentEvent(in: events) {
                return TitleCandidate(title: event.title, authority: .scheduleOverlap, provenance: "calendar:teams")
            }
        }
        if let outlookPid = apps.pid(exact: "com.microsoft.outlook"),
           let title = outlookNativeJoinableTitle(tree.nodes(pid: outlookPid), for: platform) {
            return TitleCandidate(title: title, authority: .scheduleOverlap, provenance: "calendar:outlook")
        }
        return nil
    }

    /// Native Outlook Calendar view: events are buttons grouped by day, and the
    /// *currently joinable* one carries a child "Join" button — that child is the
    /// "this meeting is happening now" marker. Labels read `<subject>` or
    /// `<subject>, <location>`, where the location is "Microsoft Teams Meeting"
    /// or a join URL.
    static func outlookNativeJoinableTitle(_ nodes: [AXNode], for platform: MeetingPlatform) -> String? {
        for (i, node) in nodes.enumerated() where node.role == "AXButton" {
            guard let label = node.desc else { continue }
            for next in nodes.dropFirst(i + 1) {
                if next.depth <= node.depth { break }
                if next.role == "AXButton" && next.desc == "Join" {
                    let event = outlookEventLabel(label)
                    if let title = event.title, event.platform == nil || event.platform == platform {
                        return title
                    }
                    break
                }
            }
        }
        return nil
    }

    private static func outlookEventLabel(_ label: String) -> (title: String?, platform: MeetingPlatform?) {
        var subject = label
        var platform: MeetingPlatform?
        if let link = label.range(of: ", https://") {
            subject = String(label[..<link.lowerBound])
            platform = MeetingPlatform.mentioned(in: String(label[link.upperBound...]))
        } else if label.hasSuffix(", Microsoft Teams Meeting") {
            subject = String(label.dropLast(", Microsoft Teams Meeting".count))
            platform = .teams
        }
        let title = subject.trimmingCharacters(in: titleTrimSet)
        return (title.isEmpty ? nil : title, platform)
    }

    /// Zoom Workplace home tab: the running scheduled meeting is an event group
    /// whose text is `"<topic>\nNow <times> Host: <name> …"`.
    static func zoomHomeNowTitle(_ nodes: [AXNode]) -> (title: String, host: String?)? {
        for node in nodes where node.role == "AXGroup" {
            guard let text = node.title ?? node.desc,
                  text.contains("\n"), text.contains("Now ") else { continue }
            let lines = text.components(separatedBy: "\n")
            guard lines.count >= 2, lines[1].hasPrefix("Now ") else { continue }
            let title = lines[0].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let host = text.firstMatch(of: #/Host: (.+?)(?: press|\n|$)/#).map { String($0.1) }
            return (title, host)
        }
        return nil
    }

    // MARK: helpers

    /// The run of nodes inside the first node matching `anchor` (depth-scoped).
    private static func subtree(of nodes: [AXNode], anchor: (AXNode) -> Bool) -> ArraySlice<AXNode> {
        guard let start = nodes.firstIndex(where: anchor) else { return [] }
        let depth = nodes[start].depth
        var end = start + 1
        while end < nodes.count, nodes[end].depth > depth { end += 1 }
        return nodes[(start + 1)..<end]
    }

    private static func parse(date: String, time: String, calendar: Calendar) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "MMMM d, yyyy H:mm"
        return fmt.date(from: "\(date) \(time)")
    }
}
