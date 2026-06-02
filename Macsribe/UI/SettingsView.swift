import SwiftUI
import AppKit

/// Settings pane. Phase 6 fleshes out model download progress + the full Claude
/// configuration; this is the initial structure.
struct SettingsView: View {
    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var vault: VaultDirectory
    @EnvironmentObject private var detector: CallDetector
    @StateObject private var recordings = RecordingsStore()
    @State private var pendingDelete: RecordingFolder?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            transcriptionTab
                .tabItem { Label("Transcription", systemImage: "waveform") }
            notesTab
                .tabItem { Label("Notes", systemImage: "doc.text") }
            detectionTab
                .tabItem { Label("Detection", systemImage: "dot.radiowaves.left.and.right") }
            storageTab
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            SkillEditorView()
                .tabItem { Label("Skill", systemImage: "wand.and.stars") }
            vaultTab
                .tabItem { Label("Vault", systemImage: "folder") }
        }
        .frame(minWidth: 540, idealWidth: 600, maxWidth: .infinity,
               minHeight: 440, idealHeight: 500, maxHeight: .infinity)
        .padding()
    }

    private var detectionTab: some View {
        Form {
            Toggle("Detect calls automatically", isOn: $settings.callDetectionEnabled)
            Toggle("Auto-record when a known app starts a call", isOn: $settings.autoRecordEnabled)
                .disabled(!settings.callDetectionEnabled)
            Text("When auto-record is off, a notification with a Start button appears instead.")
                .font(.caption2).foregroundStyle(.tertiary)

            Divider()
            Text("Permissions").font(.caption).foregroundStyle(.secondary)
            permissionRow("Microphone", ok: !recording.micDenied,
                          fix: PermissionManager.openMicrophoneSettings)
            permissionRow("System-audio recording", ok: recording.systemAudioAvailable ?? true,
                          unknown: recording.systemAudioAvailable == nil,
                          fix: PermissionManager.openPrivacySettings)
            Text("Call detection watches which apps hold the microphone — both permissions must be granted for it to work reliably.")
                .font(.caption2).foregroundStyle(.tertiary)

            Divider()
            Text("Known conferencing apps — bundle IDs, one per line (known = auto-record / unknown = notify only)")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $settings.conferencingBundleIDsRaw)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 120).border(.quaternary)

            Divider()
            Toggle("Verbose detection logging", isOn: $settings.verboseDetectionLogging)
            HStack {
                Text("Detection log").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal Log") { NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL]) }
            }

            Divider()
            Text("Live detector status").font(.caption).foregroundStyle(.secondary)
            if let call = detector.activeCall {
                Label("Active call: \(call.displayName)", systemImage: "phone.connection.fill")
                    .foregroundStyle(.green).font(.callout)
            } else {
                Text("No active call.").font(.callout).foregroundStyle(.secondary)
            }
            if detector.capturing.isEmpty {
                Text("No apps capturing the microphone right now.").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(detector.capturing, id: \.pid) { p in
                    Text("• \(p.bundleID ?? "pid \(p.pid)")").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A granted/denied status line with a one-tap "Open Settings" when denied.
    private func permissionRow(_ label: String, ok: Bool, unknown: Bool = false,
                               fix: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: unknown ? "questionmark.circle" : (ok ? "checkmark.circle.fill" : "xmark.circle.fill"))
                .foregroundStyle(unknown ? Color.secondary : (ok ? Color.green : Color.red))
            Text(label).font(.callout)
            Spacer()
            if unknown {
                Text("Checking…").font(.caption2).foregroundStyle(.tertiary)
            } else if !ok {
                Button("Open Settings", action: fix).font(.caption)
            }
        }
    }

    // MARK: Storage (manual recordings management)

    private var storageTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recordings").font(.headline)
                Spacer()
                Text("\(recordings.sessions.count) · \(byteText(recordings.totalBytes))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("Raw call audio is kept here indefinitely — it's the source for re-transcribing or re-processing a recording. Deleting a session removes only its audio; the transcript and any note in your vault are untouched.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.recordingsDirectory])
                }
                Spacer()
                Button("Refresh") { recordings.refresh() }
            }

            Divider()

            if recordings.sessions.isEmpty {
                Text("No recordings yet.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(recordings.sessions) { folder in
                            sessionRow(folder)
                            Divider()
                        }
                    }
                }
            }
        }
        .onAppear { recordings.refresh() }
        .confirmationDialog(
            "Delete this recording's audio?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { folder in
            Button("Delete \(byteText(folder.sizeBytes))", role: .destructive) {
                recordings.delete(folder); pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { folder in
            Text("“\(folder.title)” — the audio is removed permanently. Any transcript or note already in your vault is kept.")
        }
    }

    private func sessionRow(_ folder: RecordingFolder) -> some View {
        let isCurrent = folder.id == recording.currentSessionID
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.title).font(.callout).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(storageDateText(folder.date)).font(.caption2).foregroundStyle(.tertiary)
                    if isCurrent {
                        Text("• recording now").font(.caption2).foregroundStyle(.red)
                    } else if folder.isActive {
                        Text("• interrupted").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Text(byteText(folder.sizeBytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless).help("Reveal in Finder")
            Button(role: .destructive) { pendingDelete = folder } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isCurrent)
            .help(isCurrent ? "Can't delete the recording in progress" : "Delete this session's audio")
        }
        .padding(.vertical, 6)
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func storageDateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }

    private var generalTab: some View {
        Form {
            TextField("Obsidian vault path", text: $settings.vaultPath)
            Text("Transcripts are written to: \(AppPaths.unprocessedURL.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Picker("Default other-audio capture", selection: Binding(
                get: { settings.captureMode }, set: { settings.captureMode = $0 }
            )) {
                ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
            }

            Divider()
            HStack {
                Text("Logs").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
                }
                Button("Clear") { AppLog.clear() }
            }
            Text(AppLog.fileURL.path)
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var transcriptionTab: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            Text("Engine").font(.headline)
            Picker("", selection: Binding(
                get: { settings.transcriptionEngine }, set: { settings.transcriptionEngine = $0 }
            )) {
                ForEach(TranscriptionEngineKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .disabled(recording.isRecording)   // engine applies to the next session, never mid-recording
            Text(settings.transcriptionEngine.blurb)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if settings.transcriptionEngine == .whisperKit {
                Text("Active model").font(.headline)
                Text("Bigger models are more accurate but slower and larger. The active model is used for new recordings.")
                    .font(.caption).foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(WhisperModel.allCases) { model in
                        modelRow(model)
                        if model != WhisperModel.allCases.last { Divider() }
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .disabled(recording.isRecording)   // never swap the model out from under a live recording

                Text("Stored in \(AppPaths.modelsDirectory.path)")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if recording.isRecording {
                    Text("Model and compute can't be changed while recording.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                Divider()
                Text("Compute").font(.headline)
                Picker("", selection: Binding(
                    get: { settings.computeMode }, set: { settings.computeMode = $0 }
                )) {
                    ForEach(ComputeMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(recording.isRecording)
                Text(settings.computeMode.blurb)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let advisory = models.memoryAdvisory {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "memorychip").foregroundStyle(.orange)
                        Text(advisory).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }

                Divider()
                Text("Memory").font(.headline)
                Toggle("Unload the model when idle to free memory", isOn: $settings.idleUnloadEnabled)
                if settings.idleUnloadEnabled {
                    HStack(spacing: 8) {
                        Stepper("Unload after \(Int(settings.idleUnloadMinutes)) min idle",
                                value: $settings.idleUnloadMinutes, in: 1...60, step: 1)
                            .fixedSize()
                    }
                }
                Text("Reclaims the model's memory after inactivity. It reloads on the next detected call or recording — capture starts immediately and the transcript catches up once the model finishes loading.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                HStack {
                    Text("If transcription crashes on load, the compiled-model cache may be corrupt.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Reset model cache") {
                        ModelManager.clearCompiledCache()
                        Task { await models.prepare(settings.model) }
                    }
                    .disabled(recording.isRecording)
                }
            } else {
                FluidModelSection(models: recording.fluidModels, isRecording: recording.isRecording)

                Divider()
                Text("Speaker separation").font(.headline)
                HStack(spacing: 10) {
                    Slider(value: $settings.diarizationThreshold, in: 0.40...0.80, step: 0.05)
                        .frame(maxWidth: 260)
                        .disabled(recording.isRecording)
                    Text(String(format: "%.2f", settings.diarizationThreshold))
                        .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
                Text("Lower = more sensitive (splits similar voices into separate speakers); higher = merges. If distinct speakers are labelled as one, lower it. Applies to the next recording.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { models.refreshDownloadedModels() }
        // Reload the model when the compute mode changes (forces a rebuild with
        // the new compute units; GPU drops the ANE specialization wait).
        .onChange(of: settings.computeModeRaw) {
            guard !recording.isRecording else { return }
            Task { await models.prepare(settings.model) }
        }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: WhisperModel) -> some View {
        let isActive = settings.model == model
        let isDownloaded = models.downloadedModels.contains(model.rawValue)
        let progress = models.downloadProgress[model.rawValue]

        HStack(spacing: 12) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .onTapGesture { if isDownloaded { select(model) } }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.label).fontWeight(isActive ? .semibold : .regular)
                    Text(model.approxSize).font(.caption2).foregroundStyle(.secondary)
                }
                Text(model.blurb).font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()

            if let progress {
                HStack(spacing: 6) {
                    ProgressView(value: progress).frame(width: 80)
                    Text("\(Int(progress * 100))%").font(.caption2).monospacedDigit()
                }
            } else if isDownloaded {
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green).labelStyle(.titleAndIcon)
                } else {
                    Button("Use") { select(model) }
                        .font(.caption)
                }
            } else {
                Button("Download") { Task { await models.download(model) } }
                    .font(.caption)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: Vault reconciliation

    private var vaultTab: some View {
        let rec = vault.reconcileCustomers()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Filing locations").font(.headline)
            Text("Scan roots (one per line) — their subfolders become the filing destinations offered in the picker.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $settings.scanRootsRaw)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 44).border(.quaternary)
            HStack {
                Text("Contacts file").font(.caption).foregroundStyle(.secondary)
                TextField("Rolodex.md", text: $settings.contactsFileName)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()
            HStack {
                Text("Customer reconciliation").font(.headline)
                Spacer()
                Button("Refresh") { vault.refresh() }
            }
            Text("Customer folders (\(vault.customerFolderNames.count)) ⟷ \(settings.contactsFileName) (\(vault.fileCustomers.count) listed)")
                .font(.caption).foregroundStyle(.secondary)

            if rec.isClean {
                Label("All customers reconciled.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.callout).padding(.top, 4)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !rec.nearMatches.isEmpty {
                            reconcileSection("Likely the same, spelled differently", systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                                ForEach(rec.nearMatches) { nm in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\(nm.folderName)  ⟷  \(nm.fileName)").font(.callout)
                                        Text(nm.reason).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if !rec.fileOnly.isEmpty {
                            reconcileSection("In \(settings.contactsFileName), no folder yet", systemImage: "folder.badge.plus", tint: .accentColor) {
                                ForEach(rec.fileOnly, id: \.self) { name in
                                    HStack {
                                        Text(name).font(.callout)
                                        Spacer()
                                        Button("Create folder") {
                                            let root = settings.scanRoots.first ?? "Internal"
                                            vault.ensureDestination("\(root)/Customers/\(name)")
                                        }
                                        .font(.caption)
                                    }
                                }
                            }
                        }
                        if !rec.folderOnly.isEmpty {
                            reconcileSection("Folders with no contacts logged", systemImage: "person.crop.circle.badge.questionmark", tint: .secondary) {
                                ForEach(rec.folderOnly, id: \.self) { name in
                                    Text(name).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { vault.refresh() }
    }

    @ViewBuilder
    private func reconcileSection<Content: View>(_ title: String, systemImage: String, tint: Color,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold)).foregroundStyle(tint)
            content()
                .padding(.leading, 6)
        }
    }

    /// Make a model active and immediately warm it in the background, so it's
    /// loaded by the time the user starts a recording.
    private func select(_ model: WhisperModel) {
        settings.model = model
        Task { await models.prepare(model) }
    }

    private var notesTab: some View {
        Form {
            Toggle("Automatically generate notes when a recording finishes", isOn: $settings.autoRunClaude)
            Text("When off, use the “Generate meeting notes” button on the Preview after a recording.")
                .font(.caption2).foregroundStyle(.tertiary)
            TextField("claude binary path", text: $settings.claudeBinaryPath)
            TextField("Claude model", text: $settings.claudeModel)
            VStack(alignment: .leading) {
                Text("Prompt template").font(.caption)
                TextEditor(text: $settings.claudePromptTemplate)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)
                    .border(.quaternary)
            }
        }
    }
}

/// The Active-model section shown when the FluidAudio engine is selected: the
/// Parakeet speech model with its download / ready state (replaces the Whisper
/// model list, which doesn't apply to this engine).
private struct FluidModelSection: View {
    @ObservedObject var models: FluidModelManager
    let isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speech model").font(.headline)
            Text("FluidAudio runs Parakeet on-device for transcription, plus diarization and speaker identification.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parakeet TDT 0.6b v3 (multilingual)").font(.body.weight(.semibold))
                    Text("Streaming on-device ASR. Downloads on first use.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                statusControl
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            if models.status == .downloaded {
                Label("Active — used automatically while the engine is FluidAudio. Start a recording to use it.",
                      systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Stored in \(FluidModelManager.modelsDirectory.path)")
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { models.refreshPresence() }
    }

    @ViewBuilder private var statusControl: some View {
        switch models.status {
        case .unknown, .notDownloaded:
            Button("Download") { models.download() }.disabled(isRecording)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        case .downloaded:
            Label("Active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .failed(let msg):
            VStack(alignment: .trailing, spacing: 2) {
                Button("Retry") { models.download() }.disabled(isRecording)
                Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}
