import Foundation

final class TeamsSource: MeetingSource, @unchecked Sendable {
    static let identity = SourceIdentity(
        displayName: "Microsoft Teams",
        matchers: [.prefix("com.microsoft.teams")],
        capability: .titleAndRoster)

    private let call: CallIdentity
    private var prepared = Set<pid_t>()
    private var sawRosterSurface = false

    required init(call: CallIdentity) { self.call = call }

    func read(_ context: ScanContext) -> SourceReading {
        let pid = context.call.pid
        prepareIfNeeded(pid, tree: context.tree)

        var title: TitleCandidate?
        if context.needs.title {
            title = callWindowTitle(context)
            if title == nil, [3, 6].contains(context.tick) {
                title = renderedCalendarTitle(context)
            }
        }
        return SourceReading(title: title, roster: roster(context))
    }

    private func prepareIfNeeded(_ pid: pid_t, tree: any MeetingUITree) {
        guard prepared.insert(pid).inserted else { return }
        tree.prepareRichTree(pid: pid)
    }

    private func callWindowTitle(_ context: ScanContext) -> TitleCandidate? {
        for raw in context.tree.windowTitles(pid: context.call.pid) {
            if let title = MeetingParsers.teamsCallTitle(windowTitle: raw) {
                return TitleCandidate(title: title, authority: .callWindow, provenance: "callWindow")
            }
        }
        return nil
    }

    private func renderedCalendarTitle(_ context: ScanContext) -> TitleCandidate? {
        if let teamsPid = context.runningApps.pid(prefix: "com.microsoft.teams") {
            prepareIfNeeded(teamsPid, tree: context.tree)
            let events = MeetingParsers.outlookCalendarEvents(context.tree.nodes(pid: teamsPid))
            if let event = MeetingParsers.currentEvent(in: events) {
                return TitleCandidate(title: event.title, authority: .scheduleOverlap, provenance: "calendar:teams")
            }
        }
        if let outlookPid = context.runningApps.pid(exact: "com.microsoft.outlook"),
           let title = MeetingParsers.outlookNativeJoinableTitle(context.tree.nodes(pid: outlookPid)) {
            return TitleCandidate(title: title, authority: .scheduleOverlap, provenance: "calendar:outlook")
        }
        return nil
    }

    /// Roster is found by the Attendees outline, not by a settled call-window title.
    private func roster(_ context: ScanContext) -> RosterSnapshot {
        guard context.needs.roster, context.tick % 2 == 0 else {
            return .unreadable(at: context.now)
        }
        let nodes = context.tree.nodes(pid: context.call.pid)
        guard let parsed = MeetingParsers.teamsRoster(nodes) else {
            return .unreadable(at: context.now)
        }
        let first = !sawRosterSurface
        sawRosterSurface = true
        var people: [Participant] = parsed.inMeeting.map {
            Participant(name: $0.name, presence: .inCall(.listedInCall), role: $0.role)
        }
        people += parsed.othersInvited.map {
            Participant(name: $0.name, presence: .invited($0.inviteResponse), role: $0.role)
        }
        return RosterSnapshot(
            observedAt: context.now, coverage: .complete, isFirstSighting: first, participants: people)
    }
}
