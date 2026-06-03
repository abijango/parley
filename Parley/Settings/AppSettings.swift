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
        static let vaultPath = "parley.vaultPath"
        static let model = "parley.model"
        static let liveModel = "parley.liveModel"
        static let computeMode = "parley.computeMode"
        static let captureMode = "parley.captureMode"
        static let autoRunClaude = "parley.autoRunClaude"
        static let claudeBinaryPath = "parley.claudeBinaryPath"
        static let claudePromptTemplate = "parley.claudePromptTemplate"
        static let claudeModel = "parley.claudeModel"
        static let scanRoots = "parley.scanRoots"
        static let contactsFile = "parley.contactsFile"
        static let skillPath = "parley.skillPath"
        static let callDetectionEnabled = "parley.callDetectionEnabled"
        static let autoRecordEnabled = "parley.autoRecordEnabled"
        static let conferencingBundleIDs = "parley.conferencingBundleIDs"
        static let verboseDetectionLogging = "parley.verboseDetectionLogging"
        static let callEndGraceSeconds = "parley.callEndGraceSeconds"
        static let idleUnloadEnabled = "parley.idleUnloadEnabled"
        static let idleUnloadMinutes = "parley.idleUnloadMinutes"
        static let transcriptionEngine = "parley.transcriptionEngine"
        static let parakeetVersion = "parley.parakeetVersion"
        static let diarizationThreshold = "parley.diarizationThreshold"
        static let identificationThreshold = "parley.identificationThreshold"
        static let offlineAsrRepass = "parley.offlineAsrRepass"
        static let minSpeechToIdentify = "parley.minSpeechToIdentify"
        static let liveTranscriptEnabled = "parley.liveTranscriptEnabled"
        static let summaryPromptTemplate = "parley.summaryPromptTemplate"
        static let deleteAudioAfterFiling = "parley.deleteAudioAfterFiling"
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
    /// Auto-summarize: after a recording's speakers are assigned, fire the background
    /// Claude summary automatically (result is staged for review in History). Default on.
    @AppStorage(Key.autoRunClaude) var autoRunClaude: Bool = true
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

    /// Shared, self-contained prompt for the Claude meeting summary (raw `claude -p`, no
    /// skill). Tokens substituted at run time: `{{transcript}}`, `{{contacts}}`,
    /// `{{attendees}}`, `{{destination}}`. Editable in Settings → Summary.
    @AppStorage(Key.summaryPromptTemplate) var summaryPromptTemplate: String = AppSettings.defaultSummaryPrompt

    /// After a summary is committed to the vault, delete the session audio (the raw
    /// transcript + summary make it redundant). Default on; frees significant disk.
    @AppStorage(Key.deleteAudioAfterFiling) var deleteAudioAfterFiling: Bool = true

    static let defaultSummaryPrompt = """
    You are a senior analyst writing a thorough, faithful record of a client meeting. Produce a \
    clean Markdown note from the transcript below.

    Speaker mapping: the transcript labels speakers as "Me" (the person recording) or \
    "Remote"/"Speaker N". Map each to a real attendee using context and the attendee list; never \
    leave generic labels in the note.

    Resolve names against these known contacts — use full name, title, and company where a \
    confident match exists; otherwise keep the name as spoken. Never invent contact details:
    {{contacts}}

    Attendees supplied: {{attendees}}
    Filing location (context only, do not output): {{destination}}

    Write these sections in order. Be COMPREHENSIVE and SPECIFIC — capture every concrete detail: \
    named people, companies, clients, products, technologies/platforms, headcounts, monetary \
    figures, timelines, dates, locations, tenures, and commitments. Prefer specifics over generic \
    phrasing.

    ## Attendees
    (Markdown table: Name | Role | Company. List ONLY people who actually participated in \
    THIS call — i.e. who spoke or were present. People merely mentioned/referenced but NOT on \
    the call must NOT appear here; capture them in Key Topics instead. If someone was invited \
    but absent, you may add a row marked "(invited — not present)". When in doubt about whether \
    someone was present, do not list them as an attendee.)

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

    Strict rules:
    - Use ONLY information explicitly present in the transcript. Do NOT fabricate decisions, \
    owners, dates, figures, or metrics. If a section has nothing explicit, write "None recorded."
    - Output ONLY the Markdown note — no preamble, no code fences, no commentary.

    TRANSCRIPT:
    {{transcript}}
    """
}
