import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import EventKit
import Foundation

// MeetingProbe — run this *while in a real meeting* in each app you care
// about (Zoom, Teams, Meet-in-Chrome, …) and compare what each metadata
// source reports. Every section degrades gracefully and tells you which
// permission to grant when it can't see anything.
//
//   swift run                     one snapshot
//   swift run MeetingProbe --watch  re-snapshot every 5s (Ctrl-C to stop)

// MARK: - App lists

/// Parley's default auto-detect list (AppSettings.defaultConferencingBundleIDs)…
let parleyDefaults: Set<String> = [
    "com.microsoft.teams2",
    "com.microsoft.teams",
    "us.zoom.xos",
    "com.google.Chrome",
    "com.apple.Safari",
    "com.microsoft.edgemac",
    "company.thebrowser.Browser",
    "org.mozilla.firefox",
    "com.brave.Browser",
]

/// …plus extras worth probing while we're at it.
let extraCandidates: Set<String> = [
    "com.tinyspeck.slackmacgap",     // Slack huddles
    "com.hnc.Discord",               // Discord calls
    "Cisco-Systems.Spark",           // Webex
    "com.apple.FaceTime",
    "com.cron.electron",             // Notion Calendar (joins meetings)
]

let probedBundleIDs = parleyDefaults.union(extraCandidates)

/// URL substrings that identify a meeting tab in a browser.
let meetingURLMarkers = [
    "meet.google.com/", "zoom.us/j/", "zoom.us/wc/", "app.zoom.us/",
    "teams.microsoft.com/", "teams.live.com/", "webex.com/",
    "whereby.com/", "around.co/", "slack.com/huddle",
]

func header(_ title: String) {
    print("\n=== \(title) " + String(repeating: "=", count: max(0, 60 - title.count)))
}

// MARK: - 1. Core Audio mic snapshot (Parley's existing detection signal)

func micSection() {
    header("1. MIC CAPTURE (Core Audio — Parley's current signal)")
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
        print("  (could not enumerate audio process objects)"); return
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard count > 0,
          AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { print("  (no audio process objects)"); return }

    func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0; var s = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &s, &v) == noErr ? v : 0
    }
    func pidOf(_ obj: AudioObjectID) -> pid_t {
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: pid_t = 0; var s = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &s, &v) == noErr ? v : -1
    }
    func bidOf(_ obj: AudioObjectID) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: CFString? = nil; var s = UInt32(MemoryLayout<CFString?>.size)
        let ok = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(obj, &a, 0, nil, &s, $0) } == noErr
        guard ok, let cf, !(cf as String).isEmpty else { return nil }
        return cf as String
    }

    var capturing = 0
    for obj in ids where u32(obj, kAudioProcessPropertyIsRunningInput) == 1 {
        capturing += 1
        let pid = pidOf(obj)
        let bid = bidOf(obj) ?? "?"
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        let known = probedBundleIDs.contains(bid) ? "  ← in probe list" : ""
        print("  capturing input: pid=\(pid)  \(bid)  (\(name))\(known)")
    }
    if capturing == 0 { print("  nobody is capturing the mic — start/join a meeting and re-run") }
}

// MARK: - 2. CGWindowList titles (needs Screen Recording)

func cgWindowSection(pids: [pid_t: String]) {
    header("2. CGWindowList TITLES (needs Screen Recording permission)")
    let preflight = CGPreflightScreenCaptureAccess()
    print("  screen-recording permission: \(preflight ? "GRANTED" : "NOT granted — kCGWindowName will be absent)")")
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        print("  (CGWindowListCopyWindowInfo failed)"); return
    }
    var printed = 0
    for w in list {
        guard let ownerPID = w[kCGWindowOwnerPID as String] as? pid_t,
              let bid = pids[ownerPID] else { continue }
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let name = w[kCGWindowName as String] as? String
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) == true ? "onscreen" : "offscreen"
        print("  [\(bid)] \(owner) layer=\(layer) \(onscreen) title=\(name.map { "\"\($0)\"" } ?? "<nil>")")
        printed += 1
    }
    if printed == 0 { print("  no windows owned by probed apps") }
}

// MARK: - 3. Accessibility window titles (needs Accessibility)

func axSection(pids: [pid_t: String]) {
    header("3. ACCESSIBILITY TITLES (needs Accessibility permission)")
    let trusted = AXIsProcessTrusted()
    print("  accessibility permission: \(trusted ? "GRANTED" : "NOT granted — grant your terminal in System Settings > Privacy > Accessibility")")
    guard trusted else { return }

    func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    for (pid, bid) in pids.sorted(by: { $0.value < $1.value }) {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
            print("  [\(bid)] no AX windows (app may be agent-only or AX-opted-out)")
            continue
        }
        let focused = attr(app, kAXFocusedWindowAttribute)
        for (i, win) in windows.enumerated() {
            let title = attr(win, kAXTitleAttribute) as? String ?? "<nil>"
            let doc = attr(win, kAXDocumentAttribute) as? String
            let subrole = attr(win, kAXSubroleAttribute) as? String ?? "?"
            let isFocused = focused.map { CFEqual(($0 as! AXUIElement), win) } ?? false
            var line = "  [\(bid)] window[\(i)] subrole=\(subrole)\(isFocused ? " FOCUSED" : "") title=\"\(title)\""
            if let doc { line += " doc=\(doc)" }
            print(line)
        }
    }
}

// MARK: - 4. Browser tabs via AppleScript (needs Automation per browser)

func tabsSection() {
    header("4. BROWSER TABS via AppleScript (needs Automation permission)")
    struct Browser { let bundleID: String; let titleProp: String }
    let scriptable: [Browser] = [
        .init(bundleID: "com.google.Chrome", titleProp: "title"),
        .init(bundleID: "com.microsoft.edgemac", titleProp: "title"),
        .init(bundleID: "com.brave.Browser", titleProp: "title"),
        .init(bundleID: "company.thebrowser.Browser", titleProp: "title"), // Arc
        .init(bundleID: "com.apple.Safari", titleProp: "name"),
    ]
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

    for b in scriptable {
        guard running.contains(b.bundleID) else { continue }
        let src = """
        set out to ""
        tell application id "\(b.bundleID)"
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (URL of t) & "\\t" & (\(b.titleProp) of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        var err: NSDictionary?
        guard let result = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue else {
            let msg = (err?[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            print("  [\(b.bundleID)] AppleScript failed: \(msg) (grant Automation, or browser blocks scripting)")
            continue
        }
        var matched = 0
        for line in result.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (url, title) = (parts[0], parts[1])
            if meetingURLMarkers.contains(where: url.contains) {
                print("  [\(b.bundleID)] MEETING TAB title=\"\(title)\"")
                print("      url=\(url)")
                matched += 1
            }
        }
        if matched == 0 { print("  [\(b.bundleID)] no meeting tabs open") }
    }
    if running.contains("org.mozilla.firefox") {
        print("  [org.mozilla.firefox] Firefox has no AppleScript tab API — window title (AX) is the only signal")
    }
}

// MARK: - 5. Calendar events overlapping now (needs Calendar access)

func calendarSection() {
    header("5. CALENDAR (EventKit — needs Calendar full access)")
    let store = EKEventStore()
    let sema = DispatchSemaphore(value: 0)
    var granted = false
    store.requestFullAccessToEvents { ok, err in
        granted = ok
        if let err { print("  access error: \(err.localizedDescription)") }
        sema.signal()
    }
    sema.wait()
    guard granted else {
        print("  calendar permission NOT granted — grant your terminal in System Settings > Privacy > Calendars")
        return
    }
    let now = Date()
    // Window: events that started up to 4h ago or start within the next 15min —
    // mirrors how the app would correlate "mic just went live" with the calendar.
    let predicate = store.predicateForEvents(
        withStart: now.addingTimeInterval(-4 * 3600),
        end: now.addingTimeInterval(15 * 60),
        calendars: nil)
    let events = store.events(matching: predicate)
        .filter { !$0.isAllDay && $0.endDate > now }
        .sorted { $0.startDate < $1.startDate }
    if events.isEmpty { print("  no current/imminent events") }

    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
    for e in events {
        print("  EVENT \"\(e.title ?? "<untitled>")\"  \(fmt.string(from: e.startDate))–\(fmt.string(from: e.endDate))  cal=\(e.calendar.title)")
        if let org = e.organizer { print("      organizer: \(org.name ?? org.url.absoluteString)") }
        for a in e.attendees ?? [] {
            let status: String
            switch a.participantStatus {
            case .accepted: status = "accepted"; case .declined: status = "declined"
            case .tentative: status = "tentative"; default: status = "?"
            }
            print("      attendee: \(a.name ?? a.url.absoluteString)  <\(a.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""))>  [\(status)]")
        }
        if let loc = e.location, !loc.isEmpty { print("      location: \(loc)") }
        if let url = e.url { print("      url: \(url.absoluteString)") }
        if let notes = e.notes {
            // Meeting links commonly hide in the notes body — surface just those.
            for marker in meetingURLMarkers where notes.contains(marker) {
                if let range = notes.range(of: "https://[^\\s<>\"]*\(NSRegularExpression.escapedPattern(for: marker))[^\\s<>\"]*", options: .regularExpression) {
                    print("      link-in-notes: \(notes[range])")
                    break
                }
            }
        }
    }
}

// MARK: - main

func snapshot() {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("MeetingProbe snapshot @ \(fmt.string(from: Date()))")

    // Map running pids -> bundle id for every probed app (an app can have
    // several processes; NSWorkspace lists only the app-level ones, which is
    // what owns the windows).
    var pids: [pid_t: String] = [:]
    for app in NSWorkspace.shared.runningApplications {
        if let bid = app.bundleIdentifier, probedBundleIDs.contains(bid) {
            pids[app.processIdentifier] = bid
        }
    }
    header("0. RUNNING PROBED APPS")
    if pids.isEmpty { print("  none of the probed apps are running") }
    for (pid, bid) in pids.sorted(by: { $0.value < $1.value }) {
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        print("  \(bid)  pid=\(pid)  (\(name))")
    }

    micSection()
    cgWindowSection(pids: pids)
    axSection(pids: pids)
    tabsSection()
    calendarSection()
}

if CommandLine.arguments.contains("--watch") {
    while true {
        snapshot()
        print("\n--- sleeping 5s (Ctrl-C to stop) ---")
        Thread.sleep(forTimeInterval: 5)
    }
} else {
    snapshot()
}
