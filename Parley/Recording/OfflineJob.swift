import Foundation

/// An immutable snapshot of one recorded session's offline-processing work, queued on
/// `OfflineProcessingService`. Everything the worker needs lives here — it must NEVER
/// read live controller state (`engine`, `sessionDirectory`, `lastTranscriptURL`,
/// `attendees`). That decoupling is the whole point: a new recording can freely mutate
/// the controller while an older session's job runs, with no chance of cross-talk (the
/// data-loss bug where a finishing pass compacted the *live* recording's audio).
struct OfflineJob: Identifiable, Equatable {
    /// The recording session folder (parent of the `.caf` archives + `session.json`).
    let sessionDir: URL
    /// The transcript file this pass should (guardedly) rewrite with attributed text.
    let transcriptURL: URL
    let micArchiveURL: URL
    let systemArchiveURL: URL
    let mixedURL: URL
    // Metadata snapshot at enqueue time, used when rewriting the transcript so the
    // worker never reaches back into the controller's (possibly reassigned) fields.
    let title: String
    let attendees: String
    let filing: String
    /// Open the speaker-review sheet when done (History "Detect speakers"); the silent
    /// automatic post-stop pass leaves this false and surfaces unnamed speakers in History.
    let presentReviewWhenDone: Bool
    /// Whether to chain a Claude summary once speakers are resolved (snapshot of the
    /// auto-summarize setting at enqueue time).
    let autoSummarize: Bool
    /// Fluid ASR stack for this session.
    let fluidAsrProfile: FluidAsrProfile
    /// When this pass may start. Snapshotted at enqueue.
    let schedule: TranscriptionTiming
    let windowStartHour: Int
    let windowEndHour: Int
    /// Transcribe Now. Mutable so the queue can mark a waiting job without rebuilding it.
    var forced: Bool
    /// FluidAudio batch profile, Neural Engine, GPU toggle ignored.
    let accurateBatch: Bool

    /// Stable id = session folder name (e.g. "2026-06-08-160310"); also the manifest id.
    var id: String { sessionDir.lastPathComponent }

    /// Build a job from a session directory + the saved manifest, resolving the standard
    /// archive paths. Returns nil if the manifest carries no transcript link to rewrite.
    init?(dir: URL, manifest: SessionManifest, autoSummarize: Bool,
          fallbackAsrProfile: FluidAsrProfile) {
        guard let path = manifest.transcriptPath, !path.isEmpty else { return nil }
        self.sessionDir = dir
        self.transcriptURL = URL(fileURLWithPath: path)
        self.micArchiveURL = dir.appendingPathComponent("mic.caf")
        self.systemArchiveURL = dir.appendingPathComponent("system.caf")
        self.mixedURL = dir.appendingPathComponent("mixed.caf")
        self.title = manifest.title
        self.attendees = manifest.attendees
        self.filing = manifest.filing
        self.presentReviewWhenDone = manifest.presentReviewWhenDone ?? false
        self.autoSummarize = autoSummarize
        self.fluidAsrProfile = FluidAsrBinding.profile(
            stored: manifest.fluidAsrProfile, fallback: fallbackAsrProfile)
        self.schedule = manifest.transcriptionTiming ?? .afterCall
        self.windowStartHour = manifest.transcriptionWindowStartHour ?? 22
        self.windowEndHour = manifest.transcriptionWindowEndHour ?? 7
        self.forced = manifest.offlineForced == true
        self.accurateBatch = manifest.batchMode == true
    }

    /// Direct construction (post-stop / History flows), where paths and metadata are
    /// known without re-reading the manifest.
    init(sessionDir: URL, transcriptURL: URL, title: String, attendees: String,
         filing: String, presentReviewWhenDone: Bool, autoSummarize: Bool,
         fluidAsrProfile: FluidAsrProfile,
         schedule: TranscriptionTiming = .afterCall, windowStartHour: Int = 22,
         windowEndHour: Int = 7, forced: Bool = false, accurateBatch: Bool = false) {
        self.sessionDir = sessionDir
        self.transcriptURL = transcriptURL
        self.micArchiveURL = sessionDir.appendingPathComponent("mic.caf")
        self.systemArchiveURL = sessionDir.appendingPathComponent("system.caf")
        self.mixedURL = sessionDir.appendingPathComponent("mixed.caf")
        self.title = title
        self.attendees = attendees
        self.filing = filing
        self.presentReviewWhenDone = presentReviewWhenDone
        self.autoSummarize = autoSummarize
        self.fluidAsrProfile = fluidAsrProfile
        self.schedule = schedule
        self.windowStartHour = windowStartHour
        self.windowEndHour = windowEndHour
        self.forced = forced
        self.accurateBatch = accurateBatch
    }
}
