import Foundation
import AVFoundation
import AppKit
import ApplicationServices

/// Microphone permission helper. The system-audio (tap) permission has no
/// pre-check API — it prompts on first tap creation — so only the mic is
/// handled proactively here.
enum PermissionManager {
    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// True only once the user has actively denied/restricted the mic (not the
    /// not-yet-asked state) — so we can show a persistent "fix this" banner
    /// rather than nagging before the first prompt.
    static func microphoneDenied() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: return true
        default: return false
        }
    }

    /// Requests mic access, returning the granted result on the main actor.
    @MainActor
    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false   // denied / restricted — user must change System Settings
        }
    }

    /// Opens System Settings → Privacy & Security → Microphone.
    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// Opens System Settings → Privacy & Security. The system-audio-capture
    /// permission (`NSAudioCaptureUsageDescription`, macOS 14.4+) has no stable
    /// dedicated deep-link anchor, so we land on the Privacy root where the user
    /// can find the audio-recording entry.
    static func openPrivacySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy")
    }

    // MARK: Accessibility (meeting-metadata discovery)

    /// Accessibility (AX) trust — used to read meeting titles/rosters from
    /// conferencing apps. Unlike the mic, AX has NO async request API: the OS
    /// never prompts on use; the user must flip the toggle in System Settings.
    static func accessibilityAuthorized() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the one-time system dialog that offers to open System Settings →
    /// Accessibility (the closest thing AX has to a permission prompt).
    static func promptForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
