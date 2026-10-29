import Foundation
import SwiftUI

/// How non-microphone audio is captured.
enum CaptureMode: String, CaseIterable, Identifiable {
    case systemWide   // everything you hear, minus our own process
    case perApp       // a single chosen application

    var id: String { rawValue }
    var label: String {
        switch self {
        case .systemWide: return "System-wide"
        case .perApp: return "Specific app"
        }
    }
}

/// Parakeet ASR variant used by the FluidAudio engine. Default is v3.
enum FluidParakeetVersion: String, CaseIterable, Identifiable {
    case v3   // Parakeet TDT 0.6b v3 — multilingual (default)
    case v2   // Parakeet TDT 0.6b v2 — English-only

    var id: String { rawValue }
    var label: String {
        switch self {
        case .v3: return "v3 (multilingual)"
        case .v2: return "v2 (English)"
        }
    }

    /// Compact friendly name for the transport bar (version detail lives in Settings).
    var displayName: String { "Parakeet" }
}

/// Chunk-size tier (ms per chunk) for the FluidAudio multilingual *streaming*
/// live ASR (Nemotron). Smaller = lower latency, larger = higher accuracy. 560
/// is the lowest multilingual tier; 2240 is the library's recommended balance.
/// The accurate final transcript still comes from the offline TDT v3 re-pass,
/// so the live tier is purely a latency/quality knob for in-session feedback.
enum FluidStreamingTier: Int, CaseIterable, Identifiable {
    case ms560 = 560
    case ms1120 = 1120
    case ms2240 = 2240
    case ms4480 = 4480

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .ms560: return "560 ms (lowest latency)"
        case .ms1120: return "1120 ms"
        case .ms2240: return "2240 ms (recommended)"
        case .ms4480: return "4480 ms (highest accuracy)"
        }
    }
}

/// Which engine generates meeting summaries. Shared prompt; different runtime.
/// Cursor Agent variants use CLI model ids as `rawValue` so staging files are
/// `.staging/<base>.composer-2.5.md` etc. — keeps Claude/Grok/Cursor
/// side-by-side for quality benchmarks.
enum SummaryBackend: String, CaseIterable, Identifiable {
    case claude
    case grok
    case composer25 = "composer-2.5"
    case composer25Fast = "composer-2.5-fast"
    case cursorGrok46Fast = "cursor-grok-4.6-high-fast"
    case cursorGrok47Low = "grok-4.7-low"
    case cursorGrok47Medium = "grok-4.7-medium"
    case cursorGrok47MediumFast = "grok-4.7-medium-fast"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .grok: return "Grok CLI"
        case .composer25: return "Composer 2.5"
        case .composer25Fast: return "Composer 2.5 Fast"
        case .cursorGrok46Fast: return "Cursor Grok 4.6 Fast"
        case .cursorGrok47Low: return "Cursor Grok 4.7 Low"
        case .cursorGrok47Medium: return "Cursor Grok 4.7 Medium"
        case .cursorGrok47MediumFast: return "Cursor Grok 4.7 Medium Fast"
        }
    }
    var blurb: String {
        switch self {
        case .claude: return "Runs `claude -p` with your Claude Code login."
        case .grok: return "Runs `grok -p` with your Grok CLI login."
        case .composer25:
            return "Runs `cursor agent -p --mode ask` with model `composer-2.5` (Cursor subscription)."
        case .composer25Fast:
            return "Runs `cursor agent -p --mode ask` with model `composer-2.5-fast`."
        case .cursorGrok46Fast:
            return "Runs `cursor agent -p --mode ask` with model `cursor-grok-4.6-high-fast`."
        case .cursorGrok47Low:
            return "Runs `cursor agent -p --mode ask` with model `grok-4.7-low`."
        case .cursorGrok47Medium:
            return "Runs `cursor agent -p --mode ask` with model `grok-4.7-medium`."
        case .cursorGrok47MediumFast:
            return "Runs `cursor agent -p --mode ask` with model `grok-4.7-medium-fast`."
        }
    }

    /// The CLI that executes this backend.
    enum Provider { case claude, grok, cursor }

    var provider: Provider {
        switch self {
        case .claude: return .claude
        case .grok: return .grok
        case .composer25, .composer25Fast, .cursorGrok46Fast, .cursorGrok47Low, .cursorGrok47Medium, .cursorGrok47MediumFast:
            return .cursor
        }
    }

    /// True when this backend is invoked via the Cursor Agent CLI.
    var isCursorAgent: Bool { provider == .cursor }

    /// CLI `--model` id (same as `rawValue` for Cursor backends).
    var cursorModelID: String? { isCursorAgent ? rawValue : nil }

    /// What the in-progress summary bar shows. Cursor backends use the CLI id
    /// (`grok-4.7-medium-fast`); the others keep their display name.
    var statusName: String { cursorModelID ?? displayName }

    /// Maps persisted raw values, including retired Cursor Grok 4.5 ids.
    static func resolved(_ raw: String) -> SummaryBackend? {
        switch raw {
        case "cursor-grok-4.5-high", "cursor-grok-4.5-high-fast":
            return .cursorGrok46Fast
        default:
            return Self(rawValue: raw)
        }
    }

    /// Backends suitable for the Summary v2 writer role.
    static var writerBackends: [SummaryBackend] {
        [.composer25, .composer25Fast, .claude, .grok, .cursorGrok46Fast, .cursorGrok47Low, .cursorGrok47Medium, .cursorGrok47MediumFast]
    }

    /// Backends suitable for the Summary v2 checker role.
    static var checkerBackends: [SummaryBackend] {
        [.cursorGrok47MediumFast, .cursorGrok46Fast, .cursorGrok47Low, .cursorGrok47Medium, .composer25, .composer25Fast, .claude, .grok]
    }
}

/// Summary generation pipeline: classic single-backend or v2 writer→checker.
enum SummaryPipeline: String, CaseIterable, Identifiable, Codable {
    case classic
    case v2

    var id: String { rawValue }
    var label: String {
        switch self {
        case .classic: return "Summary v1 (single backend)"
        case .v2: return "Summary v2 (writer + checker)"
        }
    }
}

/// How meeting image attachments are fed into summarization.
enum AttachmentUnderstanding: String, CaseIterable, Identifiable {
    case off
    case captionsOnly
    case vision

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .captionsOnly: return "Captions only"
        case .vision: return "Vision (describe images)"
        }
    }
    var blurb: String {
        switch self {
        case .off: return "Attachments are stored in the note but not mentioned in the summary prompt."
        case .captionsOnly: return "Filenames and captions are injected as text (no pixels sent)."
        case .vision: return "A Cursor agent vision pass describes images and may draft mermaid diagrams before summarizing."
        }
    }
}

/// App-wide settings persisted via UserDefaults (`@AppStorage`).
/// TODO(app-name): the AppStorage keys are namespaced with a literal prefix below.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private init() {
        // Tests construct this singleton against the developer's defaults domain.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            migrateActiveCursorGrokTo47Medium()
            migrateActiveCursorGrokTo47MediumFast()
        }
    }

    /// One-shot. The 4.7 options were added while the saved summarizer stayed on
    /// `cursor-grok-4.6-high-fast`, so the progress bar kept saying 4.6.
    /// Moves that selection to `grok-4.7-medium`. Picking 4.6 again sticks.
    private func migrateActiveCursorGrokTo47Medium() {
        let flag = "parley.didMigrateSummaryBackendToGrok47Medium"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let previous = SummaryBackend.cursorGrok46Fast.rawValue
        let next = SummaryBackend.cursorGrok47Medium.rawValue
        if summaryBackendRaw == previous { summaryBackendRaw = next }
        if summaryCheckerBackendRaw == previous { summaryCheckerBackendRaw = next }
        UserDefaults.standard.set(true, forKey: flag)
    }

    /// One-shot. Medium Fast is the summarizer default. Moves a saved
    /// `grok-4.7-medium` selection (the previous default) onto
    /// `grok-4.7-medium-fast`. Picking Medium again sticks.
    private func migrateActiveCursorGrokTo47MediumFast() {
        let flag = "parley.didMigrateSummaryBackendToGrok47MediumFast"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let previous = SummaryBackend.cursorGrok47Medium.rawValue
        let next = SummaryBackend.cursorGrok47MediumFast.rawValue
        if summaryBackendRaw == previous { summaryBackendRaw = next }
        if summaryCheckerBackendRaw == previous { summaryCheckerBackendRaw = next }
        UserDefaults.standard.set(true, forKey: flag)
    }

    private enum Key {
        // TODO(app-name): key prefix
        static let vaultPath = "parley.vaultPath"
        static let captureMode = "parley.captureMode"
        static let autoRunClaude = "parley.autoRunClaude"
        static let summaryBackend = "parley.summaryBackend"
        static let summaryPipeline = "parley.summaryPipeline"
        static let summaryWriterBackend = "parley.summaryWriterBackend"
        static let summaryCheckerBackend = "parley.summaryCheckerBackend"
        static let claudeBinaryPath = "parley.claudeBinaryPath"
        static let claudePromptTemplate = "parley.claudePromptTemplate"
        static let claudeModel = "parley.claudeModel"
        static let grokBinaryPath = "parley.grokBinaryPath"
        static let grokModel = "parley.grokModel"
        static let cursorBinaryPath = "parley.cursorBinaryPath"
        static let summaryBulkThreshold = "parley.summaryBulkThreshold"
        static let summaryFailureTripThreshold = "parley.summaryFailureTripThreshold"
        static let summaryAutoResumeAfterLimit = "parley.summaryAutoResumeAfterLimit"
        static let summaryMinIntervalSeconds = "parley.summaryMinIntervalSeconds"
        static let scanRoots = "parley.scanRoots"
        static let contactsFile = "parley.contactsFile"
        static let skillPath = "parley.skillPath"
        static let callDetectionEnabled = "parley.callDetectionEnabled"
        static let autoRecordEnabled = "parley.autoRecordEnabled"
        static let conferencingBundleIDs = "parley.conferencingBundleIDs"
        static let verboseDetectionLogging = "parley.verboseDetectionLogging"
        static let metadataDiscoveryEnabled = "parley.metadataDiscoveryEnabled"
        static let callEndGraceSeconds = "parley.callEndGraceSeconds"
        static let autoClearSeconds = "parley.autoClearSeconds"
        static let idleDrainSeconds = "parley.idleDrainSeconds"
        static let quietHoursEnabled = "parley.quietHoursEnabled"
        static let quietHoursStartHour = "parley.quietHoursStartHour"
        static let quietHoursEndHour = "parley.quietHoursEndHour"
        static let idleUnloadEnabled = "parley.idleUnloadEnabled"
        static let idleUnloadMinutes = "parley.idleUnloadMinutes"
        static let parakeetVersion = "parley.parakeetVersion"
        static let liveStreamingTier = "parley.liveStreamingTier"
        static let liveStreamingLanguage = "parley.liveStreamingLanguage"
        static let diarizationThreshold = "parley.diarizationThreshold"
        static let identificationThreshold = "parley.identificationThreshold"
        static let offlineAsrRepass = "parley.offlineAsrRepass"
        static let useParakeetUnified = "parley.useParakeetUnified"
        static let boostAttendeeNames = "parley.boostAttendeeNames"
        static let fluidGpuEncoder = "parley.fluidGpuEncoder"
        static let minSpeechToIdentify = "parley.minSpeechToIdentify"
        static let batchMode = "parley.batchMode"
        static let transcriptionTiming = "parley.transcriptionTiming"
        static let transcriptionWindowStartHour = "parley.transcriptionWindowStartHour"
        static let transcriptionWindowEndHour = "parley.transcriptionWindowEndHour"
        static let summaryPromptTemplate = "parley.summaryPromptTemplate"
        static let summaryRepairPromptTemplate = "parley.summaryRepairPromptTemplate"
        static let summaryCheckerPromptTemplate = "parley.summaryCheckerPromptTemplate"
        static let attachmentUnderstanding = "parley.attachmentUnderstanding"
        static let attachmentVisionBackend = "parley.attachmentVisionBackend"
        static let deleteAudioAfterFiling = "parley.deleteAudioAfterFiling"
        static let ownerName = "parley.ownerName"
        static let ownerCompany = "parley.ownerCompany"
        static let micIsOwnerOnCalls = "parley.micIsOwnerOnCalls"
    }

    // MARK: You
    /// The recording owner, for `{{me}}` and for scoping `{{contacts}}`.
    @AppStorage(Key.ownerName) var ownerName: String = ""
    /// The owner's company in its canonical spelling, for `{{my_company}}`.
    @AppStorage(Key.ownerCompany) var ownerCompany: String = ""
    /// Remote calls only: attribute mic speech to the owner ("Me") and diarize just the
    /// system track. Room-mode sessions always diarize the single mic stream.
    @AppStorage(Key.micIsOwnerOnCalls) var micIsOwnerOnCalls: Bool = true

    // MARK: Memory
    /// Unload FluidAudio streaming models after this many idle minutes to free RAM.
    @AppStorage(Key.idleUnloadEnabled) var idleUnloadEnabled: Bool = true
    @AppStorage(Key.idleUnloadMinutes) var idleUnloadMinutes: Double = 5

    // MARK: Call detection
    @AppStorage(Key.callDetectionEnabled) var callDetectionEnabled: Bool = true
    @AppStorage(Key.autoRecordEnabled) var autoRecordEnabled: Bool = false
    @AppStorage(Key.verboseDetectionLogging) var verboseDetectionLogging: Bool = false
    @AppStorage(Key.callEndGraceSeconds) var callEndGraceSeconds: Double = 15
    /// Seconds after the post-meeting pipeline completes before the Record view
    /// auto-clears itself back to a blank slate for the next call; 0 = off.
    @AppStorage(Key.autoClearSeconds) var autoClearSeconds: Double = 30
    /// Seconds of continuous idle before background offline/summary queues drain.
    @AppStorage(Key.idleDrainSeconds) var idleDrainSeconds: Double = 60
    /// During quiet hours, held queue jobs may drain after the idle wait above.
    @AppStorage(Key.quietHoursEnabled) var quietHoursEnabled: Bool = true
    /// Quiet-hours window start (24h clock, inclusive). Default 22:00.
    @AppStorage(Key.quietHoursStartHour) var quietHoursStartHour: Int = 22
    /// Quiet-hours window end (24h clock, exclusive). Default 07:00.
    @AppStorage(Key.quietHoursEndHour) var quietHoursEndHour: Int = 7

    /// True when the current time falls in the configured quiet-hours window.
    var isQuietHours: Bool {
        Self.isQuietHours(now: Date(), startHour: quietHoursStartHour, endHour: quietHoursEndHour)
    }

    /// Whether held jobs may drain now (quiet hours + idle gate satisfied).
    func allowsHeldJobDrain(canDrain: Bool) -> Bool {
        quietHoursEnabled && isQuietHours && canDrain
    }

    /// Hour-based quiet window; supports overnight spans (e.g. 22 → 7).
    static func isQuietHours(now: Date, startHour: Int, endHour: Int) -> Bool {
        let hour = Calendar.current.component(.hour, from: now)
        if startHour <= endHour {
            return hour >= startHour && hour < endHour
        }
        return hour >= startHour || hour < endHour
    }
    /// Read the meeting window via Accessibility when a call is detected and
    /// suggest its title/attendees. Requires the Accessibility permission.
    @AppStorage(Key.metadataDiscoveryEnabled) var metadataDiscoveryEnabled: Bool = true
    /// Known conferencing apps (bundle IDs), one per line. A known app on the mic
    /// is a full trigger; an unknown app on the mic only notifies.
    @AppStorage(Key.conferencingBundleIDs) var conferencingBundleIDsRaw: String = AppSettings.defaultConferencingBundleIDs

    var conferencingBundleIDs: Set<String> {
        Set(conferencingBundleIDsRaw
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    /// One-time: existing installs already have AppStorage without Webex. Seed it
    /// once; the user can still remove the line afterwards.
    func seedWebexKnownAppIfNeeded() {
        let key = "parley.seededWebexBundle"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        if !conferencingBundleIDs.contains("cisco-systems.spark") {
            let trimmed = conferencingBundleIDsRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            conferencingBundleIDsRaw = trimmed.isEmpty
                ? "cisco-systems.spark\n"
                : trimmed + "\ncisco-systems.spark\n"
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    static let defaultConferencingBundleIDs = """
    com.microsoft.teams2
    com.microsoft.teams
    us.zoom.xos
    cisco-systems.spark
    com.google.Chrome
    com.apple.Safari
    com.microsoft.edgemac
    company.thebrowser.Browser
    org.mozilla.firefox
    com.brave.Browser
    """

    /// Path to the SKILL.md the app runs via `claude -p`, editable in Settings.
    @AppStorage(Key.skillPath) var skillPath: String =
        "\(NSHomeDirectory())/.claude/skills/process-meeting-transcript/SKILL.md"
    var skillURL: URL { URL(fileURLWithPath: skillPath) }

    /// Vault-relative root folders to scan for filing destinations, one per line
    /// (or comma-separated). Subfolders become the destination tree.
    @AppStorage(Key.scanRoots) var scanRootsRaw: String = "Work\nPersonal"
    /// Vault file listing contacts/attendees (created from a template if missing).
    @AppStorage(Key.contactsFile) var contactsFileName: String = "Rolodex.md"

    @AppStorage(Key.vaultPath) var vaultPath: String = "\(NSHomeDirectory())/ObsidianVault"
    @AppStorage(Key.captureMode) var captureModeRaw: String = CaptureMode.systemWide.rawValue
    @AppStorage(Key.parakeetVersion) var parakeetVersionRaw: String = FluidParakeetVersion.v3.rawValue
    /// FluidAudio live streaming ASR: chunk-size tier (ms) + language hint. 560 ms
    /// is the lowest-latency multilingual tier; "auto" uses the full-vocab model
    /// (covers zh/ja). Defaults to English so Parakeet Unified is the out-of-the-box
    /// model; any other language falls back to Nemotron + TDT v3.
    @AppStorage(Key.liveStreamingTier) var liveStreamingTierRaw: Int = FluidStreamingTier.ms2240.rawValue
    @AppStorage(Key.liveStreamingLanguage) var liveStreamingLanguage: String = "en-US"
    /// FluidAudio in-session diarization clustering threshold (lower = more speakers /
    /// more sensitive; higher = merges similar voices). Default 0.6 — the library's
    /// 0.7 over-merges distinct speakers in practice.
    @AppStorage(Key.diarizationThreshold) var diarizationThreshold: Double = 0.6
    /// Cross-session speaker identification threshold: minimum cosine similarity to a
    /// saved voiceprint's centroid to call it a match. Distinct from
    /// `diarizationThreshold` (in-session clustering). Higher = fewer false matches.
    @AppStorage(Key.identificationThreshold) var identificationThreshold: Double = 0.6
    /// FluidAudio only: after stop, re-transcribe the whole recording with the
    /// batch Parakeet pass (higher accuracy than the streaming chunks) and rewrite
    /// the saved transcript. Off = keep the live streaming transcript.
    @AppStorage(Key.offlineAsrRepass) var offlineAsrRepass: Bool = true
    /// When the live language is English, use Parakeet Unified 0.6B for streaming
    /// (~2 s latency) and the full-attention offline batch pass instead of Nemotron
    /// + TDT v3. Non-English sessions always use the multilingual path.
    @AppStorage(Key.useParakeetUnified) var useParakeetUnified: Bool = true
    /// Boost attendee names and meeting-title tokens in the offline batch transcript
    /// via FluidAudio custom vocabulary (CTC spotter + rescorer).
    @AppStorage(Key.boostAttendeeNames) var boostAttendeeNames: Bool = true
    /// Run the Parakeet v3 conformer encoder on GPU for the multilingual offline
    /// re-pass (+~8% RTFx, WER-neutral). Unified English models manage placement
    /// internally; this only affects the Nemotron + TDT v3 path.
    @AppStorage(Key.fluidGpuEncoder) var fluidGpuEncoder: Bool = false
    /// Seconds of clean, quality-gated speech before a voice is auto-identified/named.
    @AppStorage(Key.minSpeechToIdentify) var minSpeechToIdentify: Double = 5
    /// Record audio only and transcribe on FluidAudio's batch model, including
    /// while the next call is recording. Off keeps the live engine and pauses
    /// the offline queue for the duration of a recording.
    @AppStorage(Key.batchMode) var batchMode: Bool = true
    @AppStorage(Key.transcriptionTiming) var transcriptionTimingRaw: String = TranscriptionTiming.afterCall.rawValue
    /// Daily window start (24h, inclusive). Used when `transcriptionTiming` is `.window`.
    @AppStorage(Key.transcriptionWindowStartHour) var transcriptionWindowStartHour: Int = 22
    /// Daily window end (24h, exclusive). Overnight spans match quiet hours.
    @AppStorage(Key.transcriptionWindowEndHour) var transcriptionWindowEndHour: Int = 7

    var transcriptionTiming: TranscriptionTiming {
        get { TranscriptionTiming(rawValue: transcriptionTimingRaw) ?? .afterCall }
        set { transcriptionTimingRaw = newValue.rawValue }
    }
    /// Auto-summarize: after a recording's speakers are assigned, fire the background
    /// summary automatically (result is staged for review in History). Default on.
    /// Key name is historical (`autoRunClaude`); applies to whichever `summaryBackend` is set.
    @AppStorage(Key.autoRunClaude) var autoRunClaude: Bool = true
    /// Which engine generates summaries. Default is Cursor Grok 4.7 Medium Fast.
    @AppStorage(Key.summaryBackend) var summaryBackendRaw: String = SummaryBackend.cursorGrok47MediumFast.rawValue
    /// Classic single-backend vs v2 writer→checker pipeline.
    @AppStorage(Key.summaryPipeline) var summaryPipelineRaw: String = SummaryPipeline.classic.rawValue
    @AppStorage(Key.summaryWriterBackend) var summaryWriterBackendRaw: String = SummaryBackend.composer25.rawValue
    @AppStorage(Key.summaryCheckerBackend) var summaryCheckerBackendRaw: String = SummaryBackend.cursorGrok47MediumFast.rawValue
    @AppStorage(Key.claudeBinaryPath) var claudeBinaryPath: String = "\(NSHomeDirectory())/.local/bin/claude"
    @AppStorage(Key.claudePromptTemplate) var claudePromptTemplate: String = AppSettings.defaultClaudePrompt
    @AppStorage(Key.claudeModel) var claudeModel: String = "sonnet"
    @AppStorage(Key.grokBinaryPath) var grokBinaryPath: String = "\(NSHomeDirectory())/.grok/bin/grok"
    @AppStorage(Key.grokModel) var grokModel: String = "grok-4.6"
    /// Path to the Cursor CLI (`cursor agent …`). Used by Composer / Cursor Grok backends.
    @AppStorage(Key.cursorBinaryPath) var cursorBinaryPath: String = "/usr/local/bin/cursor"

    var summaryBackend: SummaryBackend {
        get { SummaryBackend.resolved(summaryBackendRaw) ?? .cursorGrok47MediumFast }
        set { summaryBackendRaw = newValue.rawValue }
    }

    var summaryPipeline: SummaryPipeline {
        get { SummaryPipeline(rawValue: summaryPipelineRaw) ?? .classic }
        set { summaryPipelineRaw = newValue.rawValue }
    }

    var summaryWriterBackend: SummaryBackend {
        get { SummaryBackend.resolved(summaryWriterBackendRaw) ?? .composer25 }
        set { summaryWriterBackendRaw = newValue.rawValue }
    }

    var summaryCheckerBackend: SummaryBackend {
        get { SummaryBackend.resolved(summaryCheckerBackendRaw) ?? .cursorGrok47MediumFast }
        set { summaryCheckerBackendRaw = newValue.rawValue }
    }
    /// Ask before auto-summarizing a wave of ≥ this many notes at once (backlog / bulk
    /// speaker-naming) so a burst never silently burns Claude usage.
    @AppStorage(Key.summaryBulkThreshold) var summaryBulkThreshold: Int = 3
    /// Pause the summary queue after this many consecutive failures (a flapping CLI
    /// burning the queue is the same harm as a usage limit).
    @AppStorage(Key.summaryFailureTripThreshold) var summaryFailureTripThreshold: Int = 3
    /// Auto-resume the summary queue after a usage-limit pause (at the parsed reset time,
    /// else exponential backoff). Off ⇒ wait for a manual Resume.
    @AppStorage(Key.summaryAutoResumeAfterLimit) var summaryAutoResumeAfterLimit: Bool = true
    /// Optional pacing: minimum seconds between summary runs (0 = off).
    @AppStorage(Key.summaryMinIntervalSeconds) var summaryMinIntervalSeconds: Double = 0

    var captureMode: CaptureMode {
        get { CaptureMode(rawValue: captureModeRaw) ?? .systemWide }
        set { captureModeRaw = newValue.rawValue }
    }

    /// Parakeet ASR variant for the FluidAudio engine.
    var parakeetVersion: FluidParakeetVersion {
        get { FluidParakeetVersion(rawValue: parakeetVersionRaw) ?? .v3 }
        set { parakeetVersionRaw = newValue.rawValue }
    }

    /// Chunk-size tier (ms) for the FluidAudio multilingual streaming live ASR.
    var liveStreamingTier: FluidStreamingTier {
        get { FluidStreamingTier(rawValue: liveStreamingTierRaw) ?? .ms560 }
        set { liveStreamingTierRaw = newValue.rawValue }
    }

    /// Root folders (vault-relative) to scan for filing destinations.
    var scanRoots: [String] {
        scanRootsRaw
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var vaultURL: URL { URL(fileURLWithPath: vaultPath) }

    /// The contacts / attendees source file (e.g. Rolodex.md).
    var contactsURL: URL { vaultURL.appendingPathComponent(contactsFileName) }

    /// Legacy contacts filename, migrated into `contactsURL` on first run.
    var legacyContactsURL: URL { vaultURL.appendingPathComponent("Key People.md") }

    /// Default prompt that invokes the user's existing skill headlessly.
    /// Tokens: `{{file}}`, `{{destination}}`, `{{attendees}}`, `{{invitees}}`, `{{me}}`,
    /// `{{my_company}}`.
    static let defaultClaudePrompt = """
    /process-meeting-transcript {{file}}
    File this note under: {{destination}}
    Recording owner ("Me" in the transcript): {{me}}, {{my_company}}
    Invitees and RSVP:
    {{invitees}}
    Additional attendees: {{attendees}}
    Run non-interactively: use the context above, do not ask for confirmation, write the note into the destination folder above.
    """

    /// Shared, self-contained prompt for the Claude meeting summary (raw `claude -p`, no
    /// skill). Tokens substituted at run time: `{{transcript}}`, `{{contacts}}`,
    /// `{{attendees}}`, `{{invitees}}`, `{{glossary}}`, `{{me}}`, `{{my_company}}`,
    /// `{{destination}}`. Editable in Settings → Summary.
    @AppStorage(Key.summaryPromptTemplate) var summaryPromptTemplate: String = AppSettings.defaultSummaryPrompt

    @AppStorage(Key.summaryRepairPromptTemplate) var summaryRepairPromptTemplate: String = AppSettings.defaultSummaryRepairPrompt

    /// Instruction block for the Summary v2 checker. Unlike the writer template this
    /// takes no `{{…}}` tokens — the transcript, contacts, attendees, and draft are
    /// appended by `SummaryCheckerPromptBuilder`. Editable in Settings → Summary.
    @AppStorage(Key.summaryCheckerPromptTemplate) var summaryCheckerPromptTemplate: String
        = SummaryCheckerPromptBuilder.defaultInstructions

    /// How image attachments are included in summary prompts.
    @AppStorage(Key.attachmentUnderstanding) var attachmentUnderstandingRaw: String
        = AttachmentUnderstanding.captionsOnly.rawValue

    /// Cursor backend for the attachment vision pre-pass (plan mode, read-only).
    @AppStorage(Key.attachmentVisionBackend) var attachmentVisionBackendRaw: String
        = SummaryBackend.composer25.rawValue

    var attachmentUnderstanding: AttachmentUnderstanding {
        get { AttachmentUnderstanding(rawValue: attachmentUnderstandingRaw) ?? .captionsOnly }
        set { attachmentUnderstandingRaw = newValue.rawValue }
    }

    var attachmentVisionBackend: SummaryBackend {
        get { SummaryBackend.resolved(attachmentVisionBackendRaw) ?? .composer25 }
        set { attachmentVisionBackendRaw = newValue.rawValue }
    }

    /// After a summary is committed to the vault, delete the session audio (the raw
    /// transcript + summary make it redundant). Default on; frees significant disk.
    @AppStorage(Key.deleteAudioAfterFiling) var deleteAudioAfterFiling: Bool = true

    static let defaultSummaryPrompt = """
    You are a senior analyst writing a thorough, faithful record of a client meeting. Produce a \
    clean Markdown note from the transcript below.

    CONTEXT
    Recording owner: {{me}}. "Me" in the transcript is this person.
    Owner's company (canonical spelling — always spell it exactly like this): {{my_company}}

    Known contacts, one per line as `Full name | Title | Company | Aliases`. Aliases are other \
    spellings or names the same person goes by. Never invent contact details:
    {{contacts}}

    Invitees from the meeting invite, with RSVP (accepted / declined / tentative / no response):
    {{invitees}}

    Additional attendees supplied: {{attendees}}
    Each attendee may be annotated with their company in parentheses, e.g. `Alice Smith (Vanguard)` \
    -- treat that as authoritative; do not override it from the transcript. When the annotation \
    ends with `, customer` (e.g. `Anna Krylova (IG Group, customer)`), that person is an \
    external client/counterpart; attendees without `, customer` are your own internal team.

    Glossary — canonical spellings, each followed by forms the transcript may have misheard:
    {{glossary}}

    Filing location (context only, do not output): {{destination}}

    STEP 1 — RESOLVE (silently; do not output this step)
    - Merge duplicates: a bare first name and a full name for the same person on the call \
    (e.g. "Jason" and "Jason Creane") are ONE attendee under the full name.
    - Match a person to a contact only on their full name, an alias, or a first name plus a \
    company the transcript or attendee list confirms. A first name alone never matches a \
    contact at an unrelated company.
    - Resolve people who are mentioned but not on the call (e.g. "Lucy", "Khadir") against the \
    contacts using the same rule, and use their full canonical name when confidently matched.
    - Correct misheard names, companies, and terms to the glossary and contacts spellings \
    (aliases included). The owner's company is always spelled as {{my_company}}.
    - Speaker labels can drift or split one turn across two speakers. When a line's content \
    clearly belongs to someone else (they answer their own question, refer to themselves by \
    name, or continue another speaker's sentence), attribute it by content. If it is unclear, \
    attribute it to the side (the owner's company or the other company), not a guessed person.
    - Invitees who never speak become rows marked "(invited, not present)", whatever their RSVP. \
    Declined or no-response invitees are never listed as present.
    - "Me" and "Speaker N" labels must be mapped to real people; never leave generic labels.

    Write these sections in order. Be COMPREHENSIVE and SPECIFIC — capture every concrete detail: \
    named people, companies, clients, products, technologies/platforms, headcounts, monetary \
    figures, timelines, dates, locations, tenures, and commitments. Prefer specifics over generic \
    phrasing.

    ## Attendees
    (Markdown table: Name | Role | Company. List ONLY people who actually participated in \
    THIS call — i.e. who spoke or were present. People merely mentioned/referenced but NOT on \
    the call must NOT appear here; capture them in Key Topics instead. Invitees who never speak \
    get a row with "(invited, not present)" after their name. When in doubt about whether \
    someone was present, do not list them as an attendee. For any attendee whose name is NOT \
    already annotated with a company (no parentheses in the supplied attendee list) and is NOT \
    confidently matched in the contacts, if the transcript clearly states their affiliation \
    (e.g. "I'm Dana from Acme" or "...here at Acme"), put that company in the Company column \
    and append the literal tag " (inferred)" -- for example "Acme (inferred)". If no affiliation \
    is evident, leave Company blank. NEVER append "(inferred)" to a company that was supplied \
    in the attendee annotation or matched from contacts. The Role column is a job title only. \
    If no title is known from contacts and none is stated in the transcript, leave Role blank — \
    never a company name, team name, or the word "Attendee". The `, customer` suffix in the \
    supplied attendee list is context for you only; never print `, customer`, `(customer)`, or \
    any similar external-party marker in the note — the Company column holds the company name \
    alone, with " (inferred)" as the only permitted addition.)

    ## Executive Summary
    (2–3 paragraphs: who met, why, the core need/opportunity, and the outcome / immediate next step.)

    ## Key Topics Discussed
    (Group into themed ### sub-headings. Under each, bullet the specifics — names, numbers, \
    technologies, named clients, locations.)

    ## Decisions Made
    (Numbered; only decisions explicitly agreed in the meeting.)

    ## Action Items
    (Markdown table: Action | Owner | Due / Timeframe | Priority. Only items explicitly stated — \
    do NOT invent dates.)

    ## Questions & Open Issues
    (Numbered.)

    ## Key Metrics or Data Points
    (Bullets: every concrete number, date, headcount, spend, timeline, location, and named client \
    mentioned.)

    ## Next Steps
    (Numbered.)

    ## Attachments
    (When ATTACHMENTS are listed below, include this section with markdown image links \
    using the filenames and captions provided. Reference whiteboards/diagrams in Key Topics \
    when relevant. Do NOT invent visual details you cannot see — rely on captions only.)

    ## Diagrams
    (Include ONLY when ATTACHMENT VISION is provided below. For each diagram/whiteboard, add a \
    `###` subheading, integrate the description into the note, and include any mermaid blocks \
    from the vision pass. Always keep the raw image embeds in ## Attachments — mermaid is a \
    supplement, not a replacement.)

    Strict rules:
    - Use ONLY information explicitly present in the transcript. Do NOT fabricate decisions, \
    owners, dates, figures, or metrics. If a section has nothing explicit, write "None recorded."
    - Output ONLY the Markdown note — no preamble, no code fences, no commentary.
    - Never comment on the transcript itself: no "the transcript is unclear", "garbled", \
    "probably a transcription error", "not clearly identifiable in the transcript", or speaker-label \
    remarks. Resolve what you can silently; put a genuinely unresolved name or term in \
    Questions & Open Issues as a plain question about the meeting.
    - Spell every person, company, and product the same way everywhere in the note, using the \
    contacts and glossary spellings.
    - Do NOT include a Raw Transcript section — Parley appends the raw transcript to the filed \
    note automatically.

    Final self-check before answering (silently): no duplicate attendees; no attendee matched \
    to a contact on first name alone; {{my_company}} spelled canonically everywhere; mentioned \
    people resolved to full names where the contacts allow; no generic speaker labels; no \
    remarks about the transcript.

    TRANSCRIPT:
    {{transcript}}
    """

    static let defaultSummaryRepairPrompt = """
    You are revising an existing meeting note after the user corrected speaker names.

    Keep the note's structure and any user edits intact. Fix attribution, names, and pronouns \
    using the rename map and updated transcript. Refresh factual attribution where a generic \
    "Speaker N" label hid who did or said what. Do NOT invent new content.

    RENAME MAP (old label → new name):
    {{rename_map}}

    {{contacts}}
    Attendees supplied: {{attendees}}
    Filing location (context only): {{destination}}

    PREVIOUS NOTE (preserve structure and edits):
    {{previous_note}}

    Strict rules:
    - Output ONLY the revised Markdown note — no preamble.
    - Do NOT include a Raw Transcript section — Parley appends it automatically.

    TRANSCRIPT:
    {{transcript}}
    """
}
