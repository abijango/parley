import Foundation

final class ZoomSource: MeetingSource, @unchecked Sendable {
    static let identity = SourceIdentity(
        displayName: "Zoom",
        matchers: [.exact("us.zoom.xos")],
        capability: .titleAndRoster)

    private let call: CallIdentity
    private var sawRosterSurface = false

    required init(call: CallIdentity) { self.call = call }

    func read(_ context: ScanContext) -> SourceReading {
        var title: TitleCandidate?
        if context.needs.title {
            if let (topic, _) = MeetingParsers.zoomHomeNowTitle(context.tree.nodes(pid: context.call.pid)) {
                title = TitleCandidate(title: topic, authority: .appContext, provenance: "zoomHome")
            } else if [3, 6].contains(context.tick) {
                title = renderedCalendarTitle(context)
            }
        }
        let nodes = context.tree.nodes(pid: context.call.pid) {
            $0 == "Zoom Meeting" || $0.lowercased().contains("zoom")
        }
        let walk = nodes.isEmpty ? context.tree.nodes(pid: context.call.pid) : nodes
        let snapshot = MeetingParsers.zoomRosterSnapshot(
            walk, at: context.now, isFirstSighting: !sawRosterSurface)
            ?? .unreadable(at: context.now)
        if snapshot.coverage != .unreadable { sawRosterSurface = true }
        return SourceReading(title: title, roster: snapshot)
    }

    private func renderedCalendarTitle(_ context: ScanContext) -> TitleCandidate? {
        if let teamsPid = context.runningApps.pid(prefix: "com.microsoft.teams") {
            context.tree.prepareRichTree(pid: teamsPid)
        }
        return MeetingParsers.scheduleOverlapTitle(apps: context.runningApps, tree: context.tree)
    }
}
