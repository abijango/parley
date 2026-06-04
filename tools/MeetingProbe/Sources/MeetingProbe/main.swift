import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import EventKit
import Foundation

// MeetingProbe — run this *while in real meetings* (Teams, Zoom, Meet in a
// browser, …) and review the log afterwards to see which metadata source
// actually carries the meeting title for each app. Every section degrades
// gracefully and tells you which permission to grant when it can't see.
//
//   swift run MeetingProbe                        one full snapshot
//   swift run MeetingProbe --watch                log CHANGES every 5s (Ctrl-C to stop)
//   swift run MeetingProbe --watch --log probe.log  also append to a file
//   swift run MeetingProbe --watch --interval 10  custom poll interval

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
    "com.microsoft.Outlook",         // joins Teams meetings directly
]

let probedBundleIDs = parleyDefaults.union(extraCandidates)

/// Browsers capture the mic from a *helper* process (`com.brave.Browser.helper`,
/// `com.google.Chrome.helper`, …) — map those back to the parent app bundle.
/// FINDING (2026-06-04): Parley's CallDetector.bestCandidate() exact-matches
/// against the conferencing list, so browser calls are never "known" — the
/// app-side fix is this same prefix matching. Safari is unfixable this way:
/// its capture shows up as com.apple.WebKit.GPU (no Safari prefix).
func probedParentBundle(of bid: String) -> String? {
    if probedBundleIDs.contains(bid) { return bid }
    let lower = bid.lowercased()
    return probedBundleIDs.first { lower.hasPrefix($0.lowercased() + ".") }
}

/// URL substrings that identify a meeting tab in a browser.
let meetingURLMarkers = [
    "meet.google.com/", "zoom.us/j/", "zoom.us/wc/", "app.zoom.us/",
    "teams.microsoft.com/", "teams.live.com/", "webex.com/",
    "whereby.com/", "around.co/", "slack.com/huddle",
]

// MARK: - Output plumbing (print + optional log file)

var logHandle: FileHandle?

func emit(_ line: String) {
    print(line)
    if let logHandle, let data = (line + "\n").data(using: .utf8) {
        logHandle.write(data)
    }
}

func timestamp() -> String {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return fmt.string(from: Date())
}

// MARK: - 1. Core Audio mic snapshot (Parley's existing detection signal)

struct MicProc { let pid: pid_t; let bid: String? }

/// Every process currently capturing mic input (same API as CallProcessProbe).
func micCapture() -> [MicProc] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard count > 0,
          AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { return [] }

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

    return ids.compactMap { obj in
        guard u32(obj, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
        return MicProc(pid: pidOf(obj), bid: bidOf(obj))
    }
}

func micSection() -> [String] {
    let procs = micCapture()
    guard !procs.isEmpty else { return ["nobody is capturing the mic"] }
    return procs.map { p in
        let bid = p.bid ?? "?"
        let name = NSRunningApplication(processIdentifier: p.pid)?.localizedName ?? "?"
        let parent = probedParentBundle(of: bid)
        let known = parent.map { $0 == bid ? "  ← in probe list" : "  ← helper of \($0)" } ?? ""
        return "capturing input: pid=\(p.pid)  \(bid)  (\(name))\(known)"
    }
}

// MARK: - 2. CGWindowList titles (needs Screen Recording)

func cgWindowSection(pids: [pid_t: String]) -> [String] {
    var out: [String] = []
    if !CGPreflightScreenCaptureAccess() {
        out.append("screen-recording permission NOT granted — window titles will be <nil>")
    }
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return ["(CGWindowListCopyWindowInfo failed)"]
    }
    for w in list {
        guard let ownerPID = w[kCGWindowOwnerPID as String] as? pid_t,
              let bid = pids[ownerPID] else { continue }
        // Layer 0 = normal windows; skip status-bar/overlay layers to cut noise.
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        guard layer == 0 else { continue }
        let name = w[kCGWindowName as String] as? String
        let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) == true ? "onscreen" : "offscreen"
        out.append("[\(bid)] \(onscreen) title=\(name.map { "\"\($0)\"" } ?? "<nil>")")
    }
    if out.isEmpty { out.append("no normal-layer windows owned by probed apps") }
    return out
}

// MARK: - 3. Accessibility window titles (needs Accessibility)

func axSection(pids: [pid_t: String]) -> [String] {
    var out: [String] = []
    guard AXIsProcessTrusted() else {
        return ["accessibility permission NOT granted — grant your terminal in System Settings > Privacy & Security > Accessibility"]
    }

    func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    for (pid, bid) in pids.sorted(by: { $0.value < $1.value }) {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
            out.append("[\(bid)] no AX windows")
            continue
        }
        let focused = attr(app, kAXFocusedWindowAttribute)
        for (i, win) in windows.enumerated() {
            let title = attr(win, kAXTitleAttribute) as? String ?? "<nil>"
            let doc = attr(win, kAXDocumentAttribute) as? String
            let isFocused = focused.map { CFEqual(($0 as! AXUIElement), win) } ?? false
            var line = "[\(bid)] window[\(i)]\(isFocused ? " FOCUSED" : "") title=\"\(title)\""
            if let doc { line += " doc=\(doc)" }
            out.append(line)
        }
    }
    if out.isEmpty { out.append("no probed apps running") }
    return out
}

// MARK: - 3b. Deep AX tree dump (what ELSE an app emits: roster, timer, …)

/// Walks the full Accessibility tree of an app and prints every element that
/// carries text (title/description/value). For Electron/Chromium apps (Teams,
/// browsers) this mirrors the web app's ARIA tree — participant tiles, the
/// roster panel, call timer, mute states — but Chromium only *builds* that
/// tree once an assistive client announces itself, hence the
/// AXManualAccessibility / AXEnhancedUserInterface switches first.
/// First pipe-segment titles of Teams' MAIN window views — used to skip the
/// non-call window during auto-dumps (its Calendar view alone is ~600 nodes).
let teamsNavViews: Set<String> = [
    "Microsoft Teams", "Calendar", "Chat", "Activity", "Teams", "Calls",
    "OneDrive", "Apps", "Files", "Copilot",
]

func looksLikeCallWindow(_ title: String) -> Bool {
    let first = title.components(separatedBy: " | ").first?
        .trimmingCharacters(in: .whitespaces) ?? title
    return !teamsNavViews.contains(first) && !first.isEmpty
}

let browserBundles: Set<String> = [
    "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
    "company.thebrowser.Browser", "org.mozilla.firefox", "com.brave.Browser",
]

/// Browser windows: only walk ones whose title smells like a meeting —
/// a full browser AX tree (Gmail, docs, …) is thousands of irrelevant nodes.
func looksLikeMeetingBrowserWindow(_ title: String) -> Bool {
    ["Meet", "Zoom", "Microsoft Teams", "Webex", "Whereby", "Huddle"]
        .contains { title.contains($0) }
}

func axDeepDump(pid: pid_t, windowFilter: ((String) -> Bool)? = nil) -> [String] {
    guard AXIsProcessTrusted() else {
        return ["accessibility permission NOT granted — cannot walk the AX tree"]
    }
    let app = AXUIElementCreateApplication(pid)
    // Documented Electron switch + the Chromium one; harmless where unsupported.
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    // Give the renderer a moment to materialize the tree after the switch.
    Thread.sleep(forTimeInterval: 1.0)

    func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    func text(_ v: AnyObject?) -> String? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    var out: [String] = []
    var visited = 0
    let printCap = 800, visitCap = 20000

    func walk(_ el: AXUIElement, depth: Int) {
        guard visited < visitCap, out.count < printCap, depth <= 40 else { return }
        visited += 1
        let role = attr(el, kAXRoleAttribute) as? String ?? "?"
        var parts: [String] = []
        if let t = text(attr(el, kAXTitleAttribute)) { parts.append("title=\"\(t.prefix(140))\"") }
        if let d = text(attr(el, kAXDescriptionAttribute)) { parts.append("desc=\"\(d.prefix(140))\"") }
        if let v = text(attr(el, kAXValueAttribute)) { parts.append("value=\"\(v.prefix(140))\"") }
        if !parts.isEmpty {
            out.append(String(repeating: " ", count: min(depth, 16)) + "[\(role)] " + parts.joined(separator: " "))
        }
        for child in (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            walk(child, depth: depth + 1)
        }
    }

    let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if windows.isEmpty { return ["no AX windows to walk"] }
    var walkedAny = false
    for (i, win) in windows.enumerated() {
        let title = attr(win, kAXTitleAttribute) as? String ?? ""
        if let windowFilter, !windowFilter(title) {
            out.append("WINDOW[\(i)] \"\(title)\" — skipped (not a call window)")
            continue
        }
        walkedAny = true
        out.append("WINDOW[\(i)] \"\(title)\"")
        walk(win, depth: 1)
    }
    if !walkedAny { out.append("(no window matched the call-window filter — nothing walked)") }
    out.append("(walked \(visited) AX nodes\(out.count >= printCap ? ", output truncated at \(printCap) lines" : ""))")
    return out
}

/// Mask volatile timer-ish values (elapsed time counters) so repeated dumps
/// only register as "changed" when real content (e.g. the roster) appears.
func maskTimers(_ lines: [String]) -> [String] {
    lines.map {
        $0.replacingOccurrences(
            of: #"\b\d{1,2}:\d{2}(:\d{2})?\b"#,
            with: "MM:SS",
            options: .regularExpression)
    }
}

// MARK: - 4. Browser tabs via AppleScript (needs Automation per browser)

func tabsSection() -> [String] {
    var out: [String] = []
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
            out.append("[\(b.bundleID)] AppleScript failed: \(msg)")
            continue
        }
        var matched = 0
        for line in result.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (url, title) = (parts[0], parts[1])
            if meetingURLMarkers.contains(where: url.contains) {
                out.append("[\(b.bundleID)] MEETING TAB title=\"\(title)\" url=\(url)")
                matched += 1
            }
        }
        if matched == 0 { out.append("[\(b.bundleID)] no meeting tabs open") }
    }
    if running.contains("org.mozilla.firefox") {
        out.append("[org.mozilla.firefox] no AppleScript tab API — AX window title is the only signal")
    }
    if out.isEmpty { out.append("no scriptable browsers running") }
    return out
}

// MARK: - 5. Calendar events overlapping now (needs Calendar access)
// NOTE: only sees calendars synced into macOS Calendar.app (incl. an Outlook/
// Exchange account IF added there). Pure Outlook-app accounts won't show.

func calendarSection() -> [String] {
    var out: [String] = []
    let store = EKEventStore()
    let sema = DispatchSemaphore(value: 0)
    var granted = false
    store.requestFullAccessToEvents { ok, _ in granted = ok; sema.signal() }
    sema.wait()
    guard granted else {
        return ["calendar permission NOT granted (or no synced calendars) — Outlook-only accounts are invisible to EventKit"]
    }
    let now = Date()
    let predicate = store.predicateForEvents(
        withStart: now.addingTimeInterval(-4 * 3600),
        end: now.addingTimeInterval(15 * 60),
        calendars: nil)
    let events = store.events(matching: predicate)
        .filter { !$0.isAllDay && $0.endDate > now }
        .sorted { $0.startDate < $1.startDate }
    if events.isEmpty { return ["no current/imminent events visible to EventKit"] }

    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
    for e in events {
        out.append("EVENT \"\(e.title ?? "<untitled>")\"  \(fmt.string(from: e.startDate))–\(fmt.string(from: e.endDate))  cal=\(e.calendar.title)")
        if let org = e.organizer { out.append("    organizer: \(org.name ?? org.url.absoluteString)") }
        for a in e.attendees ?? [] {
            let email = a.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            out.append("    attendee: \(a.name ?? email)  <\(email)>")
        }
        if let loc = e.location, !loc.isEmpty { out.append("    location: \(loc)") }
        if let url = e.url { out.append("    url: \(url.absoluteString)") }
        if let notes = e.notes {
            for marker in meetingURLMarkers where notes.contains(marker) {
                if let range = notes.range(of: "https://[^\\s<>\"]*\(NSRegularExpression.escapedPattern(for: marker))[^\\s<>\"]*", options: .regularExpression) {
                    out.append("    link-in-notes: \(notes[range])")
                    break
                }
            }
        }
    }
    return out
}

// MARK: - Snapshot assembly

func runningProbedApps() -> [pid_t: String] {
    var pids: [pid_t: String] = [:]
    for app in NSWorkspace.shared.runningApplications {
        if let bid = app.bundleIdentifier, probedBundleIDs.contains(bid) {
            pids[app.processIdentifier] = bid
        }
    }
    return pids
}

func collectSections() -> [(name: String, lines: [String])] {
    let pids = runningProbedApps()
    var appLines = pids.sorted(by: { $0.value < $1.value }).map { pid, bid in
        "\(bid)  pid=\(pid)  (\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"))"
    }
    if appLines.isEmpty { appLines = ["none of the probed apps are running"] }
    return [
        ("0. RUNNING PROBED APPS", appLines),
        ("1. MIC CAPTURE (Core Audio — Parley's current signal)", micSection()),
        ("2. CGWindowList TITLES (needs Screen Recording)", cgWindowSection(pids: pids)),
        ("3. ACCESSIBILITY TITLES (needs Accessibility)", axSection(pids: pids)),
        ("4. BROWSER MEETING TABS (AppleScript, needs Automation)", tabsSection()),
        ("5. CALENDAR / EventKit (needs Calendar access)", calendarSection()),
    ]
}

func printSection(_ name: String, _ lines: [String]) {
    emit("[\(timestamp())] === \(name)")
    for line in lines { emit("    \(line)") }
}

// MARK: - main

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--log"), i + 1 < args.count {
    let path = (args[i + 1] as NSString).expandingTildeInPath
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    logHandle = FileHandle(forWritingAtPath: path)
    logHandle?.seekToEndOfFile()
}
let interval: TimeInterval = {
    if let i = args.firstIndex(of: "--interval"), i + 1 < args.count, let v = Double(args[i + 1]) { return v }
    return 5
}()

if let i = args.firstIndex(of: "--dump-ax"), i + 1 < args.count {
    // One-shot deep dump of a running app's AX tree: --dump-ax com.microsoft.teams2
    let bid = args[i + 1]
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) else {
        emit("\(bid) is not running"); exit(1)
    }
    printSection("DEEP AX DUMP [\(bid)]", axDeepDump(pid: app.processIdentifier))
} else if args.contains("--watch") {
    emit("[\(timestamp())] MeetingProbe watch started (interval \(Int(interval))s) — logging CHANGES only")
    var last: [String: [String]] = [:]
    var callStart: [String: Date] = [:]   // probed bundle id -> when it took the mic
    var lastDump: [String: [String]] = [:]  // last (timer-masked) dump per bundle
    var lastDumpAt: [String: Date] = [:]
    while true {
        for (name, lines) in collectSections() where last[name] != lines {
            printSection(name, lines)
            last[name] = lines
        }

        // Auto deep-dump the CALL WINDOW of each in-call probed app: first at
        // ~10s (title settled), then every 30s — logged only when the masked
        // tree actually changed (e.g. the roster pane was opened).
        // Helper processes (browser renderers) map back to the parent app —
        // that's whose windows we dump.
        let capturing = Set(micCapture().compactMap { $0.bid.flatMap(probedParentBundle) })
        for bid in capturing {
            if callStart[bid] == nil { callStart[bid] = Date() }
            let inCall = Date().timeIntervalSince(callStart[bid]!)
            let sinceDump = lastDumpAt[bid].map { Date().timeIntervalSince($0) } ?? .infinity
            guard inCall >= 10, sinceDump >= 30 else { continue }
            if let pid = runningProbedApps().first(where: { $0.value == bid })?.key {
                // Teams: skip the main window's nav views (Calendar alone is
                // ~600 nodes of the user's whole week). Browsers: only walk
                // meeting-looking windows. Other apps: walk all.
                let filter: ((String) -> Bool)? =
                    bid.hasPrefix("com.microsoft.teams") ? looksLikeCallWindow
                    : browserBundles.contains(bid) ? looksLikeMeetingBrowserWindow
                    : nil
                let dump = maskTimers(axDeepDump(pid: pid, windowFilter: filter))
                lastDumpAt[bid] = Date()
                if dump != lastDump[bid] {
                    printSection("6. DEEP AX DUMP [\(bid)] (\(Int(inCall))s into call, call window only)", dump)
                    lastDump[bid] = dump
                }
            }
        }
        for bid in callStart.keys where !capturing.contains(bid) {
            callStart[bid] = nil
            lastDump[bid] = nil
            lastDumpAt[bid] = nil
        }

        Thread.sleep(forTimeInterval: interval)
    }
} else {
    emit("MeetingProbe snapshot @ \(timestamp())")
    for (name, lines) in collectSections() { printSection(name, lines) }
}
