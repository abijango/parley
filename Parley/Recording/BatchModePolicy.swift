import Foundation
import UserNotifications

/// When a Batch mode recording is allowed to run its transcription pass.
enum TranscriptionTiming: String, Codable, Equatable, Sendable {
    case afterCall
    case window
}

/// The one decision for "may this offline job start now?"
/// Recording blocks the worker only when Batch mode is off.
/// A forced job ignores the window and a manual hold.
/// A held job keeps the quiet-hours release and ignores the transcription window.
enum BatchModePolicy {
    static func profile(language: String) -> FluidAsrProfile {
        FluidAsrRouting.isEnglishStreamingLanguage(language) ? .parakeetUnified : .parakeetV3
    }

    /// The profile written at record start wins. Language is only the fallback
    /// when a crash left no profile on the manifest.
    static func pinnedProfile(stored: FluidAsrProfile?, language: String) -> FluidAsrProfile {
        stored ?? profile(language: language)
    }

    /// Batch mode keeps the schedule written at record start. Off always means
    /// after the call, so a window picked while the switch is disabled cannot apply.
    static func pinnedSchedule(
        batchMode: Bool, stored: TranscriptionTiming?, live: TranscriptionTiming
    ) -> TranscriptionTiming {
        guard batchMode else { return .afterCall }
        return stored ?? live
    }

    static func mayRun(
        batchMode: Bool,
        recordingActive: Bool,
        held: Bool,
        heldMayDrain: Bool,
        forced: Bool,
        schedule: TranscriptionTiming,
        inWindow: Bool
    ) -> Bool {
        if recordingActive && !batchMode { return false }
        if forced { return true }
        if held { return heldMayDrain }
        if schedule == .window && !inWindow { return false }
        return true
    }

    /// Batch mode queues a pass whenever audio landed. Otherwise only a speaker
    /// engine with a non-empty live timeline does, which is the previous rule.
    static func shouldQueue(batchMode: Bool, isSpeakerEngine: Bool, segmentCount: Int) -> Bool {
        if batchMode { return true }
        return isSpeakerEngine && segmentCount > 0
    }

    /// The idle wait is for summaries, and for speaker passes recorded with
    /// Batch mode off. Batch transcription starts as soon as the audio is saved
    /// and keeps running while the next call records.
    static func waitsForIdleDrain(batchMode: Bool) -> Bool {
        !batchMode
    }
}

enum SpeakerReadyNotifier {
    static let categoryID = "parley.speakersReady"
    static let transcriptPathKey = "transcriptPath"

    static func post(title: String, transcriptPath: String) {
        let content = UNMutableNotificationContent()
        content.title = "Speakers ready to review"
        content.body = title.isEmpty ? "A transcript in History still has unnamed speakers." : title
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = [transcriptPathKey: transcriptPath]
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
