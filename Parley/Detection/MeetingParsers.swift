import Foundation

/// A person discovered in a meeting roster (name + optional role), before the
/// resolver stamps it with a first-seen time.
struct RosterEntry: Equatable {
    let name: String
    let role: String?   // "Organizer" / "Host" / …
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

    /// Parses a Teams window title of the call-window form
    /// `<meeting title> | <org> | <account> | Microsoft Teams`.
    /// Returns nil for main-window/nav titles and for the generic
    /// `"Microsoft Teams"` a freshly-opened call window carries before its real
    /// title settles (caller should keep polling). The meeting title may itself
    /// contain " | ", so only the trailing three segments are stripped.
    static func teamsCallTitle(windowTitle: String) -> String? {
        let segments = windowTitle.components(separatedBy: " | ")
        guard segments.count >= 4, segments.last == "Microsoft Teams" else { return nil }
        // Main-window titles lead with a nav view ("Calendar | <selected event> |
        // …"), so the nav check must look at the FIRST segment, not the joined
        // title — a meeting name may legitimately contain " | ".
        let first = segments[0].trimmingCharacters(in: .whitespaces)
        guard !teamsNavViews.contains(first) else { return nil }
        let title = segments.dropLast(3).joined(separator: " | ")
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    // MARK: Teams roster (People pane open)

    /// Rows under `AXOutline desc="Attendees"`, e.g.
    /// `"Naufal Mir, Has context menu, Organizer, Muted"`. Section headers
    /// ("In this meeting, 1 total") carry no "Has context menu" and are skipped.
    static func teamsAttendees(_ nodes: [AXNode]) -> [RosterEntry] {
        let roles: Set<String> = ["Organizer", "Presenter", "Attendee", "Guest", "External"]
        var entries: [RosterEntry] = []
        for row in subtree(of: nodes, anchor: { $0.role == "AXOutline" && $0.desc == "Attendees" })
        where row.role == "AXRow" {
            guard let text = row.title ?? row.desc else { continue }
            let parts = text.components(separatedBy: ", ")
            guard let menuIdx = parts.firstIndex(of: "Has context menu"), menuIdx > 0 else { continue }
            // Names containing ", " keep their commas: everything before the marker.
            let name = parts[..<menuIdx].joined(separator: ", ")
            let role = parts[(menuIdx + 1)...].first(where: roles.contains)
            entries.append(RosterEntry(name: name, role: role))
        }
        return entries
    }

    // MARK: Zoom roster

    /// Two sources, both observed live:
    /// - active-speaker tile (no panel needed): `AXTabGroup` desc
    ///   `"Naufal Mir, Computer audio unmuted"`
    /// - Participants panel: statics under `AXOutline desc="Participants list"`,
    ///   `"Naufal Mir (Host, me)"`.
    static func zoomAttendees(_ nodes: [AXNode]) -> [RosterEntry] {
        var entries: [RosterEntry] = []

        for node in nodes where node.role == "AXTabGroup" {
            guard let desc = node.desc,
                  let range = desc.range(of: ", Computer audio") else { continue }
            entries.append(RosterEntry(name: String(desc[..<range.lowerBound]), role: nil))
        }

        for node in subtree(of: nodes, anchor: { $0.role == "AXOutline" && $0.desc == "Participants list" })
        where node.role == "AXStaticText" {
            guard let value = node.value else { continue }
            if let parenIdx = value.range(of: " (", options: .backwards), value.hasSuffix(")") {
                let name = String(value[..<parenIdx.lowerBound])
                let inParens = value[parenIdx.upperBound...].dropLast()
                let role = inParens.components(separatedBy: ", ")
                    .first { $0 == "Host" || $0 == "Co-host" }
                entries.append(RosterEntry(name: name, role: role))
            } else {
                entries.append(RosterEntry(name: value, role: nil))
            }
        }
        return entries
    }

    // MARK: Calendar lookups

    struct CalendarEvent: Equatable {
        let title: String
        let start: Date?
        let end: Date?
        let organizer: String?
    }

    /// Events from the Teams Calendar tab (an embedded Outlook web view), e.g.
    /// `"Wickes Workshop, 09:00 to 11:00, Monday, June 01, 2026, By Alexander
    /// Kulinchenko, Tentative"`. Titles can contain commas, so parsing anchors
    /// on the `, HH:MM to HH:MM, ` time pattern — never naive comma-splitting.
    /// `Canceled:` events and all-day events (no time anchor) are skipped.
    static func outlookCalendarEvents(_ nodes: [AXNode], calendar: Calendar = .current) -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        for node in nodes where node.role == "AXButton" {
            guard let desc = node.desc, !desc.hasPrefix("Canceled:"),
                  let match = desc.firstMatch(of: timeAnchor) else { continue }
            let title = String(desc[..<match.range.lowerBound])
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
            events.append(CalendarEvent(title: title, start: start, end: end, organizer: organizer))
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

    /// Native Outlook Calendar view: events are title-only buttons grouped by
    /// day, and the *currently joinable* one carries a child "Join" button —
    /// that child is the "this meeting is happening now" marker.
    static func outlookNativeJoinableTitle(_ nodes: [AXNode]) -> String? {
        for (i, node) in nodes.enumerated() where node.role == "AXButton" && node.desc != nil {
            for next in nodes.dropFirst(i + 1) {
                if next.depth <= node.depth { break }
                if next.role == "AXButton" && next.desc == "Join" {
                    return node.desc
                }
            }
        }
        return nil
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

    /// `", HH:MM to HH:MM, "` — the structural anchor for Outlook-web event
    /// descriptions (capture groups: start time, end time).
    private static let timeAnchor = #/, (\d{1,2}:\d{2}) to (\d{1,2}:\d{2}), /#

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
