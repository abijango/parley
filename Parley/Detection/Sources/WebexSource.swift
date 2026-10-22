import Foundation

/// Title uses the meeting window, then the calendar fallback shared with Teams and Zoom.
/// Roster comes from the meeting window's video-grid tiles.
final class WebexSource: MeetingSource, @unchecked Sendable {
    /// `sparkhelper` is one bundle segment. A prefix of `spark` would also claim `sparkfoo`.
    static let helperAliases = ["cisco-systems.sparkhelper": "cisco-systems.spark"]

    static let identity = SourceIdentity(
        displayName: "Webex",
        matchers: [
            .exact("cisco-systems.spark"),
            .exact("cisco-systems.sparkhelper"),
            .exact("com.cisco.webexmeetingsapp"),
        ],
        capability: .titleAndRoster)

    private var sawRosterSurface = false

    required init(call: CallIdentity) { _ = call }

    func read(_ context: ScanContext) -> SourceReading {
        var title: TitleCandidate?
        if context.needs.title {
            title = callWindowTitle(context) ?? context.calendarFallbackTitle(for: .webex)
        }
        return SourceReading(title: title, roster: roster(context))
    }

    /// The main app is preferred. The helper is the fallback when the meeting window lives there.
    private func candidatePids(_ context: ScanContext) -> [pid_t] {
        var pids: [pid_t] = []
        func add(_ pid: pid_t?) {
            guard let pid, !pids.contains(pid) else { return }
            pids.append(pid)
        }
        add(context.runningApps.pid(exact: "cisco-systems.spark"))
        add(context.call.pid)
        add(context.runningApps.pid(exact: "cisco-systems.sparkhelper"))
        add(context.runningApps.pid(exact: "com.cisco.webexmeetingsapp"))
        return pids
    }

    private func callWindowTitle(_ context: ScanContext) -> TitleCandidate? {
        for pid in candidatePids(context) {
            for raw in context.tree.windowTitles(pid: pid) {
                if let title = MeetingParsers.webexCallTitle(windowTitle: raw) {
                    return TitleCandidate(title: title, authority: .callWindow, provenance: "callWindow")
                }
            }
        }
        return nil
    }

    private func roster(_ context: ScanContext) -> RosterSnapshot {
        guard context.needs.roster else { return .unreadable(at: context.now) }
        for pid in candidatePids(context) {
            let nodes = context.tree.nodes(pid: pid) { MeetingParsers.webexCallTitle(windowTitle: $0) != nil }
            if let snapshot = MeetingParsers.webexRosterSnapshot(
                nodes, at: context.now, isFirstSighting: !sawRosterSurface) {
                sawRosterSurface = true
                return snapshot
            }
        }
        return .unreadable(at: context.now)
    }
}
