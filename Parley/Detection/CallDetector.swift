import Foundation
import CoreAudio
import AppKit

/// A detected active call (a non-self process holding the mic).
struct DetectedCall: Equatable {
    let pid: pid_t
    let bundleID: String
    let displayName: String
    let known: Bool   // bundleID is in the conferencing list
}

/// Detects calls by watching which processes capture the microphone (Core Audio
/// process objects). Belt-and-suspenders for "cannot fail": a periodic poll AND
/// Core Audio property listeners both drive the same idempotent `evaluate()`,
/// with start/end debounce. Logs every transition to the `detect` category.
@MainActor
final class CallDetector: ObservableObject {
    /// Processes currently capturing input (for the Settings status readout).
    @Published private(set) var capturing: [AudioInputProcess] = []
    /// The debounced, confirmed active call (nil = no call).
    @Published private(set) var activeCall: DetectedCall?

    /// Fired (debounced) when a call starts / ends.
    var onCallStart: ((DetectedCall) -> Void)?
    var onCallEnd: ((DetectedCall) -> Void)?

    private let settings = AppSettings.shared
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let ownBundleID = Bundle.main.bundleIdentifier?.lowercased()
    private let startDebounce: TimeInterval = 1.5
    private let pollInterval: TimeInterval = 1.5

    private var pollTimer: Timer?
    private var listenerAddresses: [AudioObjectPropertyAddress] = []
    private var pending: DetectedCall?
    private var pendingSince: Date?
    private var lastActiveSeen: Date?
    private var lastHeartbeat = Date.distantPast
    private var running = false

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        AppLog.log("Detector started — poll \(pollInterval)s, grace \(settings.callEndGraceSeconds)s, ownPID \(ownPID), known apps: \(settings.conferencingBundleIDs.sorted().joined(separator: ", "))", category: "detect")
        addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
        addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice)
        if let dev = CallProcessProbe.defaultInputDevice() {
            addListener(object: dev, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate(source: "poll") }
        }
        evaluate(source: "start")
    }

    func stop() {
        guard running else { return }
        running = false
        pollTimer?.invalidate(); pollTimer = nil
        // (listener blocks are torn down with the process; kept simple for the
        // always-on background detector.)
        AppLog.log("Detector stopped", category: "detect")
    }

    private func addListener(object: AudioObjectID, selector: AudioObjectPropertySelector) {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.evaluate(source: "listener") }
        }
        if status == noErr { listenerAddresses.append(addr) }
    }

    // MARK: Core evaluation (idempotent; called by poll + listeners)

    private func evaluate(source: String) {
        guard running, settings.callDetectionEnabled else { return }
        let all = CallProcessProbe.processesCapturingInput()
        let nonSelf = all.filter { $0.pid != ownPID && $0.bundleID?.lowercased() != ownBundleID }
        capturing = nonSelf

        heartbeatIfDue(nonSelf: nonSelf)
        if settings.verboseDetectionLogging {
            let desc = nonSelf.map { "\($0.bundleID ?? "pid \($0.pid)")" }.joined(separator: ", ")
            AppLog.log("eval(\(source)) capturing=[\(desc)] active=\(activeCall?.bundleID ?? "none")", category: "detect")
        }

        let candidate = bestCandidate(from: nonSelf)
        let now = Date()

        if let active = activeCall {
            let stillActive = nonSelf.contains { $0.pid == active.pid }
                || nonSelf.contains { $0.bundleID?.lowercased() == active.bundleID }
            if stillActive {
                lastActiveSeen = now
            } else if let last = lastActiveSeen, now.timeIntervalSince(last) >= settings.callEndGraceSeconds {
                AppLog.log("CALL ENDED — \(active.displayName) [\(active.bundleID)] (mic released \(Int(now.timeIntervalSince(last)))s ago)", category: "detect")
                activeCall = nil; pending = nil; pendingSince = nil
                onCallEnd?(active)
            }
        } else if let cand = candidate {
            if pending?.pid == cand.pid, let since = pendingSince {
                if now.timeIntervalSince(since) >= startDebounce {
                    AppLog.log("CALL STARTED — \(cand.displayName) [\(cand.bundleID)] known=\(cand.known)", category: "detect")
                    activeCall = cand; lastActiveSeen = now; pending = nil; pendingSince = nil
                    onCallStart?(cand)
                }
            } else {
                pending = cand; pendingSince = now
                AppLog.log("candidate seen — \(cand.displayName) [\(cand.bundleID)] known=\(cand.known); confirming…", category: "detect")
            }
        } else {
            if pending != nil { pending = nil; pendingSince = nil }
        }
    }

    /// Prefer a known conferencing app; otherwise the first non-self capturer.
    private func bestCandidate(from caps: [AudioInputProcess]) -> DetectedCall? {
        let known = settings.conferencingBundleIDs
        if let hit = caps.first(where: { ($0.bundleID?.lowercased()).map(known.contains) ?? false }) {
            return DetectedCall(pid: hit.pid, bundleID: hit.bundleID!.lowercased(),
                                displayName: Self.displayName(hit.bundleID!), known: true)
        }
        if let any = caps.first(where: { $0.bundleID != nil }) {
            return DetectedCall(pid: any.pid, bundleID: any.bundleID!.lowercased(),
                                displayName: Self.displayName(any.bundleID!), known: false)
        }
        return nil
    }

    private func heartbeatIfDue(nonSelf: [AudioInputProcess]) {
        let now = Date()
        guard now.timeIntervalSince(lastHeartbeat) >= 30 else { return }
        lastHeartbeat = now
        AppLog.log("heartbeat — alive; capturing \(nonSelf.count) non-self process(es); active=\(activeCall?.bundleID ?? "none")", category: "detect")
    }

    static func displayName(_ bundleID: String) -> String {
        let map: [String: String] = [
            "com.microsoft.teams2": "Microsoft Teams", "com.microsoft.teams": "Microsoft Teams",
            "us.zoom.xos": "Zoom", "com.google.chrome": "Chrome", "com.apple.safari": "Safari",
            "com.microsoft.edgemac": "Edge", "company.thebrowser.browser": "Arc",
            "org.mozilla.firefox": "Firefox", "com.brave.browser": "Brave",
            "com.apple.voicememos": "Voice Memos",
        ]
        if let name = map[bundleID.lowercased()] { return name }
        // Fall back to the running app's localized name, else the last bundle component.
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier?.lowercased() == bundleID.lowercased() }),
           let name = app.localizedName { return name }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
