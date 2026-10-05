//
//  Candidate 3 — Per-app MeetingSource
//  Type sketch. Bodies are `fatalError("not implemented")` or `// TODO`.
//  Derived from usage.md; where the two disagree, usage.md wins.
//
//  MODULE MAP
//  ──────────────────────────────────────────────────────────────────────────
//  Parley/Meeting/MeetingPresence.swift   NEW   DisplayName, Presence, Participant,
//                                               RosterSnapshot, TitleCandidate. The whole
//                                               vocabulary that crosses out of Detection.
//  Parley/Meeting/MeetingRoster.swift     NEW   The fold: snapshots → KnownPerson list,
//                                               arrival, decisions, manifest projection.
//  Parley/Meeting/AttendeePolicy.swift    NEW   Pure policy. Who is auto-admitted, who is a chip.
//
//  Parley/Detection/MeetingSource.swift   NEW   MeetingSource protocol, SourceIdentity,
//                                               ScanContext, SourceReading, registry.
//  Parley/Detection/Sources/TeamsSource.swift  NEW
//  Parley/Detection/Sources/ZoomSource.swift   NEW
//  Parley/Detection/Sources/WebexSource.swift  NEW   (not implemented; dump-driven later)
//  Parley/Detection/MeetingUITree.swift   NEW   MeetingUITree protocol + LiveMeetingUITree
//                                               (the only thing that touches AXClient) +
//                                               RecordedUITree for tests.
//  Parley/Detection/MeetingSourcePoller.swift  NEW  Dumb clock. Replaces MeetingMetadataResolver.
//  Parley/Detection/MeetingParsers.swift  KEEP  Pure string/tree parsing. teamsAttendees becomes
//                                               teamsRoster and returns sections.
//  Parley/Detection/AXClient.swift        EDIT  + AXUIElementSetMessagingTimeout.
//  Parley/Detection/CallDetector.swift    EDIT  known set + displayName derived from the registry.
//
//  Parley/Recording/MeetingSessionState.swift  EDIT  roster + authority-ranked title.
//  Parley/Recording/RecordingController.swift  EDIT  onReading (~15 lines). mergeRoster DELETED.
//  Parley/UI/SuggestionChips.swift             EDIT  reads AttendeePolicy output.
//
//  DELETED: DiscoveredMetadata, RosterEntry, MeetingMetadataResolver, mergeRoster,
//           `isTeamsCall` / `isZoomCall` branching, CallDetector.displayName's hardcoded map.
//
//  DATA FLOW (three files from AX to attendee, per minimize-reader-load)
//      TeamsSource.read → RosterSnapshot → MeetingRoster.apply → AttendeePolicy.admissions
//

import Foundation

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Parley/Meeting/MeetingPresence.swift
// The domain vocabulary. Nothing below this line knows what Accessibility is.
// ═══════════════════════════════════════════════════════════════════════════

/// A person's display name, guaranteed non-empty and **comma-free**.
///
/// Attendees are persisted comma-delimited (`TranscriptWriter.splitAttendees`), so a comma in a
/// name splits one person into two. Today every consumer re-checks; here the check happens once,
/// at the parse boundary, and the type carries the guarantee — per `boundary-discipline` and
/// `encode-lessons-in-structure`. There is no way to construct an invalid one.
struct DisplayName: Hashable, Sendable, Comparable {
    let value: String
    /// Case-folded identity used for dedup and lookup.
    var key: String { fatalError("not implemented") }

    /// Cleans and validates a raw name from a conferencing UI. Returns nil when the result is
    /// unusable. Absorbs the three normalizations that are currently scattered:
    /// strips trailing status badges ("External", "unfamiliar"), flips `"Rosen, Adam"` →
    /// `"Adam Rosen"`, and rejects anything that still contains a comma.
    init?(raw: String) { fatalError("not implemented") }

    static func < (lhs: DisplayName, rhs: DisplayName) -> Bool { fatalError("not implemented") }
}

/// Why we believe someone is in the call. Policy uses this to decide auto-admit confidence;
/// it is deliberately coarse — anything finer is per-app knowledge that belongs in the source.
enum PresenceEvidence: String, Equatable, Sendable, Codable {
    /// Rendered as an active participant tile / audio-state control (Zoom tiles). Strong.
    case participantTile
    /// Listed in the app's in-call section ("In this meeting", Participants list). Strong.
    case listedInCall
}

/// How an invitee replied, when the source can see it. Never treated as presence.
enum InviteResponse: String, Equatable, Sendable, Codable {
    case accepted, tentative, declined, noResponse
}

/// **The distinction the current design cannot make.** Today `RosterEntry` is one flat bag, so
/// the Outlook invite list and the people actually in the room are the same value and the UI has
/// nothing to filter on. Presence is a domain fact, so it is a domain type.
enum Presence: Equatable, Sendable {
    case inCall(PresenceEvidence)
    /// Observed in-call earlier, then absent from a `.complete` snapshot. Retained (their chip
    /// and their attendee entry must survive them leaving), but no longer "present now".
    case left(at: Date)
    /// On the invite list and never observed in the call.
    case invited(InviteResponse?)
}

enum MeetingRole: String, Equatable, Sendable, Codable {
    case organizer, coOrganizer, presenter, host, coHost, guest
}

/// One person as a single source reported them at a single moment. No identity, no history —
/// history is the roster's job.
struct Participant: Equatable, Sendable {
    let name: DisplayName
    let presence: Presence
    let role: MeetingRole?

    var isInCall: Bool { fatalError("not implemented") }
    var isInvited: Bool { fatalError("not implemented") }
}

/// **What the source's silence means.** This is the load-bearing field: without it, "the People
/// pane is closed" and "nobody is in the meeting" are the same empty array, which is why today's
/// resolver has to drop empty snapshots and can never observe a departure.
enum RosterCoverage: Equatable, Sendable {
    /// The roster surface was not readable this tick (pane closed, tree not built, AX wedged,
    /// no trust, budget exhausted). Absence carries **no** information; apply() is a no-op.
    case unreadable
    /// Some people we can prove are in the call, but the list is not exhaustive
    /// (Zoom speaker tiles; Webex's partial a11y). Absence carries no information; additive only.
    case sightings
    /// The app's full participant surface was enumerated. Absence **is** information:
    /// someone previously in-call and now missing has left.
    case complete
}

/// One source's complete observation at one instant.
struct RosterSnapshot: Equatable, Sendable {
    let observedAt: Date
    let coverage: RosterCoverage
    /// True on the first snapshot in which this source's roster surface became readable.
    /// Everyone in it may have joined long before we could see them, so their arrival time is
    /// unknown — *not* `observedAt`. This is what makes today's "joined 10:03" honest: the People
    /// pane opening at 10:03 is not the same event as Adam joining at 10:03.
    let isFirstSighting: Bool
    let participants: [Participant]

    static func unreadable(at: Date) -> RosterSnapshot { fatalError("not implemented") }
}

/// How much we trust a discovered title. Ranked, so a *late* call-window title still beats an
/// *early* calendar guess — replacing the resolver's `titleLocked` first-wins rule, which can
/// freeze a merely-overlapping calendar entry before the Teams call window settles.
enum TitleAuthority: Int, Comparable, Sendable {
    /// A calendar entry that merely overlaps the current time. Plausible, not confirmed.
    case scheduleOverlap = 1
    /// App chrome that names the running meeting (Zoom home "Now", Webex space name).
    case appContext = 2
    /// The call window's own title. The meeting we are actually in.
    case callWindow = 3

    static func < (l: TitleAuthority, r: TitleAuthority) -> Bool { l.rawValue < r.rawValue }
}

struct TitleCandidate: Equatable, Sendable {
    let title: String
    let authority: TitleAuthority
    /// Stable string persisted as `SessionManifest.titleSource` — existing values
    /// ("callWindow", "calendar:teams", "calendar:outlook", "zoomHome") are unchanged so old
    /// manifests and any downstream reader keep working.
    let provenance: String
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Parley/Meeting/MeetingRoster.swift
// The fold. A value type owned by MeetingSessionState. Deliberately dumb: it
// knows nothing about Teams/Zoom/Webex and contains no product policy.
// ═══════════════════════════════════════════════════════════════════════════

/// When someone showed up, as far as we can honestly claim.
enum Arrival: Equatable, Sendable {
    /// They were absent from a snapshot and present in a later one — a real join time.
    case joined(at: Date)
    /// Already present when the roster surface first became readable. We know they are here;
    /// we do not know since when. The UI must not print a clock time for this case.
    case presentBeforeFirstSight(noticedAt: Date)
    /// Never observed in the call (invite-list only).
    case neverObserved
}

/// What has happened to this person with respect to `meeting.attendees`.
/// Makes admission idempotent: only `.undecided` people are ever acted on, so re-running the
/// policy on every 2.5s tick admits each person exactly once and a dismissal is permanent —
/// per `make-operations-idempotent`.
enum AttendeeDecision: Equatable, Sendable {
    case undecided
    case admitted(Admission)
    case dismissed

    enum Admission: String, Equatable, Sendable, Codable { case automatic, user }
}

struct KnownPerson: Equatable, Identifiable, Sendable {
    let name: DisplayName
    var role: MeetingRole?
    var presence: Presence
    var arrival: Arrival
    var lastSeenInCall: Date?
    var decision: AttendeeDecision
    var id: String { name.key }

    var isPresentNow: Bool { fatalError("not implemented") }
}

/// Accumulates snapshots into per-person history. One entry per person, keyed by `DisplayName.key`.
///
/// Dominant access patterns, all O(1)/O(n) against the stored array + index and none needing a
/// "we'll add a cache later": lookup by name (index), present-now (filter), invited (filter),
/// manifest projection (map), chip list (filter). There is no second representation to keep in
/// sync — `attendees` is derived from `decision`, not maintained beside it.
struct MeetingRoster: Equatable, Sendable {
    private(set) var people: [KnownPerson]
    private var index: [String: Int]

    var presentNow: [KnownPerson] { fatalError("not implemented") }
    var invited: [KnownPerson] { fatalError("not implemented") }
    func person(named: DisplayName) -> KnownPerson? { fatalError("not implemented") }

    /// Fold a snapshot in. The whole coverage contract lives here and nowhere else:
    ///
    /// - `.unreadable` → return immediately. Not a departure, not a timestamp, nothing.
    /// - `.sightings`  → upsert everyone listed; never downgrade or mark anyone as left.
    /// - `.complete`   → upsert everyone listed; anyone previously `.inCall` and absent becomes
    ///                   `.left(at: observedAt)`. They stay in `people` forever (their chip and
    ///                   their attendee entry outlive them leaving).
    ///
    /// Arrival is stamped once, on the transition into `.inCall`: `.presentBeforeFirstSight` when
    /// `snapshot.isFirstSighting`, `.joined(at:)` otherwise. Never re-stamped, so a re-opened
    /// People pane cannot rewrite someone's join time.
    ///
    /// `decision` is never touched here — observation and decision are separate concerns.
    mutating func apply(_ snapshot: RosterSnapshot) {
        // TODO:
        //   guard snapshot.coverage != .unreadable else { return }
        //   for p in snapshot.participants { upsert(p, at: snapshot.observedAt,
        //                                           firstSighting: snapshot.isFirstSighting) }
        //   if snapshot.coverage == .complete { markAbsentAsLeft(seen: snapshot.participants,
        //                                                        at: snapshot.observedAt) }
        fatalError("not implemented")
    }

    /// Record the user's (or the policy's) decision. Idempotent.
    mutating func record(_ decision: AttendeeDecision, for name: DisplayName) {
        fatalError("not implemented")
    }

    // MARK: persistence projection (storage boundary only)

    /// Project to the existing on-disk shape. `SuggestedAttendee` gains two **optional** fields
    /// (`presenceKind`, `admission`) so older `session.json` files still decode and newer ones
    /// round-trip presence. `firstSeen` keeps its meaning for old readers.
    func persisted() -> [SuggestedAttendee] { fatalError("not implemented") }

    /// Rebuild from a manifest on `resume(_:)` — which today drops suggestions and the discovered
    /// title entirely, so a recovered session loses its roster. Missing new fields degrade to
    /// `.invited(nil)` / `.presentBeforeFirstSight`, never to a false join time.
    init(restoring: [SuggestedAttendee]?) { fatalError("not implemented") }

    init() { fatalError("not implemented") }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Parley/Meeting/AttendeePolicy.swift
// Pure functions. The only place the product's "auto-admit present" rule lives.
// ═══════════════════════════════════════════════════════════════════════════

enum AttendeePolicy {

    /// People to add to `meeting.attendees` right now, without a tap: present, confident, look
    /// like a person, still `.undecided`. Returns only new admissions, so calling it every tick
    /// is safe. This is the same path speaker-ID already uses (`addAttendeeIfAbsent`) — it is not
    /// a new writer, per `subtract-before-you-add`.
    static func admissions(in roster: MeetingRoster) -> [DisplayName] { fatalError("not implemented") }

    /// In-call names we will not auto-admit: rooms, devices, anything that fails `isLikelyPerson`.
    /// These are the chips — tap-to-add is the right friction for an *uncertain* name.
    static func uncertainChips(in roster: MeetingRoster) -> [KnownPerson] { fatalError("not implemented") }

    /// Invite-list people who never joined. Rendered as a separate, collapsed disclosure — never
    /// the same chip as someone in the room, and no "Add all". This is the UX bug, fixed by a
    /// type distinction rather than by a heuristic in the view.
    static func invitedChips(in roster: MeetingRoster) -> [KnownPerson] { fatalError("not implemented") }

    /// "Conf Room 4B", "Naufal's MacBook", "iPhone", "SIP:…", a bare phone number → false.
    /// Conservative: when unsure, return false and let the chip ask.
    static func isLikelyPerson(_ name: DisplayName) -> Bool { fatalError("not implemented") }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Parley/Detection/MeetingUITree.swift
// The only capability a source is given. Keeps AX in one file and makes every
// source testable against a recorded MeetingProbe dump with zero AX.
// ═══════════════════════════════════════════════════════════════════════════

/// Read-only view of a running app's UI. Read-only is structural, not a convention: there is no
/// method that presses, focuses, or navigates, so "do not drive conferencing UI" cannot be
/// violated by a source even by accident.
///
/// `AXNode` stays the internal parsing vocabulary (existing `MeetingParsersTests` fixtures depend
/// on it) and never leaves the Detection module — `SourceReading` carries domain types only.
protocol MeetingUITree: Sendable {
    /// Cheap: window titles only, no tree walk.
    func windowTitles(pid: pid_t) -> [String]
    /// Flattened nodes of the windows whose title matches. The normal roster read.
    func nodes(pid: pid_t, inWindowsTitled matches: (String) -> Bool) -> [AXNode]
    /// Flattened nodes of every window. Expensive (whole Electron DOM); sources ration this
    /// themselves and the budget's deadline bounds it.
    func nodes(pid: pid_t) -> [AXNode]
    /// Flip the Electron/Chromium AX switches for a pid, once per pid, and wait for the tree.
    func prepareRichTree(pid: pid_t)
}

/// Live implementation over `AXClient`. Sets `AXUIElementSetMessagingTimeout` per app element
/// (grounding #9: a wedged Teams/Webex must not leak the AX queue forever) and returns empty
/// results past `budget.deadline` rather than blocking.
struct LiveMeetingUITree: MeetingUITree {
    let budget: ScanBudget
    // TODO: per-pid `AXUIElementSetMessagingTimeout(app, budget.messagingTimeout)` on first use;
    //       remember prepared pids for the call's lifetime (queue-confined, no global set).
}

/// Test double replaying a `tools/MeetingProbe` dump.
struct RecordedUITree: MeetingUITree { /* … */ }

/// Wall-clock bound for one tick's AX work.
struct ScanBudget: Sendable {
    let deadline: Date
    let messagingTimeout: Float   // seconds, per AXUIElement
    var isExpired: Bool { fatalError("not implemented") }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Parley/Detection/MeetingSource.swift
// ═══════════════════════════════════════════════════════════════════════════

/// The call as the detector confirmed it. `bundleID` is already the parent app (helper prefixes
/// resolved by `CallDetector`), so no source ever re-does that.
struct CallIdentity: Equatable, Sendable {
    let bundleID: String
    let pid: pid_t          // the mic-holding process; may be a helper
    let startedAt: Date
}

enum BundleMatcher: Sendable {
    case exact(String)
    case prefix(String)     // "com.microsoft.teams" covers teams / teams2 / future suffixes
    func matches(_ bundleID: String) -> Bool { fatalError("not implemented") }
}

/// What Parley can do with an app. Splits two facts the current design conflates: `AppSettings
/// .conferencingBundleIDs` decides *auto-record*, and having a parser decides *metadata* — Webex
/// needs the first before the second exists.
enum SourceCapability: Sendable {
    case titleAndRoster
    case titleOnly
    /// Claimed for detection (known app, correct display name, auto-record eligible) but no
    /// parsers yet. The poller never calls `read` on one of these.
    case none
}

struct SourceIdentity: Sendable {
    let displayName: String
    let matchers: [BundleMatcher]
    let capability: SourceCapability
}

/// What the poller still wants. Narrowing only — it tells a source what is no longer needed so
/// expensive walks can be skipped; it never tells a source *how* to look.
struct ScanNeeds: Sendable {
    /// False once a `.callWindow`-authority title has been delivered, or after the ~16s give-up.
    let title: Bool
    /// Always true while polling. Late joiners matter for the whole call.
    let roster: Bool
}

/// Running apps, snapshotted on the main actor (NSWorkspace is not queue-safe) and handed down.
/// A source that needs a sibling app — Teams' Calendar tab, native Outlook — looks it up here.
/// The poller never learns which apps matter to whom.
struct RunningApps: Sendable {
    func pid(exact bundleID: String) -> pid_t? { fatalError("not implemented") }
    func pid(prefix: String) -> pid_t? { fatalError("not implemented") }
}

/// Everything a source gets for one tick. One parameter, so the source signature never grows.
struct ScanContext: Sendable {
    let call: CallIdentity
    let tick: Int                       // 1-based; sources choose their own cadence from it
    let elapsedSinceCallStart: TimeInterval
    let now: Date
    let runningApps: RunningApps
    let needs: ScanNeeds
    let budget: ScanBudget
    let tree: any MeetingUITree
}

/// One tick's findings. `roster` is non-optional: a source that saw nothing returns
/// `.unreadable` coverage, which is a fact worth delivering, not an update to suppress.
struct SourceReading: Equatable, Sendable {
    let title: TitleCandidate?
    let roster: RosterSnapshot
}

/// **The deep module.** One instance per call, created by the registry. Everything app-specific
/// lives behind `read`: which window is the call window, when to flip Electron switches, how
/// often a tree walk is affordable, what the People pane's absence means, whether the invite
/// section is separable from the present section, which calendar surface to consult.
///
/// Interface depth: one method, seven-field context in, two domain values out. The caller cannot
/// tell Teams from Webex, and gains nothing from knowing.
///
/// Concurrency: instances are created and used **only** on the poller's serial AX queue, so
/// per-call mutable state (prepared pids, whether the roster surface has ever been readable)
/// needs no locking. `@unchecked Sendable` on the conformances is that confinement contract.
protocol MeetingSource: AnyObject, Sendable {
    static var identity: SourceIdentity { get }
    init(call: CallIdentity)
    /// Never throws, never blocks past `context.budget.deadline`. Failure is `.unreadable`
    /// coverage and a nil title — silent degradation is the contract (grounding #1).
    func read(_ context: ScanContext) -> SourceReading
}

/// The single source of truth about conferencing apps. `CallDetector`'s known-app set and its
/// hardcoded display-name map are *derived* from this, not maintained beside it — per
/// single-source-of-truth. User-added bundle ids from Settings union on top and resolve to no
/// source (detection only), which is exactly today's behaviour for an unparsed app.
enum MeetingSourceRegistry {
    static let all: [any MeetingSource.Type] = [
        TeamsSource.self, ZoomSource.self, WebexSource.self,
    ]

    static var claimedBundleIDs: Set<String> { fatalError("not implemented") }
    static func displayName(for bundleID: String) -> String? { fatalError("not implemented") }
    /// nil when no source claims the app, or when the claiming source's capability is `.none`.
    static func source(for call: CallIdentity) -> (any MeetingSource)? { fatalError("not implemented") }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Parley/Detection/MeetingSourcePoller.swift
// A dumb clock. Contains no app name, no bundle id, no parser. When Webex
// lands, this file does not change.
// ═══════════════════════════════════════════════════════════════════════════

@MainActor
final class MeetingSourcePoller {
    var onReading: ((SourceReading) -> Void)?
    var isPolling: Bool { fatalError("not implemented") }

    /// Resolve the source once, then tick. No-op (and no AX at all) when no source claims the
    /// app, when metadata discovery is off, or when AX is untrusted — checked per tick so a
    /// mid-call permission grant resumes on its own, as today.
    func start(for call: DetectedCall) { fatalError("not implemented") }

    /// Stop scanning, keep the source and its findings. Call end / preview / stop.
    func freeze() { fatalError("not implemented") }

    func stop() { fatalError("not implemented") }

    // TODO: tick:
    //   guard !scanning, AXClient.isTrusted() else { return }
    //   let ctx = ScanContext(call:, tick: tick, elapsed:, now:,
    //                         runningApps: RunningApps.snapshot(),   // main actor
    //                         needs: ScanNeeds(title: !titleSettled && elapsed < 16, roster: true),
    //                         budget: ScanBudget(deadline: now + 4, messagingTimeout: 2),
    //                         tree: LiveMeetingUITree(budget:))
    //   axQueue.async { let r = source.read(ctx); Task { @MainActor in deliver(r) } }
    //
    // `titleSettled` is poller-local: it becomes true when a delivered candidate has
    // `.callWindow` authority. The poller tracks only what it has emitted — it never reads
    // session state, so there is no second copy of the title lock to keep in sync.
    //
    // Every reading is delivered, including all-unreadable ones. Suppressing them is what makes
    // presence-now unobservable today.
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Parley/Detection/Sources/TeamsSource.swift  (highest priority)
// ═══════════════════════════════════════════════════════════════════════════

final class TeamsSource: MeetingSource, @unchecked Sendable {
    static let identity = SourceIdentity(
        displayName: "Microsoft Teams",
        matchers: [.prefix("com.microsoft.teams")],
        capability: .titleAndRoster)

    required init(call: CallIdentity) { fatalError("not implemented") }

    func read(_ context: ScanContext) -> SourceReading { fatalError("not implemented") }

    // MARK: what only Teams knows

    /// Call-window title `<meeting> | <org> | <account> | Microsoft Teams`. Nav-view titles and
    /// the generic "Microsoft Teams" a fresh call window carries return nil so we keep polling.
    /// Authority `.callWindow`.
    private func callWindowTitle(_ context: ScanContext) -> TitleCandidate? { fatalError("not implemented") }

    /// The Teams Calendar tab (embedded Outlook web) and native Outlook, consulted **only if
    /// already rendered** — we never navigate there. Authority `.scheduleOverlap`, so a call
    /// window title arriving later still wins.
    /// Rationed to ticks 3 and 6: whole-window Electron walks, and this is where that cost
    /// knowledge belongs — not in the clock.
    private func renderedCalendarTitle(_ context: ScanContext) -> TitleCandidate? { fatalError("not implemented") }

    /// **The fix for the reported bug.** `MeetingParsers.teamsRoster` returns the two sections
    /// separately; this maps "In this meeting" → `.inCall(.listedInCall)` and "Others invited" →
    /// `.invited(response)`. Coverage:
    ///   - no `AXOutline desc="Attendees"` in the tree (People pane closed) → `.unreadable`
    ///   - outline present → `.complete` (both sections enumerated; absence means departed)
    /// Runs on even ticks only; the Electron switches are flipped once per pid before the first
    /// walk. There is no tile-based fallback in Teams today, so a closed pane is honestly
    /// `.unreadable` rather than a fabricated empty list.
    private func roster(_ context: ScanContext) -> RosterSnapshot { fatalError("not implemented") }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Parley/Detection/Sources/ZoomSource.swift
// ═══════════════════════════════════════════════════════════════════════════

final class ZoomSource: MeetingSource, @unchecked Sendable {
    static let identity = SourceIdentity(
        displayName: "Zoom",
        matchers: [.exact("us.zoom.xos")],
        capability: .titleAndRoster)

    required init(call: CallIdentity) { fatalError("not implemented") }
    func read(_ context: ScanContext) -> SourceReading { fatalError("not implemented") }

    /// The meeting window is literally "Zoom Meeting", so there is no `.callWindow` title to
    /// have. Zoom Workplace home's "Now" group is `.appContext`; a rendered Teams/Outlook
    /// calendar entry is `.scheduleOverlap`. Instant meetings legitimately yield nothing and the
    /// "Zoom call" default stands — the ranking makes that a stated outcome, not an accident of
    /// which source happened to answer first.
    private func title(_ context: ScanContext) -> TitleCandidate? { fatalError("not implemented") }

    /// Two surfaces, different coverage — the reason coverage is per-snapshot and not per-app:
    ///   - Participants panel in the tree → `.complete`, `.listedInCall`, Host/Co-host roles
    ///   - speaker tiles only (panel closed) → `.sightings`, `.participantTile`
    ///   - neither → `.unreadable`
    /// Zoom has no invite-list surface, so `.invited` never appears from here. That is a fact
    /// about Zoom, stated once, here.
    private func roster(_ context: ScanContext) -> RosterSnapshot { fatalError("not implemented") }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Parley/Detection/Sources/WebexSource.swift
// Deliberately not implemented. Selectors must come from a live MeetingProbe
// dump, exactly as Teams' and Zoom's did — guessing them is how the Teams
// invite-list bug got frozen into a test in the first place.
// ═══════════════════════════════════════════════════════════════════════════

final class WebexSource: MeetingSource, @unchecked Sendable {
    static let identity = SourceIdentity(
        displayName: "Webex",
        matchers: [.exact("cisco-systems.spark"), .exact("com.cisco.webexmeetingsapp")],
        // `.none` until dumps land. Claiming the bundle id already buys the two things the user
        // notices today: Webex becomes a *known* app (auto-record eligible) and stops being
        // called "spark call". Metadata follows later without touching anything else.
        capability: .none)

    required init(call: CallIdentity) { fatalError("not implemented") }

    /// Reachable only after `capability` flips. Then:
    /// - title: meeting window carries the space/meeting name; the generic messaging window
    ///   titled exactly "Webex" must be rejected the way "Microsoft Teams" is. `.callWindow`.
    /// - in-call vs chat: `callControl_*` automation ids are the documented tell.
    /// - roster: Cisco's participant-list a11y is weak; expect `.sightings` at best and
    ///   `.unreadable` often. Coverage already expresses that, so nothing downstream changes.
    func read(_ context: ScanContext) -> SourceReading {
        fatalError("not implemented — awaiting tools/MeetingProbe dump")
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Parley/Detection/MeetingParsers.swift  (edited)
// Still pure, still off the main actor, still fed by probe fixtures.
// ═══════════════════════════════════════════════════════════════════════════

extension MeetingParsers {
    /// Sections, not a bag. Replaces `teamsAttendees`, whose test currently *asserts* that
    /// invited-not-joined people are suggestions.
    struct ParsedTeamsRoster: Equatable {
        let inMeeting: [ParsedPerson]
        let othersInvited: [ParsedPerson]
    }
    struct ParsedPerson: Equatable {
        let name: DisplayName
        let role: MeetingRole?
        let inviteResponse: InviteResponse?   // "Tentative" etc., only meaningful for invited rows
    }

    /// nil when the `AXOutline desc="Attendees"` anchor is absent — the caller must be able to
    /// tell "pane closed" from "empty meeting", so this returns an Optional, not an empty struct.
    static func teamsRoster(_ nodes: [AXNode]) -> ParsedTeamsRoster? { fatalError("not implemented") }

    /// Zoom's two surfaces, separated so the source can assign coverage.
    static func zoomParticipantsPanel(_ nodes: [AXNode]) -> [ParsedPerson]? { fatalError("not implemented") }
    static func zoomSpeakerTiles(_ nodes: [AXNode]) -> [ParsedPerson] { fatalError("not implemented") }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Parley/Recording/MeetingSessionState.swift  (edited)
// ═══════════════════════════════════════════════════════════════════════════

extension MeetingSessionState {
    /// Replaces `suggestedAttendees`. Single in-memory representation; `attendees` (the comma
    /// string) stays the user-editable field and is *derived from* admissions, never a parallel
    /// list to reconcile.
    // @Published var roster = MeetingRoster()

    /// Best candidate so far, by authority. Auto-fills `meetingTitle` while it is still a default
    /// (`""`, `"Recorded call"`, `" call"` suffix) and the user has not edited; otherwise records
    /// it for the "Use …" chip. A strictly higher authority re-offers even after an earlier
    /// auto-fill — that is the whole point of ranking.
    func offerTitle(_ candidate: TitleCandidate) { fatalError("not implemented") }

    /// The chip's content: the best candidate, when it differs from the current title.
    var titleChip: TitleCandidate? { fatalError("not implemented") }

    /// Clears roster, best candidate, and `titleWasUserEdited` — which today survives into the
    /// next session and silently suppresses the next meeting's auto-fill.
    // func resetDiscovery()
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Parley/Recording/RecordingController.swift  (edited)
// ═══════════════════════════════════════════════════════════════════════════

extension RecordingController {
    // let sourcePoller = MeetingSourcePoller()      // replaces metadataResolver
    // mergeRoster / acceptSuggestion / acceptAllSuggestions / dismissSuggestion — DELETED

    /// User tap on an uncertain or invited chip.
    func admit(_ person: KnownPerson) { fatalError("not implemented") }

    /// ✕ on a chip, or undo of an auto-admit: marks `.dismissed` (never re-admitted) and removes
    /// the name from `meeting.attendees` if it was auto-added.
    func dismiss(_ person: KnownPerson) { fatalError("not implemented") }
}
