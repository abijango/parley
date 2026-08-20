import Foundation

/// Folds source snapshots into per-person history. No product policy (admission lives
/// in `AttendeePolicy`). Coverage contract:
/// - `.unreadable` → no-op
/// - `.sightings` → upsert listed people; never mark anyone left
/// - `.complete` → upsert; previously in-call people who are absent become `.left`
struct MeetingRoster: Equatable, Sendable {
    private(set) var people: [KnownPerson] = []
    private var index: [String: Int] = [:]
    private var sawReadableRoster = false

    var presentNow: [KnownPerson] { people.filter(\.isPresentNow) }
    var invited: [KnownPerson] { people.filter(\.presence.isInvited) }

    func person(named name: DisplayName) -> KnownPerson? {
        index[name.key].map { people[$0] }
    }

    mutating func apply(_ snapshot: RosterSnapshot) {
        guard snapshot.coverage != .unreadable else { return }
        let firstSighting = !sawReadableRoster
        sawReadableRoster = true
        for participant in snapshot.participants {
            upsert(participant, at: snapshot.observedAt, firstSighting: firstSighting)
        }
        if snapshot.coverage == .complete {
            markAbsentAsLeft(seen: snapshot.participants, at: snapshot.observedAt)
        }
    }

    mutating func record(_ decision: AttendeeDecision, for name: DisplayName) {
        guard let i = index[name.key] else { return }
        people[i].decision = decision
    }

    mutating func exclude(_ name: DisplayName) {
        record(.dismissed, for: name)
    }

    mutating func reset() {
        people = []
        index = [:]
        sawReadableRoster = false
    }

    /// Persistence projection for `SuggestedAttendee`. Only uncertain (not-yet-admitted)
    /// in-call names and dismissed chips. Invited-not-joined are not written.
    func persistedSuggestions() -> [SuggestedAttendee] {
        people.compactMap { person in
            guard let kind = person.uncertainKind else { return nil }
            let accepted: Bool
            let dismissed: Bool
            switch person.decision {
            case .admitted: accepted = true; dismissed = false
            case .dismissed: accepted = false; dismissed = true
            case .undecided: accepted = false; dismissed = false
            }
            let firstSeen: Date
            switch person.arrival {
            case .joined(let at): firstSeen = at
            case .presentBeforeFirstSight(let noticed): firstSeen = noticed
            case .neverObserved: firstSeen = Date()
            }
            return SuggestedAttendee(
                name: person.name.value,
                role: kind.caption,
                firstSeen: firstSeen,
                accepted: accepted,
                dismissed: dismissed)
        }
    }

    mutating func restore(from suggestions: [SuggestedAttendee]?) {
        reset()
        guard let suggestions else { return }
        for row in suggestions where !row.accepted {
            guard let name = DisplayName(raw: row.name) else { continue }
            let kind: UncertainKind = row.role == UncertainKind.room.caption ? .room : .device
            let person = KnownPerson(
                name: name,
                role: nil,
                presence: .inCall(.listedInCall),
                arrival: .presentBeforeFirstSight(noticedAt: row.firstSeen),
                lastSeenInCall: row.firstSeen,
                decision: row.dismissed ? .dismissed : .undecided,
                uncertainKind: kind)
            index[name.key] = people.count
            people.append(person)
        }
    }

    private mutating func upsert(_ participant: Participant, at date: Date, firstSighting: Bool) {
        if let i = index[participant.name.key] {
            var existing = people[i]
            if participant.presence.isInCall {
                if !existing.presence.isInCall {
                    existing.arrival = firstSighting
                        ? .presentBeforeFirstSight(noticedAt: date)
                        : .joined(at: date)
                }
                existing.presence = participant.presence
                existing.lastSeenInCall = date
            } else if case .invited = participant.presence, !existing.presence.isInCall {
                existing.presence = participant.presence
            }
            if existing.role == nil { existing.role = participant.role }
            people[i] = existing
            return
        }
        let arrival: Arrival
        if participant.presence.isInCall {
            arrival = firstSighting ? .presentBeforeFirstSight(noticedAt: date) : .joined(at: date)
        } else {
            arrival = .neverObserved
        }
        let kind = participant.presence.isInCall ? NameClassifier.kind(participant.name) : nil
        let person = KnownPerson(
            name: participant.name,
            role: participant.role,
            presence: participant.presence,
            arrival: arrival,
            lastSeenInCall: participant.presence.isInCall ? date : nil,
            decision: .undecided,
            uncertainKind: kind)
        index[participant.name.key] = people.count
        people.append(person)
    }

    private mutating func markAbsentAsLeft(seen: [Participant], at date: Date) {
        let presentKeys = Set(seen.filter(\.presence.isInCall).map(\.name.key))
        for i in people.indices {
            guard people[i].presence.isInCall, !presentKeys.contains(people[i].name.key) else { continue }
            people[i].presence = .left(at: date)
        }
    }
}

enum NameClassifier {
    static func kind(_ name: DisplayName) -> UncertainKind? {
        let t = name.value
        let lower = t.lowercased()
        if lower.contains("macbook") || lower.contains("iphone") || lower.contains("ipad")
            || lower.contains("imac") || lower.contains("’s mac") || lower.contains("'s mac") {
            return .device
        }
        if lower.contains("conference") || lower.contains("conf room")
            || lower.contains("meeting room") || lower.range(of: #"\broom\s+\d+"#, options: .regularExpression) != nil {
            return .room
        }
        return nil
    }

    static func isLikelyPerson(_ name: DisplayName) -> Bool {
        kind(name) == nil
    }
}

enum AttendeePolicy {
    /// In-call, person-like, still undecided. Safe to call every tick.
    static func admissions(in roster: MeetingRoster) -> [DisplayName] {
        roster.presentNow.compactMap { person in
            guard person.decision == .undecided, NameClassifier.isLikelyPerson(person.name) else { return nil }
            return person.name
        }
    }

    static func uncertainChips(in roster: MeetingRoster) -> [KnownPerson] {
        roster.presentNow.filter {
            $0.uncertainKind != nil && $0.decision == .undecided
        }
    }
}
