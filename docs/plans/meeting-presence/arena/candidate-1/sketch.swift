// Candidate A — Presence as a parse distinction
// Design sketch only. Do not compile into Parley.
//
// Module map (changes marked ★):
//
//   Parley/Detection/
//     MeetingPresence.swift          ★ NEW — domain presence types
//     MeetingParsers.swift           ★ parsers emit MeetingParticipant, not RosterEntry
//     MeetingMetadataResolver.swift  ★ DiscoveredMetadata.participants; AX timeout
//     AXClient.swift                 ★ setMessagingTimeout(pid:) at walk entry
//
//   Parley/Recording/
//     RecordingController.swift      ★ applyParticipantDiscovery replaces mergeRoster
//     SessionManifest.swift          ★ SuggestedAttendee.presence optional Codable
//     MeetingSessionState.swift      (no new fields; suggestions list unchanged)
//
//   Parley/UI/
//     SuggestionChips.swift          ★ pending filter by recommendationKind
//
//   ParleyTests/
//     MeetingParsersTests.swift      ★ presence-tagged fixtures; invited rows excluded from chips path

import Foundation

// MARK: - MeetingPresence.swift (NEW)

/// Whether AX placement classified this person as in-call, invite-only, or ambiguous.
enum ParticipantPresence: String, Codable, Equatable {
    case present   // "In this meeting" section, Zoom tile, participant panel row
    case invited   // Teams "Others invited" section only
    case unknown   // Could not classify (rooms, devices, parser gap)
}

/// One person discovered in a meeting roster, after name normalization, before
/// the controller stamps session state. Replaces flat `RosterEntry`.
struct MeetingParticipant: Equatable, Sendable {
    let name: String
    let role: String?          // "Organizer" / "Host" / …
    let presence: ParticipantPresence
}

extension MeetingParticipant {
    /// Comma-safe display name enforced at parse boundary.
    static func make(rawName: String, role: String?, presence: ParticipantPresence) -> MeetingParticipant? {
        let name = MeetingParsers.normalizeDisplayName(
            MeetingParsers.stripStatusBadges(rawName.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        guard !name.isEmpty, !name.contains(",") else { return nil }
        return MeetingParticipant(name: name, role: role, presence: presence)
    }
}

// MARK: - MeetingMetadataResolver.swift (DiscoveredMetadata change)

struct DiscoveredMetadata: Equatable {
    var title: String?
    var titleSource: String?       // "callWindow" | "calendar:teams" | "calendar:outlook" | "zoomHome"
    var participants: [MeetingParticipant] = []
}

@MainActor
final class MeetingMetadataResolver {
    var onUpdate: ((DiscoveredMetadata) -> Void)?
    var isPolling: Bool { fatalError("not implemented") }

    func start(for call: DetectedCall) { fatalError("not implemented") }
    func enterPreviewMode() { fatalError("not implemented") }
    func stop() { fatalError("not implemented") }

    private nonisolated static func scan(_ job: ScanJob) -> DiscoveredMetadata {
        var result = DiscoveredMetadata()
        let isTeamsCall = job.callBundleID.hasPrefix("com.microsoft.teams")
        let isZoomCall = job.callBundleID == "us.zoom.xos"
        let isWebexCall = job.callBundleID.lowercased() == "cisco-systems.spark"

        // Title paths unchanged from today (call window → rationed calendar → give up).
        // TODO: existing teamsCallTitle / zoomHomeNowTitle / outlook calendar branches

        if job.wantRoster, let pid = job.callPid {
            AXClient.setMessagingTimeout(forProcess: pid, seconds: 3)

            if isTeamsCall {
                ensureElectronAX(pid: pid)
                let nodes = walkCallWindows(pid: pid) {
                    MeetingParsers.teamsCallTitle(windowTitle: $0) != nil
                }
                result.participants = MeetingParsers.teamsParticipants(nodes)
            } else if isZoomCall {
                let nodes = walkCallWindows(pid: pid) { $0 == "Zoom Meeting" }
                result.participants = MeetingParsers.zoomParticipants(nodes)
            } else if isWebexCall {
                let nodes = walkCallWindows(pid: pid) { _ in true } // title predicate TBD from MeetingProbe dump
                result.participants = MeetingParsers.webexParticipants(nodes)
            }
        }

        return result
    }

    // ScanJob, tickFired, titleLocked, calendarTicks — bodies unchanged.
    private struct ScanJob: Sendable {
        let callBundleID: String
        let callPid: pid_t?
        let teamsPid: pid_t?
        let outlookPid: pid_t?
        let wantTitle: Bool
        let tryCalendar: Bool
        let wantRoster: Bool
    }

    private nonisolated static var electronEnabled = Set<pid_t>()
    private nonisolated static func ensureElectronAX(pid: pid_t) { fatalError("not implemented") }
    private nonisolated static func walkCallWindows(pid: pid_t, titleMatches: (String) -> Bool) -> [AXNode] {
        fatalError("not implemented")
    }
}

// MARK: - MeetingParsers.swift (presence-aware parsers)

enum MeetingParsers {

    static let teamsNavViews: Set<String> = [
        "Microsoft Teams", "Calendar", "Chat", "Activity", "Teams", "Calls",
        "OneDrive", "Apps", "Files", "Copilot",
    ]

    static func teamsCallTitle(windowTitle: String) -> String? { fatalError("not implemented") }
    static func stripStatusBadges(_ name: String) -> String { fatalError("not implemented") }
    static func normalizeDisplayName(_ name: String) -> String { fatalError("not implemented") }

    /// Teams People pane: section headers set presence for subsequent rows.
    /// "In this meeting, N total" → .present
    /// "Others invited, N total"   → .invited (rows tagged but never recommended downstream)
    static func teamsParticipants(_ nodes: [AXNode]) -> [MeetingParticipant] {
        let roles: Set<String> = ["Organizer", "Co-organizer", "Presenter", "Attendee", "Guest", "External", "Host"]
        let slice = subtree(of: nodes, anchor: { $0.role == "AXOutline" && $0.desc == "Attendees" })
        var participants: [MeetingParticipant] = []
        var seen = Set<String>()
        var sectionPresence: ParticipantPresence = .present // rows before first header default present

        var i = slice.startIndex
        while i < slice.endIndex {
            let row = nodes[i]
            guard row.role == "AXRow" else { i += 1; continue }
            let rowDepth = row.depth
            let title = row.title ?? row.desc ?? ""

            if title.range(of: #"\d+\s+total"#, options: .regularExpression) != nil {
                if title.lowercased().contains("others invited") {
                    sectionPresence = .invited
                } else if title.lowercased().contains("in this meeting") {
                    sectionPresence = .present
                }
                i += 1
                continue
            }

            var j = i + 1
            var name: String?
            var role: String?
            while j < slice.endIndex, nodes[j].depth > rowDepth {
                let d = nodes[j]
                if d.role == "AXStaticText", let v = d.value, !v.isEmpty {
                    if name == nil { name = v }
                    else if role == nil, roles.contains(v) { role = v }
                }
                j += 1
            }

            let parts = title.components(separatedBy: ", ").filter { $0 != "Has context menu" }
            if name == nil { name = parts.first }
            if role == nil { role = parts.dropFirst().first(where: roles.contains) }

            if let raw = name,
               let participant = MeetingParticipant.make(rawName: raw, role: role, presence: sectionPresence),
               seen.insert(participant.name.lowercased()).inserted {
                participants.append(participant)
            }
            i = j
        }
        return participants
    }

    /// Zoom: speaker tiles and participant panel rows are all in-call.
    /// Dedup by name; prefer panel role when both tile and panel exist.
    static func zoomParticipants(_ nodes: [AXNode]) -> [MeetingParticipant] {
        fatalError("not implemented")
        // TODO: tile desc "<name>, Computer audio …" → .present
        // TODO: panel "Participants list" static texts → .present with parsed role
    }

    /// Webex: dump-driven. Returns [] until MeetingProbe capture defines anchors.
    static func webexParticipants(_ nodes: [AXNode]) -> [MeetingParticipant] {
        fatalError("not implemented")
    }

    // Calendar helpers unchanged
    static func outlookCalendarEvents(_ nodes: [AXNode]) -> [CalendarEvent] { fatalError("not implemented") }
    static func currentEvent(in events: [CalendarEvent]) -> CalendarEvent? { fatalError("not implemented") }

    // Private AXNode helpers unchanged
    private static func subtree(of nodes: [AXNode], anchor: (AXNode) -> Bool) -> ArraySlice<AXNode> {
        fatalError("not implemented")
    }
}

// MARK: - AXClient.swift (timeout at boundary)

enum AXClient {
    /// Call before any walk on `pid` so wedged Electron trees release the queue.
    static func setMessagingTimeout(forProcess pid: pid_t, seconds: Float) {
        fatalError("not implemented")
        // TODO: apply AXUIElementSetMessagingTimeout to app + window elements
    }

    static func windows(pid: pid_t) -> [AXUIElement] { fatalError("not implemented") }
    static func walk(_ root: AXUIElement) -> [AXNode] { fatalError("not implemented") }
    static func title(of element: AXUIElement) -> String? { fatalError("not implemented") }
    static func enableElectronAX(pid: pid_t) { fatalError("not implemented") }
    static func isTrusted() -> Bool { fatalError("not implemented") }
}

// MARK: - SessionManifest.swift (backward-compatible presence)

struct SuggestedAttendee: Codable, Equatable, Identifiable {
    var name: String
    var role: String?
    var firstSeen: Date
    var accepted = false
    var dismissed = false
    var presence: ParticipantPresence?   // nil ⇒ legacy manifest → treat as .unknown in UI

    var id: String { name.lowercased() }

    /// What the Record tab needs to decide chip visibility.
    var recommendationKind: RecommendationKind {
        switch presence ?? .unknown {
        case .present:  return .alreadyAdmitted
        case .invited:  return .suppressed       // should never be stored after applyParticipantDiscovery
        case .unknown:  return .needsConfirmation
        }
    }
}

enum RecommendationKind: Equatable {
    case alreadyAdmitted
    case needsConfirmation
    case suppressed
}

// MARK: - RecordingController.swift (thin policy)

extension RecordingController {

    func applyParticipantDiscovery(_ participants: [MeetingParticipant]) {
        for person in participants {
            switch person.presence {
            case .present:
                addAttendeeIfAbsent(person.name)
                upsertSuggestion(
                    name: person.name,
                    role: person.role,
                    presence: .present,
                    markAccepted: true
                )

            case .invited:
                continue

            case .unknown:
                upsertSuggestion(
                    name: person.name,
                    role: person.role,
                    presence: .unknown,
                    markAccepted: false
                )
            }
        }
    }

    private func upsertSuggestion(
        name: String,
        role: String?,
        presence: ParticipantPresence,
        markAccepted: Bool
    ) {
        fatalError("not implemented")
        // TODO: union by case-insensitive name; stamp firstSeen once; backfill role;
        //       set presence; if markAccepted { accepted = true; addAttendeeIfAbsent }
    }

    private func addAttendeeIfAbsent(_ rawName: String) { fatalError("not implemented") }
}

// MARK: - SuggestionChips.swift (thin filter)

// pending computed property:
//   meeting.suggestedAttendees.filter { $0.recommendationKind == .needsConfirmation && !$0.dismissed }

// MARK: - Stubs for sketch completeness

struct DetectedCall: Equatable {
    let pid: pid_t
    let bundleID: String
    let displayName: String
    let known: Bool
}

struct AXNode: Equatable {
    var role: String = ""
    var desc: String?
    var title: String?
    var value: String?
    var depth: Int = 0
}

struct CalendarEvent: Equatable {
    var title: String
    var organizer: String?
}

typealias AXUIElement = OpaquePointer
typealias pid_t = Int32
