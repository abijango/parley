import Foundation
import AppKit

protocol MeetingUITree: Sendable {
    func windowTitles(pid: pid_t) -> [String]
    func nodes(pid: pid_t, inWindowsTitled matches: @escaping @Sendable (String) -> Bool) -> [AXNode]
    func nodes(pid: pid_t) -> [AXNode]
    func prepareRichTree(pid: pid_t)
}

struct LiveMeetingUITree: MeetingUITree {
    func windowTitles(pid: pid_t) -> [String] {
        AXClient.setMessagingTimeout(pid: pid)
        return AXClient.windows(pid: pid).compactMap { AXClient.title(of: $0) }
    }

    func nodes(pid: pid_t, inWindowsTitled matches: @escaping @Sendable (String) -> Bool) -> [AXNode] {
        AXClient.setMessagingTimeout(pid: pid)
        return AXClient.windows(pid: pid)
            .filter { AXClient.title(of: $0).map(matches) ?? false }
            .flatMap { AXClient.walk($0) }
    }

    func nodes(pid: pid_t) -> [AXNode] {
        AXClient.setMessagingTimeout(pid: pid)
        return AXClient.windows(pid: pid).flatMap { AXClient.walk($0) }
    }

    func prepareRichTree(pid: pid_t) {
        AXClient.setMessagingTimeout(pid: pid)
        AXClient.enableElectronAX(pid: pid)
        Thread.sleep(forTimeInterval: 1.0)
    }
}

struct CallIdentity: Equatable, Sendable {
    let bundleID: String
    let pid: pid_t
    let startedAt: Date
}

enum BundleMatcher: Sendable {
    case exact(String)
    case prefix(String)

    func matches(_ bundleID: String) -> Bool {
        let bid = bundleID.lowercased()
        switch self {
        case .exact(let value): return bid == value.lowercased()
        case .prefix(let value): return bid.hasPrefix(value.lowercased())
        }
    }
}

enum SourceCapability: Sendable {
    case titleAndRoster
    case titleOnly
    case none
}

struct SourceIdentity: Sendable {
    let displayName: String
    let matchers: [BundleMatcher]
    let capability: SourceCapability
}

struct ScanNeeds: Sendable {
    let title: Bool
    let roster: Bool
}

struct RunningApps: Sendable {
    let pids: [String: pid_t]

    static func snapshot() -> RunningApps {
        var map: [String: pid_t] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier?.lowercased() else { continue }
            map[bid] = app.processIdentifier
        }
        return RunningApps(pids: map)
    }

    func pid(exact bundleID: String) -> pid_t? {
        pids[bundleID.lowercased()]
    }

    func pid(prefix: String) -> pid_t? {
        let p = prefix.lowercased()
        if let exact = pids[p] { return exact }
        return pids.first { $0.key.hasPrefix(p) }?.value
    }
}

struct ScanContext: Sendable {
    let call: CallIdentity
    let tick: Int
    let elapsedSinceCallStart: TimeInterval
    let now: Date
    let runningApps: RunningApps
    let needs: ScanNeeds
    let tree: any MeetingUITree
}

struct SourceReading: Equatable, Sendable {
    let title: TitleCandidate?
    let roster: RosterSnapshot
}

protocol MeetingSource: AnyObject, Sendable {
    static var identity: SourceIdentity { get }
    init(call: CallIdentity)
    func read(_ context: ScanContext) -> SourceReading
}

enum MeetingSourceRegistry {
    static let all: [any MeetingSource.Type] = [
        TeamsSource.self, ZoomSource.self, WebexSource.self,
    ]

    static func displayName(for bundleID: String) -> String? {
        all.first { type in type.identity.matchers.contains { $0.matches(bundleID) } }?
            .identity.displayName
    }

    static func sourceType(for bundleID: String) -> (any MeetingSource.Type)? {
        all.first { type in type.identity.matchers.contains { $0.matches(bundleID) } }
    }

    static func source(for call: CallIdentity) -> (any MeetingSource)? {
        guard let type = sourceType(for: call.bundleID),
              type.identity.capability != .none else { return nil }
        return type.init(call: call)
    }
}
