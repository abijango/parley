import SwiftUI
import AppKit

/// Settings pane: eight tabs, all rendered as grouped forms (the System
/// Settings idiom) so every tab shares one container style, one inset rhythm,
/// and native section cards — replacing the three ad-hoc layout idioms the
/// design audit catalogued.
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
            vaultTab
                .tabItem { Label("Vault", systemImage: "folder") }
        }
        .frame(minWidth: 540, idealWidth: 600, maxWidth: .infinity,
               minHeight: 440, idealHeight: 500, maxHeight: .infinity)
    }

    /// One consistent caption treatment for explanatory text under a control.
    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One consistent border treatment for every TextEditor in Settings.
    private func editorStyle<V: View>(_ editor: V, height: CGFloat) -> some View {
        editor
            .font(Theme.Typography.mono)
            .frame(height: height)
            .overlay(Theme.Radius.rect(Theme.Radius.small).strokeBorder(.quaternary))
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section("Vault") {
                TextField("Obsidian vault path", text: $settings.vaultPath)
                LabeledContent("Transcripts folder") {
                    Text(AppPaths.unprocessedURL.path)
                        .font(Theme.Typography.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Section("Recording") {
                Picker("Default other-audio capture", selection: Binding(
                    get: { settings.captureMode }, set: { settings.captureMode = $0 }
                )) {
                    ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Logs") {
                HStack(spacing: Theme.Spacing.small) {
                    Text(AppLog.fileURL.path)
                        .font(Theme.Typography.captionSecondary).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Reveal Log") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
                    }
                    Button("Clear") { AppLog.clear() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Summary

    private var summaryTab: some View {
        Form {
            Section("Meeting summaries") {
                helpText("After a recording's speakers are assigned, Claude writes a summary in the background. When it's ready, review it in History → \"Review\", set where it's filed, then commit it to your vault.")
                Toggle("Auto-summarize after speakers are assigned", isOn: $settings.autoRunClaude)
                helpText("When off, summaries only run when you press Summarize on a transcript in History.")
                Toggle("Delete the recording's audio after committing its summary", isOn: $settings.deleteAudioAfterFiling)
                helpText("Once a summary is filed you have the raw transcript + the note, so the audio is redundant. Frees significant disk.")
            }

            Section("Claude") {
                LabeledContent("Model") {
                    TextField("sonnet", text: $settings.claudeModel)
                        .textFieldStyle(.roundedBorder).font(Theme.Typography.mono)
                        .frame(maxWidth: 220)
                }
                LabeledContent("CLI") {
                    TextField("~/.local/bin/claude", text: $settings.claudeBinaryPath)
                        .textFieldStyle(.roundedBorder).font(Theme.Typography.mono)
                }
                helpText("Runs `claude -p` (raw prompt, no skill/tools; extended thinking left on). Requires the Claude CLI to be installed + logged in.")
            }

            Section("Prompt") {
                helpText("The instructions Claude follows. Tokens: {{transcript}} {{contacts}} {{attendees}} {{destination}}.")
                editorStyle(TextEditor(text: $settings.summaryPromptTemplate), height: 220)
                HStack {
                    Spacer()
                    Button("Reset to default") { settings.summaryPromptTemplate = AppSettings.defaultSummaryPrompt }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Detection

    private var detectionTab: some View {
        Form {
            Section("Call detection") {
                Toggle("Detect calls automatically", isOn: $settings.callDetectionEnabled)
                Toggle("Auto-record when a known app starts a call", isOn: $settings.autoRecordEnabled)
                    .disabled(!settings.callDetectionEnabled)
                helpText("When auto-record is off, a notification with a Start button appears instead.")
            }

            Section("Permissions") {
                permissionRow("Microphone", ok: !recording.micDenied,
                              fix: PermissionManager.openMicrophoneSettings)
                permissionRow("System-audio recording", ok: recording.systemAudioAvailable ?? true,
                              unknown: recording.systemAudioAvailable == nil,
                              fix: PermissionManager.openPrivacySettings)
                helpText("Call detection watches which apps hold the microphone — both permissions must be granted for it to work reliably.")
            }

            Section("Known conferencing apps") {
                helpText("Bundle IDs, one per line (known = auto-record / unknown = notify only).")
                editorStyle(TextEditor(text: $settings.conferencingBundleIDsRaw), height: 120)
            }

            Section("Logging") {
                Toggle("Verbose detection logging", isOn: $settings.verboseDetectionLogging)
                HStack {
                    Text("Detection log")
                        .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal Log") { NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL]) }
                }
            }

            Section("Live detector status") {
                if let call = detector.activeCall {
                    Label("Active call: \(call.displayName)", systemImage: "phone.connection.fill")
                        .foregroundStyle(Theme.Severity.success.color)
                        .font(Theme.Typography.secondary)
                } else {
                    Text("No active call.")
                        .font(Theme.Typography.secondary).foregroundStyle(.secondary)
                }
                if detector.capturing.isEmpty {
                    Text("No apps capturing the microphone right now.")
                        .font(Theme.Typography.captionSecondary).foregroundStyle(.tertiary)
                } else {
                    ForEach(detector.capturing, id: \.pid) { p in
                        Text("• \(p.bundleID ?? "pid \(p.pid)")")
                            .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A granted/denied status line with a one-tap "Open Settings" when denied.
    private func permissionRow(_ label: String, ok: Bool, unknown: Bool = false,
                               fix: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: unknown ? "questionmark.circle" : (ok ? "checkmark.circle.fill" : "xmark.circle.fill"))
                .foregroundStyle(unknown ? Color.secondary
                                 : (ok ? Theme.Severity.success.color : Theme.Severity.danger.color))
            Text(label).font(Theme.Typography.secondary)
            Spacer()
            if unknown {
                Text("Checking…")
                    .font(Theme.Typography.captionSecondary).foregroundStyle(.tertiary)
            } else if !ok {
                Button("Open Settings", action: fix)
            }
        }
    }

    // MARK: Storage (manual recordings management)

    private var storageTab: some View {
        Form {
            Section {
                helpText("Raw call audio is kept here indefinitely — it's the source for re-transcribing or re-processing a recording. Deleting a session removes only its audio; the transcript and any note in your vault are untouched.")
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
            } header: {
                HStack {
                    Text("Recordings")
                    Spacer()
                    Text("\(recordings.sessions.count) · \(byteText(recordings.totalBytes))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }

            Section("Cleanup") {
                HStack(spacing: Theme.Spacing.small) {
                    Text("Delete recordings older than")
                    Picker("", selection: $purgeDays) {
                        ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Button("Delete older", role: .destructive) { confirmPurge() }
                    Spacer()
                }
                let orphans = orphanedSessions
                if !orphans.isEmpty {
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "questionmark.folder")
                            .foregroundStyle(Theme.Severity.warning.color)
                        Text("\(orphans.count) orphaned · \(byteText(orphans.reduce(Int64(0)) { $0 + $1.sizeBytes }))")
                            .font(Theme.Typography.secondary).foregroundStyle(.secondary).monospacedDigit()
                        Text("audio with no transcript in History")
                            .font(Theme.Typography.captionSecondary).foregroundStyle(.tertiary)
                        Spacer()
                        Button("Delete orphaned", role: .destructive) {
                            storageStatus = nil; pendingBulkDelete = orphans
                        }
                        .help("Raw audio whose transcript was deleted — you can no longer reach it from History.")
                    }
                }
                if let storageStatus {
                    Text(storageStatus)
                        .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                }
            }

            Section("Sessions") {
                if recordings.sessions.isEmpty {
                    Text("No recordings yet.")
                        .font(Theme.Typography.secondary).foregroundStyle(.secondary)
                } else {
                    ForEach(recordings.sessions) { folder in
                        sessionRow(folder)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Refresh transcripts too so orphaned-audio detection is accurate (a session looks
        // orphaned only when no transcript references it).
        .onAppear { recordings.refresh(); recording.store.refresh() }
        .confirmationDialog(
            "Move this recording's audio to the Trash?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { folder in
            Button("Move \(byteText(folder.sizeBytes)) to Trash", role: .destructive) {
                recordings.delete(folder); pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { folder in
            Text("“\(folder.title)” — the audio is moved to the Trash (recoverable). Any transcript or note already in your vault is kept.")
        }
        .confirmationDialog(
            "Delete \(pendingBulkDelete?.count ?? 0) recording\((pendingBulkDelete?.count ?? 0) == 1 ? "" : "s")?",
            isPresented: Binding(get: { pendingBulkDelete != nil }, set: { if !$0 { pendingBulkDelete = nil } })
        ) {
            if let folders = pendingBulkDelete, !folders.isEmpty {
                let bytes = folders.reduce(Int64(0)) { $0 + $1.sizeBytes }
                Button("Move \(folders.count) · \(byteText(bytes)) to Trash", role: .destructive) {
                    recordings.delete(folders)
                    selectedSessions.removeAll()
                    storageStatus = "Moved \(folders.count) recording(s) to the Trash."
                    pendingBulkDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingBulkDelete = nil }
        } message: {
            Text("Audio is moved to the Trash (recoverable). Transcripts and notes in your vault are kept.")
        }
    }

    /// Sessions whose folder no transcript references — unreachable from History. Excludes the
    /// live/interrupted session so an in-progress recording is never flagged as orphaned.
    private var orphanedSessions: [RecordingFolder] {
        let referenced = Set(recording.store.items.compactMap {
            MeetingFiles.sessionDir(forAudioPath: $0.meta.audio)?.standardizedFileURL.path
        })
        return recordings.orphanedSessions(referencedSessionPaths: referenced)
            .filter { $0.id != recording.currentSessionID && !$0.isActive }
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
        return HStack(spacing: Theme.Spacing.medium) {
            Toggle("", isOn: Binding(
                get: { selectedSessions.contains(folder.id) },
                set: { if $0 { selectedSessions.insert(folder.id) } else { selectedSessions.remove(folder.id) } }
            ))
            .labelsHidden().toggleStyle(.checkbox)
            .disabled(isCurrent)
            .help(isCurrent ? "Can't select the recording in progress" : "Select for bulk delete")

            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(folder.title)
                    .font(Theme.Typography.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: Theme.Spacing.small) {
                    Text(storageDateText(folder.date))
                        .font(Theme.Typography.captionSecondary).foregroundStyle(.tertiary)
                    if isCurrent {
                        Text("• recording now")
                            .font(Theme.Typography.captionSecondary)
                            .foregroundStyle(Theme.Severity.danger.color)
                    } else if folder.isActive {
                        Text("• interrupted")
                            .font(Theme.Typography.captionSecondary)
                            .foregroundStyle(Theme.Severity.warning.color)
                    }
                }
            }
            Spacer()
            Text(byteText(folder.sizeBytes))
                .font(Theme.Typography.caption).foregroundStyle(.secondary).monospacedDigit()
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
        .padding(.vertical, Theme.Spacing.xxSmall)
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func storageDateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: Transcription

    /// Cross-session speaker-recognition sliders, shared by both speaker-capable
    /// engines (FluidAudio + WhisperKit + SpeakerKit).
    @ViewBuilder private var speakerRecognitionSection: some View {
        Section("Speaker recognition") {
            HStack(spacing: Theme.Spacing.medium) {
                Slider(value: $settings.identificationThreshold, in: 0.40...0.85, step: 0.05)
                    .frame(maxWidth: 260)
                Text(String(format: "%.2f", settings.identificationThreshold))
                    .font(Theme.Typography.mono).foregroundStyle(.secondary)
            }
            helpText("How close a voice must be to a saved person before it's auto-named. Higher = stricter (fewer wrong names, but may miss a known voice); lower = more eager (may attach the wrong person).")
            HStack(spacing: Theme.Spacing.medium) {
                Slider(value: $settings.minSpeechToIdentify, in: 2...15, step: 1)
                    .frame(maxWidth: 260)
                Text("\(Int(settings.minSpeechToIdentify)) s")
                    .font(Theme.Typography.mono).foregroundStyle(.secondary)
            }
            helpText("How much clean speech from a speaker before they're auto-identified and named. Lower names people sooner but on less evidence.")
        }
    }

    private var transcriptionTab: some View {
        Form {
            Section("Engine") {
                Picker("Engine", selection: Binding(
                    get: { settings.transcriptionEngine }, set: { settings.transcriptionEngine = $0 }
                )) {
                    ForEach(TranscriptionEngineKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(recording.isRecording)   // engine applies to the next session, never mid-recording
                helpText(settings.transcriptionEngine.blurb)
            }

            if settings.transcriptionEngine == .whisperKit {
                Section("Live transcript") {
                    Toggle("Show a live transcript while recording", isOn: $settings.liveTranscriptEnabled)
                        .disabled(recording.isRecording)
                    helpText("Off = offline-only: capture audio silently and generate the full, speaker-attributed transcript in one fast pass when you stop. Turn on to also see streaming text during the call (uses the live model below) — at the cost of continuous live decoding.")
                }

                Section("Live model") {
                    Picker("Live model", selection: Binding(
                        get: { settings.liveModel }, set: { settings.liveModel = $0 }
                    )) {
                        ForEach(WhisperModel.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(maxWidth: 260)
                    .disabled(recording.isRecording || !settings.liveTranscriptEnabled)
                    .opacity(settings.liveTranscriptEnabled ? 1 : 0.5)
                    helpText(settings.liveTranscriptEnabled
                             ? "Used for the fast LIVE transcript during a call. Pick a small/fast model so it keeps real-time — if you see \"OVERLOADED — skipped audio\" in the logs, choose a smaller one. (Speakers are labelled at stop regardless.)"
                             : "Only used when Live transcript is on.")
                }

                Section("Final model (at stop)") {
                    helpText("Re-transcribes the whole recording when you stop — this is the SAVED transcript. Use the most accurate model you can; it only runs once and isn't real-time. Can be the same as the live model.")
                    ForEach(WhisperModel.allCases) { model in
                        modelRow(model)
                    }
                    .disabled(recording.isRecording)   // never swap the model out from under a live recording
                    Text("Stored in \(AppPaths.modelsDirectory.path)")
                        .font(Theme.Typography.captionSecondary).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                    if recording.isRecording {
                        Text("Model and compute can't be changed while recording.")
                            .font(Theme.Typography.captionSecondary).foregroundStyle(.tertiary)
                    }
                }

                Section("Compute") {
                    Picker("Compute", selection: Binding(
                        get: { settings.computeMode }, set: { settings.computeMode = $0 }
                    )) {
                        ForEach(ComputeMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .disabled(recording.isRecording)
                    helpText(settings.computeMode.blurb)
                    if let advisory = models.memoryAdvisory {
                        StatusBanner(.warning, advisory, symbol: "memorychip")
                    }
                }

                Section("Memory") {
                    Toggle("Unload the model when idle to free memory", isOn: $settings.idleUnloadEnabled)
                    if settings.idleUnloadEnabled {
                        Stepper("Unload after \(Int(settings.idleUnloadMinutes)) min idle",
                                value: $settings.idleUnloadMinutes, in: 1...60, step: 1)
                            .fixedSize()
                    }
                    helpText("Reclaims the model's memory after inactivity. It reloads on the next detected call or recording — capture starts immediately and the transcript catches up once the model finishes loading.")
                    HStack {
                        Text("If transcription crashes on load, the compiled-model cache may be corrupt.")
                            .font(Theme.Typography.captionSecondary).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Reset model cache") {
                            ModelManager.clearCompiledCache()
                            Task { await models.prepare(settings.model) }
                        }
                        .disabled(recording.isRecording)
                    }
                }

                Section("Speaker detection") {
                    helpText("SpeakerKit (pyannote v4, on the Neural Engine) labels who spoke. It runs once when the recording stops — the live transcript stays fast; speaker names appear at stop. Models download on first use.")
                }

                speakerRecognitionSection
            } else {
                FluidModelSection(models: recording.fluidModels, isRecording: recording.isRecording)

                Section("Speaker separation") {
                    HStack(spacing: Theme.Spacing.medium) {
                        Slider(value: $settings.diarizationThreshold, in: 0.40...0.80, step: 0.05)
                            .frame(maxWidth: 260)
                            .disabled(recording.isRecording)
                        Text(String(format: "%.2f", settings.diarizationThreshold))
                            .font(Theme.Typography.mono).foregroundStyle(.secondary)
                    }
                    helpText("How readily two voice samples are treated as the same person. Too high merges distinct speakers into one; too low fragments a single person's natural variation into several \"speakers\". ~0.6–0.7 suits most calls — only nudge it if you see one of those failure modes. Applies to the next recording.")
                }

                speakerRecognitionSection

                Section("Final transcript") {
                    Toggle("Re-transcribe the whole recording after stopping", isOn: $settings.offlineAsrRepass)
                    helpText("A full-context batch pass over the recorded audio — more accurate than the live streaming chunks. Runs once at stop (adds a few seconds) and rewrites the saved transcript. Turn off to keep the live transcript as-is.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { models.refreshDownloadedModels() }
        // Reload the model when the compute mode changes (forces a rebuild with
        // the new compute units; GPU drops the ANE specialization wait).
        .onChange(of: settings.computeModeRaw) {
            guard !recording.isRecording else { return }
            Task { await models.prepare(settings.model) }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: WhisperModel) -> some View {
        let isActive = settings.model == model
        let isDownloaded = models.downloadedModels.contains(model.rawValue)
        let progress = models.downloadProgress[model.rawValue]

        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Theme.Palette.accent : .secondary)
                .onTapGesture { if isDownloaded { select(model) } }

            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                HStack(spacing: Theme.Spacing.small) {
                    Text(model.label).fontWeight(isActive ? .semibold : .regular)
                    Text(model.approxSize)
                        .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                }
                Text(model.blurb)
                    .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
            }

            Spacer()

            if let progress {
                HStack(spacing: Theme.Spacing.small) {
                    ProgressView(value: progress).frame(width: 80)
                    Text("\(Int(progress * 100))%")
                        .font(Theme.Typography.captionSecondary).monospacedDigit()
                }
            } else if isDownloaded {
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Severity.success.color)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Use") { select(model) }
                }
            } else {
                Button("Download") { Task { await models.download(model) } }
            }
        }
        .padding(.vertical, Theme.Spacing.xxSmall)
        .contentShape(Rectangle())
    }

    // MARK: Vault reconciliation

    private var vaultTab: some View {
        let rec = vault.reconcileCustomers()
        return Form {
            Section("Filing locations") {
                helpText("Scan roots (one per line) — their subfolders become the filing destinations offered in the picker.")
                editorStyle(TextEditor(text: $settings.scanRootsRaw), height: 44)
                LabeledContent("Contacts file") {
                    TextField("Rolodex.md", text: $settings.contactsFileName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section {
                Text("Customer folders (\(vault.customerFolderNames.count)) ⟷ \(settings.contactsFileName) (\(vault.fileCustomers.count) listed)")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)

                if rec.isClean {
                    Label("All customers reconciled.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.Severity.success.color)
                        .font(Theme.Typography.secondary)
                } else {
                    if !rec.nearMatches.isEmpty {
                        reconcileSection("Likely the same, spelled differently",
                                         systemImage: "exclamationmark.triangle.fill",
                                         tint: Theme.Severity.warning.color) {
                            ForEach(rec.nearMatches) { nm in
                                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                                    Text("\(nm.folderName)  ⟷  \(nm.fileName)")
                                        .font(Theme.Typography.secondary)
                                    Text(nm.reason)
                                        .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if !rec.fileOnly.isEmpty {
                        reconcileSection("In \(settings.contactsFileName), no folder yet",
                                         systemImage: "folder.badge.plus",
                                         tint: Theme.Palette.accent) {
                            ForEach(rec.fileOnly, id: \.self) { name in
                                HStack {
                                    Text(name).font(Theme.Typography.secondary)
                                    Spacer()
                                    Button("Create folder") {
                                        let root = settings.scanRoots.first ?? "Internal"
                                        vault.ensureDestination("\(root)/Customers/\(name)")
                                    }
                                }
                            }
                        }
                    }
                    if !rec.folderOnly.isEmpty {
                        reconcileSection("Folders with no contacts logged",
                                         systemImage: "person.crop.circle.badge.questionmark",
                                         tint: .secondary) {
                            ForEach(rec.folderOnly, id: \.self) { name in
                                Text(name)
                                    .font(Theme.Typography.secondary).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Customer reconciliation")
                    Spacer()
                    Button("Refresh") { vault.refresh() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { vault.refresh() }
    }

    @ViewBuilder
    private func reconcileSection<Content: View>(_ title: String, systemImage: String, tint: Color,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Label(title, systemImage: systemImage)
                .font(Theme.Typography.caption.weight(.semibold)).foregroundStyle(tint)
            content()
                .padding(.leading, Theme.Spacing.small)
        }
    }

    /// Make a model active and immediately warm it in the background, so it's
    /// loaded by the time the user starts a recording.
    private func select(_ model: WhisperModel) {
        settings.model = model
        Task { await models.prepare(model) }
    }

    // MARK: Notes

    private var notesTab: some View {
        Form {
            Section("Notes generation") {
                Toggle("Automatically generate notes when a recording finishes", isOn: $settings.autoRunClaude)
                helpText("When off, use the “Generate meeting notes” button on the Preview after a recording.")
            }
            Section("Claude") {
                TextField("claude binary path", text: $settings.claudeBinaryPath)
                TextField("Claude model", text: $settings.claudeModel)
            }
            Section("Prompt template") {
                editorStyle(TextEditor(text: $settings.claudePromptTemplate), height: 120)
            }
        }
        .formStyle(.grouped)
    }
}

/// The Active-model section shown when the FluidAudio engine is selected: the
/// Parakeet speech model with its download / ready state (replaces the Whisper
/// model list, which doesn't apply to this engine).
private struct FluidModelSection: View {
    @ObservedObject var models: FluidModelManager
    let isRecording: Bool

    var body: some View {
        Section("Speech model") {
            Text("FluidAudio runs Parakeet on-device for transcription, plus diarization and speaker identification.")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .onAppear { models.refreshPresence() }

            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text("Parakeet TDT 0.6b v3 (multilingual)")
                        .font(Theme.Typography.controlLabel)
                    Text("Streaming on-device ASR. Downloads on first use.")
                        .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                }
                Spacer()
                statusControl
            }

            if models.status == .downloaded {
                Label("Active — used automatically while the engine is FluidAudio. Start a recording to use it.",
                      systemImage: "checkmark.seal.fill")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Stored in \(FluidModelManager.modelsDirectory.path)")
                .font(Theme.Typography.captionSecondary).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder private var statusControl: some View {
        switch models.status {
        case .unknown, .notDownloaded:
            Button("Download") { models.download() }.disabled(isRecording)
        case .downloading:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView().controlSize(.small)
                Text("Downloading…")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
        case .downloaded:
            Label("Active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.Severity.success.color)
                .font(Theme.Typography.secondary)
        case .failed(let msg):
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxSmall) {
                Button("Retry") { models.download() }.disabled(isRecording)
                Text(msg)
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(Theme.Severity.danger.color).lineLimit(2)
            }
        }
    }
}
