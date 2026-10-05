import Foundation

// MARK: - Module map

// Detection/MeetingMetadataResolver.swift
//   Main-actor lifecycle and a background AX scan. Resolves title authority,
//   emits every completed scan as MeetingMetadataSnapshot, and never gates
//   recording. It does not retain person history or recommendation state.
//
// Detection/MeetingParsers.swift
//   AXNode -> domain snapshot boundary. Teams parsing preserves the
//   "In this meeting" / "Others invited" distinction. Zoom distinguishes a
//   complete Participants panel from partial visible tiles. Webex remains an
//   unimplemented, dump-driven parser.
//
// Detection/AXClient.swift
//   AX-only implementation detail. Every application element receives a
//   messaging timeout; every walk also has a visit, depth, and wall-clock budget.
//
// Detection/CallDetector.swift + Settings/AppSettings.swift
//   Webex bundle recognition/display policy. "Known for recording" remains
//   independent from whether a metadata parser exists.
//
// Meeting/PresenceLedger.swift
//   Pure, main-actor-owned value type. Owns first observation, present-now
//   evidence, recommendation decisions, accepted order, and admission policy.
//
// Meeting/PresenceManifestAdapter.swift
//   Storage boundary. Persists StoredState and migrates legacy
//   SessionManifest.suggestedAttendees only when StoredState is absent.
//
// Recording/MeetingSessionState.swift
//   Publishes PresenceLedger.View. The legacy attendee string is a derived
//   adapter until transcript/storage call sites accept [PersonName].
//
// UI/SuggestionChips.swift
//   Renders View.recommendations. It contains no presence or invite filtering.

// MARK: - Validated identity

/// A display name accepted by the meeting domain.
///
/// Invariants:
/// - trimmed and non-empty;
/// - status badges removed at the parser boundary;
/// - "Last, First" normalized when unambiguous;
/// - contains no comma, because current durable attendee storage is comma-delimited.
struct PersonName: Hashable, Codable, Sendable {
    let displayName: String

    init?(_ rawValue: String) {
        fatalError("not implemented")
    }

    var id: ParticipantID {
        fatalError("not implemented")
    }
}

/// Name-derived identity is the strongest stable identity exposed by current AX
/// trees. Construction is internal to PersonName.
struct ParticipantID: Hashable, Codable, Sendable, Identifiable {
    let rawValue: String
    var id: String { fatalError("not implemented") }
}

struct ParticipantRole: Hashable, Codable, Sendable {
    let value: String

    init?(_ rawValue: String?) {
        fatalError("not implemented")
    }
}

// MARK: - Resolver output

struct MeetingMetadataSnapshot: Equatable, Sendable {
    /// Also advances partial-observation leases when title and roster are nil.
    let observedAt: Date
    let title: TitleCandidate?
    /// nil = no roster surface recognized; non-nil empty = an observed empty roster.
    let roster: RosterSnapshot?
}

struct TitleCandidate: Equatable, Sendable {
    let value: String
    let source: TitleSource
}

/// Authority is internal to the resolver. Callers receive only the best candidate
/// so a rendered-calendar fallback cannot permanently lock out a settled call title.
enum TitleSource: String, Codable, Sendable {
    case teamsCallWindow
    case zoomHome
    case teamsRenderedCalendar
    case outlookRenderedCalendar
    case webexCallWindow

    var manifestValue: String {
        fatalError("not implemented")
    }
}

/// Scope encodes what an absent name means. Only `.complete` may prove that a
/// previously present person is no longer present.
enum RosterScope: Hashable, Codable, Sendable {
    case complete(CompleteRosterSurface)
    case partial(PartialRosterSurface)
}

enum CompleteRosterSurface: String, Hashable, Codable, Sendable {
    case teamsPeoplePane
    case zoomParticipantsPanel
    /// Reserved shape only. No Webex parser is written before a MeetingProbe dump.
    case webexParticipantList
}

enum PartialRosterSurface: String, Hashable, Codable, Sendable {
    case zoomVisibleTiles
    /// Reserved shape only. No Webex parser is written before a MeetingProbe dump.
    case webexVisibleParticipants
}

/// A source-level snapshot already separated by meaning. AXNode, section labels,
/// application pids, and English anchors do not cross this boundary.
struct RosterSnapshot: Equatable, Sendable {
    let scope: RosterScope
    let confirmedPresent: [ConfirmedPresentPerson]
    let ambiguousPresent: [AmbiguousPresentEntity]
    let invitedOnly: [InvitedPerson]
}

struct ConfirmedPresentPerson: Equatable, Sendable {
    let person: PersonName
    let role: ParticipantRole?
}

/// An in-call label that may be a room, device, dial-in endpoint, or malformed
/// person name. It is recommendation evidence, never automatic acceptance.
struct AmbiguousPresentEntity: Equatable, Sendable {
    let person: PersonName
    let role: ParticipantRole?
    let reason: AmbiguityReason
}

enum AmbiguityReason: String, Codable, Sendable {
    case roomOrDevice
    case endpointLabel
    case lowConfidenceName
}

/// Invite evidence is deliberately not presence evidence.
struct InvitedPerson: Equatable, Sendable {
    let person: PersonName
    let response: InviteResponse?
}

struct InviteResponse: Hashable, Codable, Sendable {
    let value: String
}

// MARK: - Presence ledger

struct PresenceLedger {
    /// Last resolver heartbeat applied. Views are deterministic at this clock;
    /// replay and restore never consult ambient Date().
    private var clock: Date

    // Dominant lookups are O(1) by name-derived ID. Order is stored separately
    // because accepted attendee order is user-visible and durable.
    private var recordsByID: [ParticipantID: Record]
    private var acceptedOrder: [ParticipantID]

    // Complete membership supports set replacement and explicit departures.
    private var completeObservations: [CompleteRosterSurface: CompleteObservation]

    // Partial observations are leases. Their expiry returns presence to unknown;
    // it does not claim the person left.
    private var partialLeases: [PartialRosterSurface: [ParticipantID: PartialLease]]

    init() {
        fatalError("not implemented")
    }

    init(restoring state: StoredState) {
        fatalError("not implemented")
    }

    var view: View {
        fatalError("not implemented")
    }

    var storedState: StoredState {
        fatalError("not implemented")
    }

    /// The sole state transition entry point. Every command is idempotent:
    /// replaying a roster snapshot or user intent produces the same durable state.
    mutating func apply(_ command: Command) -> Change {
        fatalError("not implemented")
    }

    enum Command: Sendable {
        /// A nil roster advances partial leases but does not prove anyone absent.
        case observe(RosterSnapshot?, at: Date)
        case accept(ParticipantID, origin: ExternalAcceptanceOrigin)
        case acceptName(PersonName, origin: ExternalAcceptanceOrigin)
        case dismissRecommendation(ParticipantID)
        case acceptAllRecommendations
        /// The token field is authoritative for manual replacement and ordering.
        /// Removing an automatically accepted name suppresses re-admission on the
        /// next identical poll.
        case replaceAccepted([PersonName], origin: ExternalAcceptanceOrigin)
        case reset
    }

    enum ExternalAcceptanceOrigin: String, Codable, Sendable {
        case user
        case manualEdit
        case speakerIdentification
    }

    struct Change: Equatable, Sendable {
        let view: View
        let acceptedChanged: Bool
        let durableStateChanged: Bool
    }

    struct View: Equatable, Sendable {
        static var empty: View {
            fatalError("not implemented")
        }

        let presentNow: [PersonView]
        let recommendations: [Recommendation]
        let accepted: AcceptedAttendees
        /// Invite-only identities stay out of recommendation UI by default.
        let inviteOnlyCount: Int
        /// Stable post-call history for preview and speaker assignment.
        let observedPeople: [PersonView]
    }

    struct PersonView: Equatable, Identifiable, Sendable {
        let id: ParticipantID
        let person: PersonName
        let role: ParticipantRole?
        /// First AX observation of any kind, not a claimed join time.
        let firstObservedAt: Date?
        let firstPresentObservedAt: Date?
        let presence: PresenceNow
        let isAccepted: Bool
    }

    enum PresenceNow: Equatable, Codable, Sendable {
        case present(lastObservedAt: Date)
        case notPresent(lastCompleteObservationAt: Date)
        case unknown
    }

    struct Recommendation: Equatable, Identifiable, Sendable {
        let id: ParticipantID
        let person: PersonName
        let role: ParticipantRole?
        let firstObservedAt: Date
        let reason: RecommendationReason
    }

    enum RecommendationReason: String, Codable, Sendable {
        case ambiguousInCallEntity
        case legacySuggestion
    }

    struct AcceptedAttendees: Equatable, Codable, Sendable {
        let names: [PersonName]

        var commaDelimited: String {
            fatalError("not implemented")
        }
    }

    /// Versioned domain persistence. This is not the AX snapshot format.
    struct StoredState: Equatable, Codable, Sendable {
        let version: Int
        let clock: Date
        let records: [StoredRecord]
        let acceptedOrder: [ParticipantID]
        let completeObservations: [CompleteObservation]
        let partialLeases: [PartialLease]
    }

    struct StoredRecord: Equatable, Codable, Sendable {
        let id: ParticipantID
        let person: PersonName
        let role: ParticipantRole?
        let firstObservedAt: Date?
        let firstPresentObservedAt: Date?
        let decision: StoredDecision
        let inviteResponse: InviteResponse?
    }

    struct CompleteObservation: Equatable, Codable, Sendable {
        let source: CompleteRosterSurface
        let observedAt: Date
        let members: Set<ParticipantID>
    }

    struct PartialLease: Equatable, Codable, Sendable {
        let source: PartialRosterSurface
        let participantID: ParticipantID
        let lastObservedAt: Date
        let expiresAt: Date
    }

    enum StoredDecision: Equatable, Codable, Sendable {
        case undecided
        case recommended(RecommendationReason)
        case accepted(Acceptance)
        case suppressed(SuppressionReason)
    }

    struct Acceptance: Equatable, Codable, Sendable {
        let origin: AcceptanceOrigin
        let acceptedAt: Date
    }

    enum AcceptanceOrigin: String, Codable, Sendable {
        case automaticConfirmedPresence
        case user
        case manualEdit
        case speakerIdentification
        case legacyRestore
    }

    enum SuppressionReason: String, Codable, Sendable {
        case recommendationDismissed
        case manuallyRemoved
    }

    private struct Record {
        var person: PersonName
        var role: ParticipantRole?
        var firstObservedAt: Date?
        var firstPresentObservedAt: Date?
        var decision: StoredDecision
        var inviteResponse: InviteResponse?
    }

    // Policy is intentionally not a caller option. Confirmed presence auto-admits;
    // ambiguity recommends; invite-only evidence remains undecided; suppression
    // wins over repeated observations.
    private static func nextDecision(
        current: StoredDecision,
        evidence: EvidenceKind,
        at: Date
    ) -> StoredDecision {
        fatalError("not implemented")
    }

    private enum EvidenceKind {
        case confirmedPresent
        case ambiguousPresent
        case invitedOnly
    }

    private static let partialObservationTTL: TimeInterval = 12
}

// MARK: - Resolver and parser signatures

@MainActor
final class MeetingMetadataResolver {
    var onUpdate: ((MeetingMetadataSnapshot) -> Void)?
    var isPolling: Bool { fatalError("not implemented") }

    func start(for call: DetectedCall) {
        fatalError("not implemented")
    }

    func enterPreviewMode() {
        fatalError("not implemented")
    }

    func stop() {
        fatalError("not implemented")
    }

    // TODO: keep a generation token so late scans from a stopped or replaced call
    // are discarded. Emit a heartbeat snapshot on every timer tick, including
    // missing trust/parse misses. Rank title candidates instead of locking the
    // first non-nil fallback.
}

extension MeetingParsers {
    /// Returns nil when the Teams People roster is not rendered. When rendered,
    /// returns `.complete(.teamsPeoplePane)` even if both sections are empty.
    static func teamsRosterSnapshot(_ nodes: [AXNode]) -> RosterSnapshot? {
        fatalError("not implemented")
    }

    /// Prefer `.complete(.zoomParticipantsPanel)` when the panel is observed;
    /// otherwise return `.partial(.zoomVisibleTiles)` for visible speaker tiles.
    static func zoomRosterSnapshot(_ nodes: [AXNode]) -> RosterSnapshot? {
        fatalError("not implemented")
    }

    /// No selectors or anchors are specified until a live MeetingProbe dump exists.
    static func webexRosterSnapshot(_ nodes: [AXNode]) -> RosterSnapshot? {
        fatalError("not implemented")
    }
}

private struct AXScanLimits: Sendable {
    let messageTimeout: TimeInterval
    let totalScanTimeout: TimeInterval
    let visitCap: Int
    let maxDepth: Int

    static var meetingMetadata: AXScanLimits {
        fatalError("not implemented")
    }
}

extension AXClient {
    /// Calls AXUIElementSetMessagingTimeout on each application element before
    /// reads. The walk also checks the total scan deadline between nodes.
    static func boundedWalk(pid: pid_t, limits: AXScanLimits) -> [AXNode] {
        fatalError("not implemented")
    }
}

// MARK: - Manifest boundary

// SessionManifest adds:
//     var presenceLedger: PresenceLedger.StoredState?
//
// The property is optional and decoded with decodeIfPresent, so old session.json
// files remain valid. Existing suggestedAttendees also remains optional.

enum PresenceManifestAdapter {
    /// New state wins. Otherwise migrate manifest.attendees plus optional legacy
    /// SuggestedAttendee values into validated domain records.
    static func restore(from manifest: SessionManifest) -> PresenceLedger {
        fatalError("not implemented")
    }

    /// Writes attendees from ledger.view.accepted, writes storedState, and clears
    /// the legacy suggestions field on new manifests.
    static func stamp(_ ledger: PresenceLedger, into manifest: inout SessionManifest) {
        fatalError("not implemented")
    }
}
