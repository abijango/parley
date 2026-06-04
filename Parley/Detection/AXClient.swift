import Foundation
import ApplicationServices

/// One node of an app's Accessibility tree, flattened depth-first by
/// `AXClient.walk`. `depth` preserves the hierarchy: a node's subtree is the
/// run of following nodes with greater depth.
struct AXNode: Equatable {
    let role: String
    let title: String?
    let desc: String?
    let value: String?
    let depth: Int

    /// First non-empty of title/desc/value — the node's human-readable text.
    var anyText: String? { title ?? desc ?? value }
}

/// Thin Accessibility wrapper — the only file that talks to the AX C API.
/// All functions are synchronous and intended to be called from the resolver's
/// background queue (Electron trees can take hundreds of ms to walk; never on
/// the main actor). Shapes validated against live Teams/Zoom/Outlook trees by
/// `tools/MeetingProbe` (see docs/MEETING_METADATA_INVESTIGATION.md).
enum AXClient {

    static func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Chromium/Electron apps (Teams, browsers) only materialize their full AX
    /// tree once an assistive client announces itself; these switches are the
    /// documented way to ask. Harmless on native apps. Allow ~1s for the tree
    /// to build after the first call per pid.
    static func enableElectronAX(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// The app-level AX windows of a pid (real UI windows only — unlike
    /// CGWindowList, AX doesn't surface Chromium's invisible helper surfaces).
    static func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        return (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let v = attribute(app, kAXFocusedWindowAttribute) else { return nil }
        return (v as! AXUIElement)
    }

    static func title(of element: AXUIElement) -> String? {
        attribute(element, kAXTitleAttribute) as? String
    }

    /// Bounded depth-first flatten of an element's subtree. Caps make a worst-
    /// case Electron walk (whole-calendar DOM) finite; parse failures upstream
    /// degrade gracefully, so truncation is acceptable.
    static func walk(_ root: AXUIElement, visitCap: Int = 20_000, maxDepth: Int = 40) -> [AXNode] {
        var out: [AXNode] = []
        var visited = 0

        func recurse(_ el: AXUIElement, depth: Int) {
            guard visited < visitCap, depth <= maxDepth else { return }
            visited += 1
            out.append(AXNode(
                role: attribute(el, kAXRoleAttribute) as? String ?? "?",
                title: text(attribute(el, kAXTitleAttribute)),
                desc: text(attribute(el, kAXDescriptionAttribute)),
                value: text(attribute(el, kAXValueAttribute)),
                depth: depth))
            for child in (attribute(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                recurse(child, depth: depth + 1)
            }
        }

        recurse(root, depth: 0)
        return out
    }

    // MARK: plumbing

    private static func attribute(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func text(_ v: AnyObject?) -> String? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
}
