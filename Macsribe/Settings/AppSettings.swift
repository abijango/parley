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
    case whisperKit   // original WhisperKit path — transcription only, no speaker ID
    case fluidAudio   // native FluidAudio stack — transcription + speaker identification

    var id: String { rawValue }
    var label: String {
        switch self {
        case .whisperKit: return "WhisperKit"
        case .fluidAudio: return "FluidAudio (speaker ID)"
        }
    }
    var blurb: String {
        switch self {
        case .whisperKit: return "OpenAI Whisper on-device. High accuracy, no speaker labels — the original, well-tested path."
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
    @AppStorage(Key.computeMode) var computeModeRaw: String = ComputeMode.gpu.rawValue
    @AppStorage(Key.transcriptionEngine) var transcriptionEngineRaw: String = TranscriptionEngineKind.whisperKit.rawValue
    @AppStorage(Key.parakeetVersion) var parakeetVersionRaw: String = FluidParakeetVersion.v3.rawValue
    @AppStorage(Key.autoRunClaude) var autoRunClaude: Bool = false
    @AppStorage(Key.claudeBinaryPath) var claudeBinaryPath: String = "\(NSHomeDirectory())/.local/bin/claude"
    @AppStorage(Key.claudePromptTemplate) var claudePromptTemplate: String = AppSettings.defaultClaudePrompt
    @AppStorage(Key.claudeModel) var claudeModel: String = "sonnet"

    var captureMode: CaptureMode {
        get { CaptureMode(rawValue: captureModeRaw) ?? .systemWide }
        set { captureModeRaw = newValue.rawValue }
    }

    var model: WhisperModel {
        get { WhisperModel(rawValue: modelRaw) ?? .small }
        set { modelRaw = newValue.rawValue }
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
}
