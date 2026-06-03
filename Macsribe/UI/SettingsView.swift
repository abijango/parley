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
    @State private var selectedSessions: Set<String> = []
    @State private var purgeDays = 14
    @State private var pendingBulkDelete: [RecordingFolder]?
    @State private var storageStatus: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            transcriptionTab
                .tabItem { Label("Transcription", systemImage: "waveform") }
            SpeakersSettingsView(store: recording.voiceprints,
                                 diarizationThreshold: settings.diarizationThreshold)
                .tabItem { Label("Speakers", systemImage: "person.2.wave.2") }
            notesTab
                .tabItem { Label("Notes", systemImage: "doc.text") }
            summaryTab
                .tabItem { Label("Summary", systemImage: "rectangle.split.3x1") }
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

    private var summaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Meeting summaries").font(.headline)
                Text("After a recording's speakers are assigned, Claude writes a summary in the background. When it's ready, review it in History → \"Review\", set where it's filed, then commit it to your vault.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                Toggle("Auto-summarize after speakers are assigned", isOn: $settings.autoRunClaude)
                Text("When off, summaries only run when you press Summarize on a transcript in History.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                Text("Claude model").font(.subheadline.weight(.semibold))
                TextField("sonnet", text: $settings.claudeModel)
                    .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: 220)
                HStack(spacing: 6) {
                    Text("CLI").font(.caption).foregroundStyle(.secondary)
                    TextField("~/.local/bin/claude", text: $settings.claudeBinaryPath)
                        .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                }
                Text("Runs `claude -p` (raw prompt, no skill/tools; extended thinking left on). Requires the Claude CLI to be installed + logged in.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                Text("Prompt").font(.subheadline.weight(.semibold))
                Text("The instructions Claude follows. Tokens: {{transcript}} {{contacts}} {{attendees}} {{destination}}.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $settings.summaryPromptTemplate)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    Spacer()
                    Button("Reset to default") { settings.summaryPromptTemplate = AppSettings.defaultSummaryPrompt }
                        .font(.caption)
                }
            }
            .padding()
        }
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
                if !selectedSessions.isEmpty {
                    Button("Delete selected (\(selectedSessions.count))", role: .destructive) { confirmDeleteSelected() }
                }
                Button("Refresh") { recordings.refresh() }
            }

            HStack(spacing: 8) {
                Text("Delete recordings older than").font(.callout)
                Picker("", selection: $purgeDays) {
                    ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                }
                .labelsHidden().fixedSize()
                Button("Delete older", role: .destructive) { confirmPurge() }
                Spacer()
            }
            if let storageStatus {
                Text(storageStatus).font(.caption2).foregroundStyle(.secondary)
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
        .confirmationDialog(
            "Delete \(pendingBulkDelete?.count ?? 0) recording\((pendingBulkDelete?.count ?? 0) == 1 ? "" : "s")?",
            isPresented: Binding(get: { pendingBulkDelete != nil }, set: { if !$0 { pendingBulkDelete = nil } })
        ) {
            if let folders = pendingBulkDelete, !folders.isEmpty {
                let bytes = folders.reduce(Int64(0)) { $0 + $1.sizeBytes }
                Button("Delete \(folders.count) · \(byteText(bytes))", role: .destructive) {
                    recordings.delete(folders)
                    selectedSessions.removeAll()
                    storageStatus = "Deleted \(folders.count) recording(s)."
                    pendingBulkDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingBulkDelete = nil }
        } message: {
            Text("Audio is removed permanently. Transcripts and notes in your vault are kept.")
        }
    }

    private func confirmDeleteSelected() {
        let folders = recordings.sessions.filter {
            selectedSessions.contains($0.id) && $0.id != recording.currentSessionID
        }
        if folders.isEmpty { storageStatus = "Nothing to delete."; return }
        storageStatus = nil
        pendingBulkDelete = folders
    }

    private func confirmPurge() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -purgeDays, to: Date()) ?? Date()
        let folders = recordings.sessions(olderThan: cutoff).filter { $0.id != recording.currentSessionID }
        if folders.isEmpty { storageStatus = "No recordings older than \(purgeDays) days."; return }
        storageStatus = nil
        pendingBulkDelete = folders
    }

    private func sessionRow(_ folder: RecordingFolder) -> some View {
        let isCurrent = folder.id == recording.currentSessionID
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selectedSessions.contains(folder.id) },
                set: { if $0 { selectedSessions.insert(folder.id) } else { selectedSessions.remove(folder.id) } }
            ))
            .labelsHidden().toggleStyle(.checkbox)
            .disabled(isCurrent)
            .help(isCurrent ? "Can't select the recording in progress" : "Select for bulk delete")

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

    /// Cross-session speaker-recognition sliders, shared by both speaker-capable
    /// engines (FluidAudio + WhisperKit + SpeakerKit).
    @ViewBuilder private var speakerRecognitionSection: some View {
        Text("Speaker recognition").font(.headline)
        HStack(spacing: 10) {
            Slider(value: $settings.identificationThreshold, in: 0.40...0.85, step: 0.05)
                .frame(maxWidth: 260)
            Text(String(format: "%.2f", settings.identificationThreshold))
                .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
        }
        Text("How close a voice must be to a saved person before it's auto-named. Higher = stricter (fewer wrong names, but may miss a known voice); lower = more eager (may attach the wrong person).")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
            Slider(value: $settings.minSpeechToIdentify, in: 2...15, step: 1)
                .frame(maxWidth: 260)
            Text("\(Int(settings.minSpeechToIdentify)) s")
                .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
        }
        Text("How much clean speech from a speaker before they're auto-identified and named. Lower names people sooner but on less evidence.")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
                Text("Live transcript").font(.headline)
                Toggle("Show a live transcript while recording", isOn: $settings.liveTranscriptEnabled)
                    .disabled(recording.isRecording)
                Text("Off = offline-only: capture audio silently and generate the full, speaker-attributed transcript in one fast pass when you stop. Turn on to also see streaming text during the call (uses the live model below) — at the cost of continuous live decoding.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                Text("Live model").font(.headline)
                Picker("", selection: Binding(
                    get: { settings.liveModel }, set: { settings.liveModel = $0 }
                )) {
                    ForEach(WhisperModel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).frame(maxWidth: 260).labelsHidden()
                .disabled(recording.isRecording || !settings.liveTranscriptEnabled)
                .opacity(settings.liveTranscriptEnabled ? 1 : 0.5)
                Text(settings.liveTranscriptEnabled
                     ? "Used for the fast LIVE transcript during a call. Pick a small/fast model so it keeps real-time — if you see \"OVERLOADED — skipped audio\" in the logs, choose a smaller one. (Speakers are labelled at stop regardless.)"
                     : "Only used when Live transcript is on.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                Text("Final model (at stop)").font(.headline)
                Text("Re-transcribes the whole recording when you stop — this is the SAVED transcript. Use the most accurate model you can; it only runs once and isn't real-time. Can be the same as the live model.")
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

                Divider()
                Text("Speaker detection").font(.headline)
                Text("SpeakerKit (pyannote v4, on the Neural Engine) labels who spoke. It runs once when the recording stops — the live transcript stays fast; speaker names appear at stop. Models download on first use.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                speakerRecognitionSection
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
                Text("How readily two voice samples are treated as the same person. Too high merges distinct speakers into one; too low fragments a single person's natural variation into several \"speakers\". ~0.6–0.7 suits most calls — only nudge it if you see one of those failure modes. Applies to the next recording.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                speakerRecognitionSection

                Divider()
                Text("Final transcript").font(.headline)
                Toggle("Re-transcribe the whole recording after stopping", isOn: $settings.offlineAsrRepass)
                Text("A full-context batch pass over the recorded audio — more accurate than the live streaming chunks. Runs once at stop (adds a few seconds) and rewrites the saved transcript. Turn off to keep the live transcript as-is.")
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
