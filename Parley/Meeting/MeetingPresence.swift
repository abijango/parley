import Foundation

/// Comma-free display name. Attendees are stored comma-delimited, so a comma in a
/// name would split one person into two. Construction is the only validation point.
struct DisplayName: Hashable, Sendable, Comparable {
    let value: String

    var key: String { value.lowercased() }

    /// Badge-strip, flip `"Last, First"` when unambiguous, reject empty or leftover commas.
    init?(raw: String) {
        var name = MeetingParsers.normalizeDisplayName(
            MeetingParsers.stripStatusBadges(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(",") else { return nil }
        value = name
    }

    static func < (lhs: DisplayName, rhs: DisplayName) -> Bool {
        lhs.value.localizedCaseInsensitiveCompare(rhs.value) == .orderedAscending
    }
}

enum PresenceEvidence: String, Equatable, Sendable, Codable {
    case participantTile
    case listedInCall
}

enum InviteResponse: String, Equatable, Sendable, Codable {
    case accepted, tentative, declined, noResponse

    static func parse(_ raw: String) -> InviteResponse? {
        switch raw.lowercased() {
        case "accepted": return .accepted
        case "tentative": return .tentative
        case "declined": return .declined
        default: return nil
        }
    }
}

enum Presence: Equatable, Sendable {
    case inCall(PresenceEvidence)
    case left(at: Date)
    case invited(InviteResponse?)

    var isInCall: Bool {
        if case .inCall = self { return true }
        return false
    }

    var isInvited: Bool {
        if case .invited = self { return true }
        return false
    }
}

enum MeetingRole: String, Equatable, Sendable, Codable {
    case organizer, coOrganizer, presenter, host, coHost, guest, attendee

    static func parse(_ raw: String?) -> MeetingRole? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "organizer": return .organizer
        case "co-organizer", "coorganizer": return .coOrganizer
        case "presenter": return .presenter
        case "host": return .host
        case "co-host", "cohost": return .coHost
        case "guest": return .guest
        case "attendee": return .attendee
        default: return nil
        }
    }

    var display: String {
        switch self {
        case .organizer: return "Organizer"
        case .coOrganizer: return "Co-organizer"
        case .presenter: return "Presenter"
        case .host: return "Host"
        case .coHost: return "Co-host"
        case .guest: return "Guest"
        case .attendee: return "Attendee"
        }
    }
}

struct Participant: Equatable, Sendable {
    let name: DisplayName
    let presence: Presence
    let role: MeetingRole?
}

enum RosterCoverage: Equatable, Sendable {
    /// Pane closed, tree missing, truncated walk, or no trust. Absence proves nothing.
    case unreadable
    /// Partial (Zoom tiles). Additive only — never mark someone as left.
    case sightings
    /// Full participant surface. Absence of a previously in-call name means they left.
    case complete
}

struct RosterSnapshot: Equatable, Sendable {
    let observedAt: Date
    let coverage: RosterCoverage
    let isFirstSighting: Bool
    let participants: [Participant]

    static func unreadable(at date: Date) -> RosterSnapshot {
        RosterSnapshot(observedAt: date, coverage: .unreadable, isFirstSighting: false, participants: [])
    }
}

enum TitleAuthority: Int, Comparable, Sendable {
    case scheduleOverlap = 1
    case appContext = 2
    case callWindow = 3

    static func < (l: TitleAuthority, r: TitleAuthority) -> Bool { l.rawValue < r.rawValue }
}

struct TitleCandidate: Equatable, Sendable {
    let title: String
    let authority: TitleAuthority
    let provenance: String
}

enum Arrival: Equatable, Sendable {
    case joined(at: Date)
    case presentBeforeFirstSight(noticedAt: Date)
    case neverObserved
}

enum AttendeeDecision: Equatable, Sendable {
    case undecided
    case admitted(Admission)
    case dismissed

    enum Admission: String, Equatable, Sendable, Codable { case automatic, user }
}

enum UncertainKind: String, Codable, Equatable {
    case room
    case device

    var caption: String {
        switch self {
        case .room: return "Room"
        case .device: return "Device"
        }
    }
}

struct KnownPerson: Equatable, Identifiable, Sendable {
    let name: DisplayName
    var role: MeetingRole?
    var presence: Presence
    var arrival: Arrival
    var lastSeenInCall: Date?
    var decision: AttendeeDecision
    var uncertainKind: UncertainKind?

    var id: String { name.key }

    var isPresentNow: Bool { presence.isInCall }
}
