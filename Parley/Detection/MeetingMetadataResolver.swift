import Foundation
import AppKit

/// One resolver scan's findings, delivered to the controller on the main actor.
struct DiscoveredMetadata: Equatable {
    var title: String?
    var titleSource: String?       // "callWindow" | "calendar:teams" | "calendar:outlook" | "zoomHome"
    var roster: [RosterEntry] = [] // raw roster snapshot; controller merges + stamps join times
}

/// Discovers meeting metadata for a detected call by reading conferencing-app
/// UI via Accessibility. Polls on a main-actor timer; every AX read runs on a
/// serial background queue (Electron trees are slow), and only value-type
/// results cross back. Failure of any source silently yields nothing — this
/// must never affect recording.
///
/// Title resolution order (user priority, validated by tools/MeetingProbe):
///  1. call-window title (Teams pipe-format; polled until it settles)
///  2. rendered calendar lookup: Zoom home "Now" entry (Zoom calls), the Teams
///     Calendar tab, the native Outlook Calendar view
///  3. give up after ~16s — the caller's "(App) call" default stands.
/// Roster polling continues for the whole call (late joiners), every other tick.
@MainActor
final class MeetingMetadataResolver {

    var onUpdate: ((DiscoveredMetadata) -> Void)?

    /// True while the poll timer is live (used to avoid double-starting when a
    /// manual record begins during an already-detected call).
    var isPolling: Bool { timer != nil }

    private let settings = AppSettings.shared
    private let axQueue = DispatchQueue(label: "parley.meeting-ax", qos: .utility)
    private var timer: Timer?
    private var scanning = false
    private var call: DetectedCall?
    private var startedAt: Date?
    private var titleLocked = false
    private var tick = 0

    private let tickInterval: TimeInterval = 2.5
    private let titleGiveUpSeconds: TimeInterval = 16
    /// Calendar walks are whole-window tree walks — only attempted twice.
    private let calendarTicks: Set<Int> = [3, 6]

    // MARK: lifecycle

    func start(for call: DetectedCall) {
        stop()
        guard settings.metadataDiscoveryEnabled else { return }
        self.call = call
        startedAt = Date()
        titleLocked = false
        tick = 0
        AppLog.log("metadata resolver started for \(call.bundleID) (trusted=\(AXClient.isTrusted()))", category: "detect")
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFired() }
        }
        tickFired()
    }

    /// Stop polling but keep the session's discoveries flowing no further —
    /// the controller retains what was found (chips stay usable post-stop).
    func enterPreviewMode() {
        timer?.invalidate(); timer = nil
        AppLog.log("metadata resolver frozen (preview)", category: "detect")
    }

    func stop() {
        timer?.invalidate(); timer = nil
        call = nil
        scanning = false
    }

    // MARK: polling

    private func tickFired() {
        guard let call, !scanning else { return }
        // No-op without trust; resumes automatically if granted mid-call.
        guard AXClient.isTrusted() else { return }
        tick += 1

        let inTitleWindow = startedAt.map { Date().timeIntervalSince($0) < titleGiveUpSeconds } ?? false
        let wantTitle = !titleLocked && inTitleWindow
        let tryCalendar = wantTitle && calendarTicks.contains(tick)
        let wantRoster = tick % 2 == 0   // every ~5s; tree walks are the expensive part
        guard wantTitle || wantRoster else { return }

        // Resolve pids on the main actor (NSWorkspace); AX happens on the queue.
        let callApp = Self.runningApp(bundleID: call.bundleID)
        let teamsPid = Self.runningApp(bundleIDPrefix: "com.microsoft.teams")?.processIdentifier
        let outlookPid = Self.runningApp(bundleID: "com.microsoft.outlook")?.processIdentifier
        guard callApp != nil || tryCalendar else { return }

        scanning = true
        let job = ScanJob(
            callBundleID: call.bundleID,
            callPid: callApp?.processIdentifier,
            teamsPid: teamsPid,
            outlookPid: outlookPid,
            wantTitle: wantTitle,
            tryCalendar: tryCalendar,
            wantRoster: wantRoster)
        axQueue.async { [weak self] in
            let result = Self.scan(job)
            Task { @MainActor in
                guard let self else { return }
                self.scanning = false
                guard self.call != nil else { return }   // stopped while scanning
                if result.title != nil { self.titleLocked = true }
                if result.title != nil || !result.roster.isEmpty {
                    self.onUpdate?(result)
                }
            }
        }
    }

    private static func runningApp(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier?.lowercased() == bundleID.lowercased()
        }
    }

    private static func runningApp(bundleIDPrefix: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier?.lowercased().hasPrefix(bundleIDPrefix.lowercased()) == true
        }
    }

    // MARK: scanning (background queue only)

    private struct ScanJob: Sendable {
        let callBundleID: String
        let callPid: pid_t?
        let teamsPid: pid_t?
        let outlookPid: pid_t?
        let wantTitle: Bool
        let tryCalendar: Bool
        let wantRoster: Bool
    }

    /// Pids we've already flipped the Electron AX switches for (axQueue-confined).
    nonisolated(unsafe) private static var electronEnabled = Set<pid_t>()

    private nonisolated static func ensureElectronAX(pid: pid_t) {
        guard !electronEnabled.contains(pid) else { return }
        electronEnabled.insert(pid)
        AXClient.enableElectronAX(pid: pid)
        Thread.sleep(forTimeInterval: 1.0)   // let the renderer build the tree (bg queue)
    }

    private nonisolated static func scan(_ job: ScanJob) -> DiscoveredMetadata {
        var result = DiscoveredMetadata()
        let isTeamsCall = job.callBundleID.hasPrefix("com.microsoft.teams")
        let isZoomCall = job.callBundleID == "us.zoom.xos"

        // 1. Call-window title (cheap: window titles only, no tree walk).
        if job.wantTitle, isTeamsCall, let pid = job.callPid {
            for window in AXClient.windows(pid: pid) {
                if let raw = AXClient.title(of: window),
                   let title = MeetingParsers.teamsCallTitle(windowTitle: raw) {
                    result.title = title
                    result.titleSource = "callWindow"
                    break
                }
            }
        }

        // 2. Rendered-calendar lookups (tree walks — rationed to two attempts).
        if result.title == nil, job.tryCalendar {
            if isZoomCall, let pid = job.callPid,
               let (title, _) = MeetingParsers.zoomHomeNowTitle(walkAll(pid: pid)) {
                result.title = title
                result.titleSource = "zoomHome"
            }
            if result.title == nil, let pid = job.teamsPid {
                ensureElectronAX(pid: pid)
                let events = MeetingParsers.outlookCalendarEvents(walkAll(pid: pid))
                if let event = MeetingParsers.currentEvent(in: events) {
                    result.title = event.title
                    result.titleSource = "calendar:teams"
                }
            }
            if result.title == nil, let pid = job.outlookPid,
               let title = MeetingParsers.outlookNativeJoinableTitle(walkAll(pid: pid)) {
                result.title = title
                result.titleSource = "calendar:outlook"
            }
        }

        // 3. Roster (call-window walk; Teams roster needs the Electron switches).
        if job.wantRoster, let pid = job.callPid {
            if isTeamsCall {
                ensureElectronAX(pid: pid)
                let nodes = walkCallWindows(pid: pid) {
                    MeetingParsers.teamsCallTitle(windowTitle: $0) != nil
                }
                result.roster = MeetingParsers.teamsAttendees(nodes)
            } else if isZoomCall {
                let nodes = walkCallWindows(pid: pid) { $0 == "Zoom Meeting" }
                result.roster = MeetingParsers.zoomAttendees(nodes)
            }
        }

        return result
    }

    /// Flattened nodes of every window of a pid.
    private nonisolated static func walkAll(pid: pid_t) -> [AXNode] {
        AXClient.windows(pid: pid).flatMap { AXClient.walk($0) }
    }

    /// Flattened nodes of just the windows whose title matches (the call window).
    private nonisolated static func walkCallWindows(pid: pid_t, titleMatches: (String) -> Bool) -> [AXNode] {
        AXClient.windows(pid: pid)
            .filter { AXClient.title(of: $0).map(titleMatches) ?? false }
            .flatMap { AXClient.walk($0) }
    }
}
