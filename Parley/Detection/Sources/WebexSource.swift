import Foundation

/// Title uses the meeting window, then the same calendar fallback as Teams and Zoom.
/// The participant list stays unreadable until a live call exposes it. An empty
/// complete roster would look like everyone had left.
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

    required init(call: CallIdentity) { _ = call }

    func read(_ context: ScanContext) -> SourceReading {
        var title: TitleCandidate?
        if context.needs.title {
            title = callWindowTitle(context)
            if title == nil, [3, 6].contains(context.tick) {
                title = calendarTitle(context)
            }
        }
        return SourceReading(title: title, roster: .unreadable(at: context.now))
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

    private func calendarTitle(_ context: ScanContext) -> TitleCandidate? {
        if let teamsPid = context.runningApps.pid(prefix: "com.microsoft.teams") {
            context.tree.prepareRichTree(pid: teamsPid)
        }
        return MeetingParsers.scheduleOverlapTitle(apps: context.runningApps, tree: context.tree)
    }
}
