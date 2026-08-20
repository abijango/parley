import Foundation
import AppKit

/// Polls the conferencing app claimed by `MeetingSourceRegistry`. A dumb clock:
/// no bundle-id branches live here. AX work runs on `parley.meeting-ax`.
@MainActor
final class MeetingMetadataResolver {

    var onUpdate: ((SourceReading) -> Void)?

    var isPolling: Bool { timer != nil }

    private let settings = AppSettings.shared
    private let axQueue = DispatchQueue(label: "parley.meeting-ax", qos: .utility)
    private var timer: Timer?
    private var scanning = false
    private var call: DetectedCall?
    private var startedAt: Date?
    private var source: (any MeetingSource)?
    private var bestTitleAuthority: TitleAuthority?
    private var tick = 0

    private let tickInterval: TimeInterval = 2.5
    private let titleGiveUpSeconds: TimeInterval = 16

    func start(for call: DetectedCall) {
        if self.call?.bundleID == call.bundleID, timer != nil { return }
        stop()
        guard settings.metadataDiscoveryEnabled else { return }
        self.call = call
        startedAt = Date()
        bestTitleAuthority = nil
        tick = 0
        let identity = CallIdentity(bundleID: call.bundleID, pid: call.pid, startedAt: startedAt ?? Date())
        source = MeetingSourceRegistry.source(for: identity)
        AppLog.log("metadata poller started for \(call.bundleID) source=\(source != nil) trusted=\(AXClient.isTrusted())", category: "detect")
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFired() }
        }
        tickFired()
    }

    func enterPreviewMode() {
        timer?.invalidate(); timer = nil
        AppLog.log("metadata poller frozen (preview)", category: "detect")
    }

    func stop() {
        timer?.invalidate(); timer = nil
        call = nil
        source = nil
        scanning = false
        bestTitleAuthority = nil
    }

    private func tickFired() {
        guard let call, let source, !scanning else { return }
        guard AXClient.isTrusted() else { return }
        tick += 1

        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let wantTitle = elapsed < titleGiveUpSeconds && bestTitleAuthority != .callWindow
        let running = RunningApps.snapshot()
        let callPid = running.pid(exact: call.bundleID)
            ?? running.pid(prefix: call.bundleID)
            ?? call.pid
        let identity = CallIdentity(bundleID: call.bundleID, pid: callPid, startedAt: startedAt ?? Date())
        let needs = ScanNeeds(title: wantTitle, roster: true)
        let ctx = ScanContext(
            call: identity, tick: tick, elapsedSinceCallStart: elapsed,
            now: Date(), runningApps: running, needs: needs, tree: LiveMeetingUITree())

        scanning = true
        axQueue.async { [weak self] in
            let reading = source.read(ctx)
            Task { @MainActor in
                guard let self, self.call != nil else { return }
                self.scanning = false
                if let title = reading.title {
                    if let best = self.bestTitleAuthority, title.authority <= best, title.authority != .callWindow {
                        // Weaker or equal fallback — still deliver roster, drop the title.
                        self.onUpdate?(SourceReading(title: nil, roster: reading.roster))
                        return
                    }
                    self.bestTitleAuthority = title.authority
                }
                self.onUpdate?(reading)
            }
        }
    }
}
