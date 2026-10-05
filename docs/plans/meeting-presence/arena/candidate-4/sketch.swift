import Foundation
import ApplicationServices

// MARK: - Module map
//
// Detection/   AXClient, MeetingParsers, MeetingMetadataResolver
//              Timer + AX I/O. Public output is MeetingSighting (no AX, no invited).
// Recording/   MeetingAdmission, MeetingSessionState, SessionManifest
//              Admission is the deep module: auto-admit, exclude, uncertain chips.
// UI/          UncertainChips binds pendingUncertain; TokenField binds attendees.
//
// Recording never imports AX types. Invited-not-joined never appear on MeetingSighting.
// Present people never appear as chips.

// =============================================================================
// Detection — public surface
// =============================================================================

/// Where a discovered title came from. Ranked: call-window outranks calendar/home
/// fallbacks. The resolver may overwrite a weaker title with a stronger one;
/// it does not lock on a calendar hit before the Teams call window settles.
enum TitleSource: String, Codable, Equatable, Comparable {
    case user
    case calendarOutlook
    case calendarTeams
    case zoomHome
    case callWindow

    var rank: Int {
        switch self {
        case .user: return 100
        case .callWindow: return 4
        case .zoomHome: return 3
        case .calendarTeams: return 2
        case .calendarOutlook: return 1
        }
    }

    static func < (lhs: TitleSource, rhs: TitleSource) -> Bool { lhs.rank < rhs.rank }
}

struct DiscoveredTitle: Equatable {
    let text: String
    let source: TitleSource
}

/// A conferencing-app label already comma-normalized and badge-stripped.
/// Identity is case-insensitive `text`. Construction is the storage boundary.
struct DisplayName: Hashable, Codable {
    let text: String
    var id: String { text.lowercased() }

    /// Returns nil for empty. Flips `"Last, First"`. Strips trailing Teams badges.
    /// Any remaining comma is replaced so `TranscriptWriter.splitAttendees` cannot
    /// split one person into two.
    static func parse(_ raw: String) -> DisplayName? {
        fatalError("not implemented")
    }
}

/// One AX roster tick. Empty pane-closed trees are `unobserved`, not `observed([])`.
/// `observed([])` means the roster chrome was readable and listed nobody — do not
/// wipe attendees. People who leave stay on the note.
enum PresentSnapshot: Equatable {
    case unobserved
    case observed([DisplayName])
}

/// Best-effort metadata for one resolver tick. Invited-not-joined are not a field.
struct MeetingSighting: Equatable {
    var title: DiscoveredTitle?
    var present: PresentSnapshot
}

// MARK: Parser-internal (not on the controller/UI surface)

/// Teams People-pane parse. `invited` exists so tests can assert Olga/Tetyana are
/// here and not in `present`. The resolver drops `invited` when building a sighting.
enum TeamsRosterParse: Equatable {
    /// No `AXOutline desc="Attendees"` in this walk (pane closed or English miss).
    case paneMissing
    case sectioned(present: [DisplayName], invited: [DisplayName])
}

enum MeetingParsers {
    static func teamsCallTitle(windowTitle: String) -> String? {
        fatalError("not implemented")
    }

    static func stripStatusBadges(_ name: String) -> String {
        fatalError("not implemented")
    }

    static func normalizeDisplayName(_ name: String) -> String {
        fatalError("not implemented")
    }

    /// Walks the Attendees outline and splits on section headers
    /// `"In this meeting, N total"` vs `"Others invited, N total"`.
    /// Rows before the first header are treated as present (legacy trees).
    /// Rows under `"Others invited"` never enter `present`.
    static func teamsAttendees(_ nodes: [AXNode]) -> TeamsRosterParse {
        fatalError("not implemented")
        // TODO: track current section while iterating AXRow; skip "N total" headers.
        // TODO: existing test that expects Tetyana/Olga as roster entries must flip:
        //       they are `invited`, and MeetingSighting.present must not contain them.
    }

    /// Tiles + Participants panel. Zoom has no invite-list section; every parsed
    /// name is present. Device labels ("Naufal's MacBook") stay present here —
    /// Admission classifies them as uncertain.
    static func zoomAttendees(_ nodes: [AXNode]) -> PresentSnapshot {
        fatalError("not implemented")
        // TODO: if neither tile TabGroups nor Participants outline exist → .unobserved
        // TODO: else .observed(unique DisplayName.parse)
    }

    /// Dump-driven later via tools/MeetingProbe. Do not invent selectors.
    static func webexCallTitle(windowTitle: String) -> String? {
        // TODO: ignore the generic messaging window titled exactly "Webex".
        return nil
    }

    static func webexAttendees(_ nodes: [AXNode]) -> PresentSnapshot {
        // TODO: fill from a live MeetingProbe dump. Until then: .unobserved
        return .unobserved
    }

    // Calendar helpers (outlookCalendarEvents, currentEvent, outlookNativeJoinableTitle,
    // zoomHomeNowTitle) stay as they are — title-only, never a presence source.
}

@MainActor
final class MeetingMetadataResolver {
    var onUpdate: ((MeetingSighting) -> Void)?
    var isPolling: Bool { fatalError("not implemented") }

    func start(for call: DetectedCall) {
        fatalError("not implemented")
        // TODO: AXClient.setMessagingTimeout on the call pid (and calendar pids).
        // TODO: titleLocked only when a callWindow title arrives, or titleGiveUpSeconds elapses.
        // TODO: a calendar/zoomHome title may be published, then replaced if callWindow appears.
        // TODO: always publish a sighting when present != .unobserved OR title != nil.
        //       Do not drop .observed([]) — Admission needs the distinction from .unobserved.
    }

    func enterPreviewMode() { fatalError("not implemented") }
    func stop() { fatalError("not implemented") }

    /// AX on `parley.meeting-ax`. Maps parser output to MeetingSighting.
    /// Webex (`cisco-systems.spark` / `Cisco-Systems.Spark`) is a branch that
    /// calls the stub parsers — not another `if isTeams` with guessed selectors.
    nonisolated static func scan(_ job: ScanJob) -> MeetingSighting {
        fatalError("not implemented")
        // TODO: Teams: teamsAttendees → drop invited → PresentSnapshot
        // TODO: Zoom: zoomAttendees
        // TODO: Webex: webexCallTitle / webexAttendees (stubs)
    }

    struct ScanJob: Sendable {
        let callBundleID: String
        let callPid: pid_t?
        let teamsPid: pid_t?
        let outlookPid: pid_t?
        let wantTitle: Bool
        let tryCalendar: Bool
        let wantRoster: Bool
    }
}

enum AXClient {
    static func isTrusted() -> Bool { fatalError("not implemented") }

    /// Must be called once per pid before walks. A wedged Teams/Webex tree must
    /// not leak `parley.meeting-ax` forever.
    static func setMessagingTimeout(pid: pid_t, seconds: Float = 2.0) {
        fatalError("not implemented")
        // TODO: AXUIElementSetMessagingTimeout(AXUIElementCreateApplication(pid), seconds)
    }

    static func enableElectronAX(pid: pid_t) { fatalError("not implemented") }
    static func windows(pid: pid_t) -> [AXUIElement] { fatalError("not implemented") }
    static func title(of element: AXUIElement) -> String? { fatalError("not implemented") }
    static func walk(_ root: AXUIElement, visitCap: Int = 20_000, maxDepth: Int = 40) -> [AXNode] {
        fatalError("not implemented")
    }
}

// `DetectedCall.known` remains "in the conferencing bundle list" (auto-record policy).
// Metadata capability is the resolver's bundle switch, which includes Webex stubs.
// Add `cisco-systems.spark` to AppSettings.defaultConferencingBundleIDs so Webex is
// known for auto-record; parsers can still yield nothing until a dump exists.

// =============================================================================
// Recording — admission (the deep module)
// =============================================================================

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

struct UncertainChip: Codable, Equatable, Identifiable {
    var display: DisplayName
    var kind: UncertainKind
    var dismissed: Bool
    var id: String { display.id }
}

/// Person vs room/device. Lives next to admission, not in each parser.
/// False-uncertain is recoverable (chip tap). False-person is recoverable
/// (token delete → exclusion). Prefer uncertain when the label looks like hardware.
enum NameClassifier {
    static func classify(_ name: DisplayName) -> Classified {
        fatalError("not implemented")
        // TODO: device if text matches MacBook/iPhone/iPad/iMac / "’s MacBook"
        // TODO: room if text matches Conference/Conf Room/Meeting Room / "Room <n>"
        // TODO: else .person
    }

    enum Classified: Equatable {
        case person(DisplayName)
        case uncertain(DisplayName, UncertainKind)
    }
}

/// Owns who is on the Record-tab attendees field because they were in the call.
/// Controller does not merge arrays. UI does not filter a bag.
@MainActor
final class MeetingAdmission {
    private unowned let meeting: MeetingSessionState
    /// Names the user removed this session. Next `ingest` will not put them back.
    /// Does not block `addRecognized` (speaker-ID) or a typed TokenField add.
    private var excluded: Set<String> = []
    /// Last TokenField contents, so `tokenFieldChanged` can diff removals
    /// without treating an `ingest` write as user intent to exclude newcomers.
    private var lastTokens: [String] = []

    init(meeting: MeetingSessionState) {
        fatalError("not implemented")
    }

    var excludedDisplayNames: [String] {
        fatalError("not implemented")
    }

    func reset() {
        fatalError("not implemented")
        // TODO: excluded.removeAll(); lastTokens = []; meeting.resetDiscovery()
    }

    /// Auto-admit newly observed people. No-op on `.unobserved`.
    /// Never removes a name because they left the snapshot.
    /// Never writes invited names (they are not on the sighting).
    func ingest(_ sighting: MeetingSighting) {
        fatalError("not implemented")
        // TODO: guard case .observed(let labels) = sighting.present else { return }
        // TODO: for each label, classify:
        //       .person → append to meeting.attendees unless excluded or already present
        //       .uncertain → upsert meeting.uncertainChips unless dismissed / already an attendee
        // TODO: lastTokens = split(meeting.attendees)
        // TODO: log first auto-admit per name; do not stamp a fake join time on chips
    }

    /// Inspector TokenField committed a new list (add / remove / reorder / clear).
    /// Names that disappeared become exclusions. Names that appeared stay
    /// (user-typed or ingest). Idempotent: same list twice is a no-op.
    func tokenFieldChanged(to names: [String]) {
        fatalError("not implemented")
        // TODO: parse each name through DisplayName.parse (drop empties)
        // TODO: for id in lastTokens.ids.subtracting(new.ids) { excluded.insert(id) }
        // TODO: meeting.attendees = joined new; lastTokens = new
    }

    /// Clear-all control. Excludes every current attendee so the next tick cannot refill.
    func clearAll() {
        fatalError("not implemented")
    }

    func admitUncertain(_ id: String) {
        fatalError("not implemented")
        // TODO: mark chip admitted (drop from pending), append to attendees, remove from excluded
    }

    func dismissUncertain(_ id: String) {
        fatalError("not implemented")
        // TODO: chip.dismissed = true; persist via heartbeat
    }

    /// Speaker-ID / history naming. Bypasses AX exclusion.
    func addRecognized(_ rawName: String) {
        fatalError("not implemented")
    }

    /// Crash resume. Old `suggestedAttendees` are not auto-admitted.
    func restore(from manifest: SessionManifest) {
        fatalError("not implemented")
        // TODO: meeting.attendees = manifest.attendees
        // TODO: excluded = Set((manifest.excludedAttendees ?? []).map { $0.lowercased() })
        // TODO: meeting.uncertainChips = manifest.uncertainChips ?? []
        // TODO: if let old = manifest.suggestedAttendees, uncertainChips empty:
        //         dismissed old rows → excluded
        //         leftover !accepted && !dismissed → UncertainChip(kind: .device) as conservative chips
        //         do NOT copy them into attendees
        // TODO: lastTokens = split(meeting.attendees)
    }
}

@MainActor
final class MeetingSessionState: ObservableObject {
    @Published var meetingTitle = ""
    @Published var destinationPath = ""
    @Published var attendees = ""
    @Published var manualNotes = ""
    @Published var attachments: [MeetingAttachment] = []

    /// Replaces `suggestedAttendees`. Only uncertain names. Present people are in `attendees`.
    @Published var uncertainChips: [UncertainChip] = []
    @Published var discoveredTitle: String?
    private(set) var discoveredTitleSource: String?
    var titleSource: String?
    var titleWasUserEdited = false

    var pendingUncertain: [UncertainChip] {
        uncertainChips.filter { !$0.dismissed }
    }

    func resetDiscovery() {
        fatalError("not implemented")
        // TODO: uncertainChips = []; discoveredTitle = nil; discoveredTitleSource = nil
        // TODO: titleWasUserEdited = false   // must reset with the session
    }

    func setDiscoveredTitle(_ title: String, source: String) {
        fatalError("not implemented")
    }

    func applyDiscoveredTitleIfAllowed(_ title: String, source: String) {
        fatalError("not implemented")
        // TODO: guard !titleWasUserEdited, isDefaultTitle(meetingTitle)
    }

    func isDefaultTitle(_ title: String) -> Bool {
        fatalError("not implemented")
    }
}

struct SessionManifest: Codable, Equatable {
    // … existing fields unchanged …

    var titleSource: String?

    /// Legacy bag. Optional forever so old files decode. Live path stops writing it.
    var suggestedAttendees: [SuggestedAttendee]?

    /// Names the user removed this session (AX will not re-admit).
    var excludedAttendees: [String]?

    /// Uncertain chips (including dismissed). Optional so old files decode.
    var uncertainChips: [UncertainChip]?
}

/// Kept only so `JSONDecoder` can read pre-admission manifests.
struct SuggestedAttendee: Codable, Equatable, Identifiable {
    var name: String
    var role: String?
    var firstSeen: Date
    var accepted = false
    var dismissed = false
    var id: String { name.lowercased() }
}

enum SessionStore {
    static func stamped(
        _ manifest: SessionManifest,
        status: SessionManifest.Status,
        title: String,
        attendees: String,
        filing: String,
        manualNotes: String,
        attachments: [MeetingAttachment]?,
        titleSource: String?,
        suggestedAttendees: [SuggestedAttendee]?,
        excludedAttendees: [String]?,
        uncertainChips: [UncertainChip]?,
        heartbeat: Date = Date()
    ) -> SessionManifest {
        fatalError("not implemented")
    }
}

// RecordingController keeps `admission: MeetingAdmission` next to `meeting`.
// Deleted methods: mergeRoster, acceptSuggestion, acceptAllSuggestions, dismissSuggestion.
// addAttendeeIfAbsent(raw) forwards to admission.addRecognized(raw).
// persistManifest / stampFinalizedManifest pass excludedAttendees + uncertainChips.
// onCallStart: meeting.resetDiscovery(); admission.reset(); titleWasUserEdited is inside resetDiscovery.
// clearForNextMeeting: admission.reset() after wiping the title/attendees fields.
