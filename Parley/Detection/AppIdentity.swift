import Foundation

/// Raw bundle ids come from Core Audio.
enum AppIdentity {
    static func canonical(_ rawBundleID: String, known: Set<String>) -> String {
        let bid = rawBundleID.lowercased()
        if let alias = MeetingSourceRegistry.helperAliases[bid] {
            return alias
        }
        let parents = known.map { $0.lowercased() }
        if let parent = parents.first(where: { bid == $0 || bid.hasPrefix($0 + ".") }) {
            return parent
        }
        return bid
    }
}

struct CapturingProcess: Equatable {
    var pid: pid_t
    var bundleID: String?
}

struct CallDetectionState: Equatable {
    var active: DetectedCall?
    var pending: DetectedCall?
    var pendingSince: Date?
    var lastActiveSeen: Date?
}

enum CallDetectionEvent: Equatable {
    case candidate(DetectedCall)
    case started(DetectedCall)
    case ended(DetectedCall, after: TimeInterval)
}

@MainActor
enum CallDetection {
    static func step(
        _ state: inout CallDetectionState,
        capturers: [CapturingProcess],
        now: Date,
        known: Set<String>,
        grace: TimeInterval,
        startDebounce: TimeInterval
    ) -> CallDetectionEvent? {
        let candidate = bestCandidate(from: capturers, known: known)
        if let active = state.active {
            let stillActive = capturers.contains { $0.pid == active.pid }
                || capturers.contains { process in
                    guard let bid = process.bundleID else { return false }
                    return AppIdentity.canonical(bid, known: known) == active.bundleID
                }
            if stillActive {
                state.lastActiveSeen = now
                return nil
            }
            if let last = state.lastActiveSeen, now.timeIntervalSince(last) >= grace {
                let after = now.timeIntervalSince(last)
                state.active = nil
                state.pending = nil
                state.pendingSince = nil
                return .ended(active, after: after)
            }
            return nil
        }
        guard let cand = candidate else {
            if state.pending != nil {
                state.pending = nil
                state.pendingSince = nil
            }
            return nil
        }
        if state.pending?.bundleID == cand.bundleID, let since = state.pendingSince {
            if now.timeIntervalSince(since) >= startDebounce {
                state.active = cand
                state.lastActiveSeen = now
                state.pending = nil
                state.pendingSince = nil
                return .started(cand)
            }
            return nil
        }
        state.pending = cand
        state.pendingSince = now
        return .candidate(cand)
    }

    private static func bestCandidate(from caps: [CapturingProcess], known: Set<String>) -> DetectedCall? {
        for cap in caps {
            guard let bid = cap.bundleID else { continue }
            let canonical = AppIdentity.canonical(bid, known: known)
            if known.contains(where: { $0.lowercased() == canonical }) {
                return DetectedCall(pid: cap.pid, bundleID: canonical,
                                    displayName: CallDetector.displayName(canonical), known: true)
            }
        }
        guard let any = caps.first(where: { $0.bundleID != nil }), let raw = any.bundleID else { return nil }
        let canonical = AppIdentity.canonical(raw, known: known)
        return DetectedCall(pid: any.pid, bundleID: canonical,
                            displayName: CallDetector.displayName(canonical), known: false)
    }
}
