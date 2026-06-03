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

/// Whisper model variants we expose. Raw values are WhisperKit model repo names.
enum WhisperModel: String, CaseIterable, Identifiable {
    case small  = "openai_whisper-small"
    case medium = "openai_whisper-medium"
    case large  = "openai_whisper-large-v3"                            // full float16 — max accuracy (~3 GB)
    case turbo  = "openai_whisper-large-v3-v20240930_turbo_632MB"      // optimized turbo — near-large accuracy, ~0.6 GB

    var id: String { rawValue }
    var label: String {
        switch self {
        case .small: return "Small (default)"
        case .medium: return "Medium"
        case .large: return "Large v3"
        case .turbo: return "Turbo (large-v3)"
        }
    }

    /// On-disk download size (actual, from the WhisperKit repo), for Settings.
    var approxSize: String {
        switch self {
        case .small: return "~490 MB"
        case .medium: return "~1.5 GB"
        case .large: return "~3.0 GB"
        case .turbo: return "~0.6 GB"
        }
    }

    /// Accuracy/speed guidance shown under each option.
    var blurb: String {
        switch self {
        case .small: return "Fastest, lowest accuracy. Best for live latency."
        case .medium: return "Better accuracy; may lag real-time on older Macs."
        case .large: return "Best accuracy (full v3). Heaviest — slow to download & load."
        case .turbo: return "Near-large accuracy, small & fast. Best all-round for live."
        }
    }
}

/// Where Whisper runs. GPU avoids the Neural Engine's per-build/per-pressure
/// "specialization" compile (which can take minutes), at a small inference cost.
enum ComputeMode: String, CaseIterable, Identifiable {
    case gpu = "GPU"
    case neuralEngine = "Neural Engine"
    var id: String { rawValue }
    var blurb: String {
        switch self {
        case .gpu: return "No specialization wait, loads fast every time. Slightly slower per token. Best when memory is tight or you rebuild often."
        case .neuralEngine: return "Fastest inference once warm, lower power — but compiles for the ANE (~minutes) on first load / after a rebuild or memory pressure."
        }
    }
}

/// Which transcription engine a recording uses. Chosen in Settings; applies to
/// the NEXT recording session (no mid-session switch).
enum TranscriptionEngineKind: String, CaseIterable, Identifiable {
    case whisperKit   // WhisperKit ASR + SpeakerKit diarization + speaker ID
    case fluidAudio   // native FluidAudio stack — Parakeet ASR + diarization + speaker ID

    var id: String { rawValue }
    var label: String {
        switch self {
        case .whisperKit: return "WhisperKit + SpeakerKit"
        case .fluidAudio: return "FluidAudio"
        }
    }
    var blurb: String {
        switch self {
        case .whisperKit: return "WhisperKit ASR for fast live text + SpeakerKit diarization & speaker ID applied at stop. Labels who spoke."
        case .fluidAudio: return "Native Parakeet ASR + on-device diarization & speaker identification. Labels who spoke."
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
}

/// App-wide settings persisted via UserDefaults (`@AppStorage`).
/// TODO(app-name): the AppStorage keys are namespaced with a literal prefix below.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        // TODO(app-name): key prefix
        static let vaultPath = "macsribe.vaultPath"
        static let model = "macsribe.model"
        static let liveModel = "macsribe.liveModel"
        static let computeMode = "macsribe.computeMode"
        static let captureMode = "macsribe.captureMode"
        static let autoRunClaude = "macsribe.autoRunClaude"
        static let claudeBinaryPath = "macsribe.claudeBinaryPath"
        static let claudePromptTemplate = "macsribe.claudePromptTemplate"
        static let claudeModel = "macsribe.claudeModel"
        static let scanRoots = "macsribe.scanRoots"
        static let contactsFile = "macsribe.contactsFile"
        static let skillPath = "macsribe.skillPath"
        static let callDetectionEnabled = "macsribe.callDetectionEnabled"
        static let autoRecordEnabled = "macsribe.autoRecordEnabled"
        static let conferencingBundleIDs = "macsribe.conferencingBundleIDs"
        static let verboseDetectionLogging = "macsribe.verboseDetectionLogging"
        static let callEndGraceSeconds = "macsribe.callEndGraceSeconds"
        static let idleUnloadEnabled = "macsribe.idleUnloadEnabled"
        static let idleUnloadMinutes = "macsribe.idleUnloadMinutes"
        static let transcriptionEngine = "macsribe.transcriptionEngine"
        static let parakeetVersion = "macsribe.parakeetVersion"
        static let diarizationThreshold = "macsribe.diarizationThreshold"
        static let identificationThreshold = "macsribe.identificationThreshold"
        static let offlineAsrRepass = "macsribe.offlineAsrRepass"
        static let minSpeechToIdentify = "macsribe.minSpeechToIdentify"
        static let liveTranscriptEnabled = "macsribe.liveTranscriptEnabled"
        static let summaryPromptTemplate = "macsribe.summaryPromptTemplate"
        static let localSummaryModelId = "macsribe.localSummaryModelId"
        static let summaryEnginesEnabled = "macsribe.summaryEnginesEnabled"
    }

    // MARK: Memory
    /// Unload the Whisper model after this many idle minutes to free RAM; it
    /// reloads on the next call/record (fast on GPU, with capture-first catch-up).
    @AppStorage(Key.idleUnloadEnabled) var idleUnloadEnabled: Bool = true
    @AppStorage(Key.idleUnloadMinutes) var idleUnloadMinutes: Double = 5

    // MARK: Call detection
    @AppStorage(Key.callDetectionEnabled) var callDetectionEnabled: Bool = true
    @AppStorage(Key.autoRecordEnabled) var autoRecordEnabled: Bool = false
    @AppStorage(Key.verboseDetectionLogging) var verboseDetectionLogging: Bool = false
    @AppStorage(Key.callEndGraceSeconds) var callEndGraceSeconds: Double = 15
    /// Known conferencing apps (bundle IDs), one per line. A known app on the mic
    /// is a full trigger; an unknown app on the mic only notifies.
    @AppStorage(Key.conferencingBundleIDs) var conferencingBundleIDsRaw: String = AppSettings.defaultConferencingBundleIDs

    var conferencingBundleIDs: Set<String> {
        Set(conferencingBundleIDsRaw
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    static let defaultConferencingBundleIDs = """
    com.microsoft.teams2
    com.microsoft.teams
    us.zoom.xos
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
    @AppStorage(Key.model) var modelRaw: String = WhisperModel.small.rawValue
    /// WhisperKit + SpeakerKit only: the model used for the fast LIVE transcript
    /// (the `model` above is the offline/final transcript at stop). Defaults to a
    /// small/fast model so live decoding keeps up with real-time.
    @AppStorage(Key.liveModel) var liveModelRaw: String = WhisperModel.small.rawValue
    @AppStorage(Key.computeMode) var computeModeRaw: String = ComputeMode.gpu.rawValue
    // Default engine: WhisperKit + SpeakerKit (kept after the A/B). FluidAudio remains
    // selectable as a secondary option. Only affects fresh installs / unset stores.
    @AppStorage(Key.transcriptionEngine) var transcriptionEngineRaw: String = TranscriptionEngineKind.whisperKit.rawValue
    @AppStorage(Key.parakeetVersion) var parakeetVersionRaw: String = FluidParakeetVersion.v3.rawValue
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
    /// Seconds of clean, quality-gated speech before a voice is auto-identified/named.
    @AppStorage(Key.minSpeechToIdentify) var minSpeechToIdentify: Double = 5
    /// WhisperKit + SpeakerKit only: show a live (streaming) transcript while recording.
    /// Off (default) = offline-only — capture audio silently and produce the full,
    /// speaker-attributed transcript in one pass at stop. The offline pass is fast and
    /// accurate, so live text is opt-in; turning it off removes all live-decode load.
    @AppStorage(Key.liveTranscriptEnabled) var liveTranscriptEnabled: Bool = false
    @AppStorage(Key.autoRunClaude) var autoRunClaude: Bool = false
    @AppStorage(Key.claudeBinaryPath) var claudeBinaryPath: String = "\(NSHomeDirectory())/.local/bin/claude"
    @AppStorage(Key.claudePromptTemplate) var claudePromptTemplate: String = AppSettings.defaultClaudePrompt
    @AppStorage(Key.claudeModel) var claudeModel: String = "sonnet"

    var captureMode: CaptureMode {
        get { CaptureMode(rawValue: captureModeRaw) ?? .systemWide }
        set { captureModeRaw = newValue.rawValue }
    }

    /// Offline / final transcript model (also used by recovery + FluidAudio-era preload).
    var model: WhisperModel {
        get { WhisperModel(rawValue: modelRaw) ?? .small }
        set { modelRaw = newValue.rawValue }
    }

    /// Live-display model for the WhisperKit + SpeakerKit engine (fast).
    var liveModel: WhisperModel {
        get { WhisperModel(rawValue: liveModelRaw) ?? .small }
        set { liveModelRaw = newValue.rawValue }
    }

    var computeMode: ComputeMode {
        get { ComputeMode(rawValue: computeModeRaw) ?? .gpu }
        set { computeModeRaw = newValue.rawValue }
    }

    /// Transcription engine for the next recording session.
    var transcriptionEngine: TranscriptionEngineKind {
        get { TranscriptionEngineKind(rawValue: transcriptionEngineRaw) ?? .whisperKit }
        set { transcriptionEngineRaw = newValue.rawValue }
    }

    /// Parakeet ASR variant for the FluidAudio engine.
    var parakeetVersion: FluidParakeetVersion {
        get { FluidParakeetVersion(rawValue: parakeetVersionRaw) ?? .v3 }
        set { parakeetVersionRaw = newValue.rawValue }
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
    /// `{{file}}`, `{{customer}}`, `{{attendees}}` are substituted at run time.
    static let defaultClaudePrompt = """
    /process-meeting-transcript {{file}}
    File this note under: {{destination}}
    Additional attendees: {{attendees}}
    Run non-interactively: use the context above, do not ask for confirmation, write the note into the destination folder above.
    """

    /// Shared, self-contained summary prompt used by the comparison engines
    /// (Claude raw / Apple / Qwen) — distinct from `claudePromptTemplate`, which drives
    /// the agentic skill. Tokens substituted at run time: `{{transcript}}`, `{{contacts}}`,
    /// `{{attendees}}`, `{{destination}}`. Editable in the Summary settings + compare view.
    @AppStorage(Key.summaryPromptTemplate) var summaryPromptTemplate: String = AppSettings.defaultSummaryPrompt

    /// HuggingFace repo id of the local MLX model used by the Qwen summary engine (GPU).
    /// Must be an MLX *text* build. Confirmed-good defaults: `mlx-community/Qwen3-4B-4bit`,
    /// `mlx-community/Qwen2.5-3B-Instruct-4bit`. Downloaded on first use.
    @AppStorage(Key.localSummaryModelId) var localSummaryModelId: String = "mlx-community/Qwen3-4B-4bit"

    /// Which engines participate in the summary comparison (so the user can compare any
    /// subset, e.g. just Qwen vs Claude). Stored as comma-separated `SummaryEngineKind`
    /// raw values; defaults to all three.
    @AppStorage(Key.summaryEnginesEnabled) var summaryEnginesEnabledRaw: String = "claude,appleFoundation,qwenLocal"

    var enabledSummaryEngines: Set<SummaryEngineKind> {
        Set(summaryEnginesEnabledRaw.split(separator: ",").compactMap { SummaryEngineKind(rawValue: String($0)) })
    }

    func isSummaryEngineEnabled(_ kind: SummaryEngineKind) -> Bool {
        enabledSummaryEngines.contains(kind)
    }

    /// Toggle an engine's participation, keeping at least one enabled.
    func setSummaryEngine(_ kind: SummaryEngineKind, enabled: Bool) {
        var set = enabledSummaryEngines
        if enabled { set.insert(kind) } else { set.remove(kind) }
        guard !set.isEmpty else { return }   // never disable the last one
        summaryEnginesEnabledRaw = SummaryEngineKind.allCases
            .filter { set.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    static let defaultSummaryPrompt = """
    You are a meeting-notes assistant. Turn the transcript below into a clean, well-structured \
    Markdown meeting note.

    Resolve first names and partial names against these known contacts, using their full name, \
    title, and company where a confident match exists (otherwise keep the name as spoken — never invent details):
    {{contacts}}

    Additional attendees the user supplied for this meeting: {{attendees}}
    Intended filing location (for context only — do not output a path): {{destination}}

    Use EXACTLY these sections, in this order; omit a section only if it would be genuinely empty:
    ## Attendees
    ## Executive Summary
    ## Key Topics
    ## Decisions
    ## Action Items
    ## Questions & Open Issues
    ## Next Steps

    Rules:
    - Output ONLY the Markdown note — no preamble, no code fences, no closing commentary.
    - Action items: one bullet each as "**Owner** — task — due/when" when known.
    - Be faithful to the transcript; do not fabricate decisions, owners, dates, or metrics.

    TRANSCRIPT:
    {{transcript}}
    """
}
