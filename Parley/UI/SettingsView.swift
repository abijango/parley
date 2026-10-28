import SwiftUI
import AppKit

/// Settings pane: seven tabs, all rendered as grouped forms (the System
/// Settings idiom) so every tab shares one container style, one inset rhythm,
/// and native section cards — replacing the three ad-hoc layout idioms the
/// design audit catalogued.
struct SettingsView: View {
    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var vault: VaultDirectory
    @EnvironmentObject private var detector: CallDetector
    @StateObject private var recordings = RecordingsStore()
    @State private var pendingDelete: RecordingFolder?
    @State private var selectedSessions: Set<String> = []
    @State private var purgeDays = 14
    @State private var pendingBulkDelete: [RecordingFolder]?
    @State private var storageStatus: String?
    /// AX trust has no change notification — refreshed when the Detection tab appears.
    @State private var axTrusted = PermissionManager.accessibilityAuthorized()
    @StateObject private var groundTruthEval = SummaryGroundTruthEval()

    /// Settings sections — rendered as a left sidebar (Cursor / System-Settings idiom)
    /// rather than top tabs.
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general, transcription, notes, summary, detection, storage, vault
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general:       return "General"
            case .transcription: return "Transcription"
            case .notes:         return "Notes"
            case .summary:       return "Summary"
            case .detection:     return "Detection"
            case .storage:       return "Storage"
            case .vault:         return "Vault"
            }
        }
        var icon: String {
            switch self {
            case .general:       return "gearshape"
            case .transcription: return "waveform"
            case .notes:         return "doc.text"
            case .summary:       return "rectangle.split.3x1"
            case .detection:     return "dot.radiowaves.left.and.right"
            case .storage:       return "internaldrive"
            case .vault:         return "folder"
            }
        }
    }

    @State private var selection: SettingsTab? = .general

    /// Cap the settings window to the visible screen (never larger than display).
    private var screenMaxSize: CGSize {
        let frame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(
            width: max(680, frame.width - 80),
            height: max(420, frame.height - 80))
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selection) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                detailContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Section name pinned like System Settings / Cursor preferences.
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Text((selection ?? .general).title)
                        .font(Theme.Typography.screenTitle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Spacing.xLarge)
                .padding(.top, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.small)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
            // macOS Form toggles default to a checkbox — force the switch.
            .toggleStyle(.switch)
            .tint(Theme.Palette.accent)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Settings")
        .frame(minWidth: 680, minHeight: 420)
        .background(SettingsWindowConfigurator(maxSize: screenMaxSize))
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .general {
        case .general:       generalTab
        case .transcription: transcriptionTab
        case .notes:         notesTab
        case .summary:       summaryTab
        case .detection:     detectionTab
        case .storage:       storageTab
        case .vault:         vaultTab
        }
    }

    /// One consistent caption treatment for explanatory text under a control.
    /// Shows the terms this meeting would boost, and why the rejects were rejected.
    /// The 2026-09-14 corruption was invisible precisely because nothing surfaced
    /// that "Steps", "Next" and "Carlos" had been handed to the recogniser.
    @ViewBuilder
    private var vocabularyPreview: some View {
        let candidates = FluidVocabularyBuilder.candidates(
            attendees: recording.meeting.attendees,
            meetingTitle: recording.meeting.meetingTitle,
            enabled: true)
        if candidates.isEmpty {
            helpText("No attendees or meeting title yet — nothing would be boosted.")
        } else {
            let included = candidates.filter(\.isIncluded)
            let excluded = candidates.filter { !$0.isIncluded }
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if included.isEmpty {
                    Text("Nothing would be boosted for this meeting.")
                        .font(Theme.Typography.caption).foregroundStyle(.secondary)
                } else {
                    Text("Boosting \(included.count) term\(included.count == 1 ? "" : "s")")
                        .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    ForEach(included, id: \.text) { candidate in
                        HStack(spacing: Theme.Spacing.small) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(candidate.text).font(Theme.Typography.mono)
                            if candidate.tier == .strictToken {
                                Text("strict match only")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !excluded.isEmpty {
                    Text("Held back (\(excluded.count))")
                        .font(Theme.Typography.caption).foregroundStyle(.secondary)
                        .padding(.top, 2)
                    ForEach(excluded, id: \.text) { candidate in
                        if case .excluded(let reason) = candidate.tier {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.secondary)
                                Text(candidate.text).font(Theme.Typography.mono)
                                Text(reason)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(.leading, Theme.Spacing.small)
        }
    }

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
            Section("Paths") {
                LabeledContent("Obsidian vault") {
                    TextField("path to your vault", text: $settings.vaultPath)
                        .textFieldStyle(.parley).frame(maxWidth: 280)
                }
                SettingRow("Transcripts folder") {
                    Text(AppPaths.unprocessedURL.path)
                        .font(Theme.Typography.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .frame(maxWidth: 280, alignment: .trailing)
                }
            }
            Section("Recording") {
                SettingRow("Default other-audio capture",
                           description: "How the far side of a call is captured when a recording starts.") {
                    Picker("", selection: Binding(
                        get: { settings.captureMode }, set: { settings.captureMode = $0 }
                    )) {
                        ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Section("Logs") {
                SettingRow("Diagnostic log", description: AppLog.fileURL.path) {
                    HStack(spacing: Theme.Spacing.small) {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
                        }
                        Button("Clear") { AppLog.clear() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Summary

    private var summaryTab: some View {
        Form {
            Section("Meeting summaries") {
                helpText("After a recording's speakers are assigned, a summary is written in the background. When it's ready, review it in History → \"Review\", set where it's filed, then commit it to your vault. The filed note includes the raw transcript at the bottom.")
                SettingRow("Pipeline",
                           description: "Summary v1 runs one backend. Summary v2 runs a writer then a checker that proposes structured edits for markup review.") {
                    Picker("", selection: $settings.summaryPipelineRaw) {
                        ForEach(SummaryPipeline.allCases) { p in
                            Text(p.label).tag(p.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
                SettingRow("Auto-summarize after speakers are assigned",
                           description: "When off, summaries only run when you press Summarize on a transcript in History.") {
                    Toggle("", isOn: $settings.autoRunClaude).labelsHidden()
                }
                SettingRow("Delete audio after committing its summary",
                           description: "Once a summary is filed the note includes the raw transcript inline, so the audio is redundant. Frees significant disk.") {
                    Toggle("", isOn: $settings.deleteAudioAfterFiling).labelsHidden()
                }
                SettingRow("Ask before summarizing a batch",
                           description: "When several notes become ready at once (a backlog, or naming speakers across many), ask once rather than running them all silently — so a burst never unexpectedly burns API usage.") {
                    Stepper(value: $settings.summaryBulkThreshold, in: 2...50) {
                        Text("\(settings.summaryBulkThreshold) notes").font(Theme.Typography.body)
                    }
                    .frame(maxWidth: 150)
                }
                SettingRow("Auto-resume after a usage limit",
                           description: "If the summary CLI hits a usage/rate limit, the queue pauses and resumes automatically when the limit lifts. Off keeps it paused until you press Resume.") {
                    Toggle("", isOn: $settings.summaryAutoResumeAfterLimit).labelsHidden()
                }
            }

            Section("Provider") {
                if settings.summaryPipeline == .v2 {
                    SettingRow("Writer", description: settings.summaryWriterBackend.blurb) {
                        Picker("", selection: $settings.summaryWriterBackendRaw) {
                            ForEach(SummaryBackend.writerBackends) { backend in
                                Text(backend.displayName).tag(backend.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }
                    SettingRow("Checker", description: settings.summaryCheckerBackend.blurb) {
                        Picker("", selection: $settings.summaryCheckerBackendRaw) {
                            ForEach(SummaryBackend.checkerBackends) { backend in
                                Text(backend.displayName).tag(backend.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }
                } else {
                    SettingRow("Summarize with", description: settings.summaryBackend.blurb) {
                        Picker("", selection: $settings.summaryBackendRaw) {
                            ForEach(SummaryBackend.allCases) { backend in
                                Text(backend.displayName).tag(backend.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }
                }
            }

            if settings.summaryPipeline == .v2
                || (settings.summaryPipeline == .classic && settings.summaryBackend.isCursorAgent) {
                Section("Cursor Agent") {
                    CursorConnectionView()
                    if settings.summaryPipeline == .classic {
                        LabeledContent("Model id") {
                            Text(settings.summaryBackend.rawValue)
                                .font(Theme.Typography.mono)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    LabeledContent("CLI") {
                        TextField("/usr/local/bin/cursor", text: $settings.cursorBinaryPath)
                            .textFieldStyle(.parley).font(Theme.Typography.mono)
                    }
                    helpText("Runs `cursor agent -p --mode ask --output-format json` with your Cursor subscription. Ask mode is read-only (no vault edits). Sign in once via Terminal if prompted.")
                }
            }

            if settings.summaryPipeline == .classic && settings.summaryBackend == .claude {
                Section("Claude") {
                    ClaudeConnectionView()
                    LabeledContent("Model") {
                        TextField("sonnet", text: $settings.claudeModel)
                            .textFieldStyle(.parley).font(Theme.Typography.mono)
                            .frame(maxWidth: 220)
                    }
                    LabeledContent("CLI") {
                        TextField("~/.local/bin/claude", text: $settings.claudeBinaryPath)
                            .textFieldStyle(.parley).font(Theme.Typography.mono)
                    }
                    helpText("Runs `claude -p` (raw prompt, no skill/tools). The status above shows whether the CLI is installed and logged in.")
                }
            } else if settings.summaryPipeline == .classic && settings.summaryBackend == .grok {
                Section("Grok") {
                    GrokConnectionView()
                    LabeledContent("Model") {
                        TextField("grok-4.6", text: $settings.grokModel)
                            .textFieldStyle(.parley).font(Theme.Typography.mono)
                            .frame(maxWidth: 220)
                    }
                    LabeledContent("CLI") {
                        TextField("~/.grok/bin/grok", text: $settings.grokBinaryPath)
                            .textFieldStyle(.parley).font(Theme.Typography.mono)
                    }
                    helpText("Runs `grok -p` (raw prompt, no vault tools; JSON on stdout). The status above shows whether the CLI is installed and logged in.")
                }
            }

            Section("Attachments") {
                SettingRow("Include in summaries",
                           description: settings.attachmentUnderstanding.blurb) {
                    Picker("", selection: $settings.attachmentUnderstandingRaw) {
                        ForEach(AttachmentUnderstanding.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280)
                }
                if settings.attachmentUnderstanding == .vision {
                    Picker("Vision backend", selection: $settings.attachmentVisionBackendRaw) {
                        ForEach(SummaryBackend.allCases.filter(\.isCursorAgent)) { backend in
                            Text(backend.displayName).tag(backend.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    helpText("Runs a read-only Cursor agent pass in plan mode to describe images before summarizing.")
                }
            }

            Section("Prompt") {
                helpText("The instructions the summarizer follows (same for every backend). Tokens: {{transcript}} {{contacts}} {{attendees}} {{destination}}.")
                editorStyle(TextEditor(text: $settings.summaryPromptTemplate), height: 220)
                HStack {
                    Spacer()
                    Button("Reset to default") { settings.summaryPromptTemplate = AppSettings.defaultSummaryPrompt }
                }
            }

            Section("Ground truth check") {
                helpText("Re-runs the selected summarizer on one approved meeting and scores it against the filed note. Use it when a new model ships to compare cost, speed, and how many approved facts it still captures. Fact recall is lexical: a fact counts when most of its names and numbers show up. The check does not file a note.")
                SettingRow("Example", description: SummaryGroundTruth.rationale) {
                    Text(SummaryGroundTruth.displayTitle)
                        .font(Theme.Typography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 280, alignment: .trailing)
                }
                SettingRow(settings.summaryPipeline == .v2 ? "Writer" : "Summarizer",
                           description: settings.summaryPipeline == .v2
                               ? "Scores the writer alone, not the checker pass."
                               : nil) {
                    Button(groundTruthEval.phase == .running ? "Running…" : "Run check") {
                        let backend = settings.summaryPipeline == .v2
                            ? settings.summaryWriterBackend
                            : settings.summaryBackend
                        groundTruthEval.run(backend: backend, settings: settings)
                    }
                    .disabled(groundTruthEval.phase == .running)
                }
                if case .failed(let reason) = groundTruthEval.phase {
                    helpText(reason)
                }
                if let report = groundTruthEval.report {
                    let recall = Int((report.score.recall * 100).rounded())
                    let metricsLine = SummaryMetricsFormat.compactLine(metrics: report.metrics)?.text
                    SettingRow(report.backendName) {
                        Text("\(recall)% fact recall (\(report.score.matched)/\(report.score.total))")
                            .font(Theme.Typography.body)
                            .monospacedDigit()
                    }
                    if let metricsLine {
                        helpText(metricsLine)
                    }
                    if !report.score.missedPreviews.isEmpty {
                        helpText("Missed: " + report.score.missedPreviews.prefix(4).joined(separator: " · "))
                    }
                }
            }

            if settings.summaryPipeline == .v2 {
                Section("Checker instructions") {
                    helpText("Rules the checker follows when reviewing the writer's draft. The transcript, contacts, attendees, and draft are appended automatically — no {{tokens}} here.")
                    editorStyle(TextEditor(text: $settings.summaryCheckerPromptTemplate), height: 220)
                    HStack {
                        Spacer()
                        Button("Reset to default") {
                            settings.summaryCheckerPromptTemplate = SummaryCheckerPromptBuilder.defaultInstructions
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Detection

    private var detectionTab: some View {
        Form {
            Section("Call detection") {
                SettingRow("Detect calls automatically") {
                    Toggle("", isOn: $settings.callDetectionEnabled).labelsHidden()
                }
                SettingRow("Auto-record when a known app starts a call",
                           description: "When off, a notification with a Start button appears instead.") {
                    Toggle("", isOn: $settings.autoRecordEnabled).labelsHidden()
                        .disabled(!settings.callDetectionEnabled)
                }
                SettingRow("Suggest meeting title & attendees",
                           description: "Reads the meeting window via Accessibility. In-call people are added automatically; invite-list names are not. Rooms and devices stay as chips.") {
                    Toggle("", isOn: $settings.metadataDiscoveryEnabled).labelsHidden()
                        .disabled(!settings.callDetectionEnabled)
                }
                SettingRow("Call-end grace",
                           description: "How long after the app releases the microphone before the call is treated as ended and recording stops.") {
                    HStack(spacing: Theme.Spacing.medium) {
                        Slider(value: $settings.callEndGraceSeconds, in: 5...60, step: 1)
                            .frame(maxWidth: 260)
                        Text("\(Int(settings.callEndGraceSeconds))s")
                            .font(Theme.Typography.mono).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .disabled(!settings.callDetectionEnabled)
                }
            }

            Section("After a meeting") {
                SettingRow("Clear for the next call",
                           description: "Once a recording finishes, reset the title, attendees, filing, notes and transcript. Pauses only during speaker review; any edit cancels it.") {
                    Picker("", selection: $settings.autoClearSeconds) {
                        Text("Off").tag(0.0)
                        Text("15s").tag(15.0)
                        Text("30s").tag(30.0)
                        Text("1m").tag(60.0)
                        Text("2m").tag(120.0)
                    }
                    .labelsHidden().fixedSize()
                }
                SettingRow("Idle before background work",
                           description: "How long to stay idle after a call before summaries start, and before speaker detection when Batch mode is off. Batch transcription starts as soon as the recording is saved. Starting a new recording cancels this wait.") {
                    Picker("", selection: $settings.idleDrainSeconds) {
                        Text("Off").tag(0.0)
                        Text("30s").tag(30.0)
                        Text("1m").tag(60.0)
                        Text("2m").tag(120.0)
                    }
                    .labelsHidden().fixedSize()
                }
                SettingRow("Quiet hours for held jobs",
                           description: "Held speaker passes and summaries stay parked during the day. From 22:00–07:00 they may run after the idle wait above.") {
                    Toggle("", isOn: $settings.quietHoursEnabled).labelsHidden()
                }
            }

            Section("Permissions") {
                permissionRow("Microphone", ok: !recording.micDenied,
                              fix: PermissionManager.openMicrophoneSettings)
                permissionRow("System-audio recording", ok: recording.systemAudioAvailable ?? true,
                              unknown: recording.systemAudioAvailable == nil,
                              fix: PermissionManager.openPrivacySettings)
                permissionRow("Accessibility (meeting details)", ok: axTrusted,
                              fix: PermissionManager.openAccessibilitySettings)
                helpText("Call detection watches which apps hold the microphone. Accessibility is only needed for title/attendee suggestions — recording works without it.")
            }

            Section("Known conferencing apps") {
                helpText("Bundle IDs, one per line (known = auto-record / unknown = notify only).")
                editorStyle(TextEditor(text: $settings.conferencingBundleIDsRaw), height: 120)
            }

            Section("Logging") {
                SettingRow("Verbose detection logging") {
                    Toggle("", isOn: $settings.verboseDetectionLogging).labelsHidden()
                }
                SettingRow("Detection log") {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL]) }
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
        .onAppear { axTrusted = PermissionManager.accessibilityAuthorized() }
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
                    Text("\(recordings.sessions.count) · \(storageTotalLabel)")
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
                    let orphanBytes = orphans.compactMap(\.sizeBytes).reduce(Int64(0), +)
                    let orphanSuffix = orphans.contains { $0.sizeBytes == nil } ? "+" : ""
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "questionmark.folder")
                            .foregroundStyle(Theme.Severity.warning.color)
                        Text("\(orphans.count) orphaned · \(byteText(orphanBytes))\(orphanSuffix)")
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
                    Label {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                            Text("No recordings yet")
                            Text("Session folders appear here after you record a meeting.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.secondary)
                    }
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
            Button("Move \(byteText(folder.sizeBytes ?? 0)) to Trash", role: .destructive) {
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
                let bytes = folders.compactMap(\.sizeBytes).reduce(Int64(0), +)
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
            Text(folder.sizeBytes.map(byteText) ?? "…")
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

    private var storageTotalLabel: String {
        if recordings.sizesPending {
            return "\(byteText(recordings.totalBytes))+"
        }
        return byteText(recordings.totalBytes)
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

    /// Cross-session speaker-recognition sliders for FluidAudio.
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
            helpText("Manage voiceprints — rebuild, delete, and backup — in the People tab.")
        }
    }

    private var transcriptionTab: some View {
        Form {
            Section("Batch mode") {
                SettingRow("Batch mode",
                           description: "Record audio only. Transcription starts as soon as the call ends and keeps running while the next call records. English uses the accurate offline model. Any other language uses Parakeet v3.") {
                    Toggle("", isOn: $settings.batchMode).labelsHidden()
                }
                Picker("When", selection: Binding(
                    get: { settings.transcriptionTiming },
                    set: { settings.transcriptionTiming = $0 }
                )) {
                    Text("After each call").tag(TranscriptionTiming.afterCall)
                    Text("During a daily window").tag(TranscriptionTiming.window)
                }
                .disabled(!settings.batchMode)
                if settings.batchMode && settings.transcriptionTiming == .window {
                    Stepper(value: $settings.transcriptionWindowStartHour, in: 0...23) {
                        Text(String(format: "Starts %02d:00", settings.transcriptionWindowStartHour))
                    }
                    Stepper(value: $settings.transcriptionWindowEndHour, in: 0...23) {
                        Text(String(format: "Ends %02d:00", settings.transcriptionWindowEndHour))
                    }
                    helpText("Outside this window, recordings wait. Transcribe Now on a History row runs that one next. Overnight windows are allowed, for example 22:00 to 07:00.")
                }
            }

            FluidModelSection(models: recording.fluidModels, settings: settings, isRecording: recording.isRecording)

                Section("English optimization") {
                    Toggle("Parakeet Unified (English)", isOn: $settings.useParakeetUnified)
                        .disabled(recording.isRecording)
                    helpText("When the live language is English, use Parakeet Unified 0.6B for streaming (~2 s latency) and a full-attention offline batch pass. Non-English sessions keep Nemotron multilingual + TDT v3.")
                    Toggle("Boost attendee names in transcript", isOn: $settings.boostAttendeeNames)
                        .disabled(recording.isRecording)
                    helpText("Imports attendee names and meeting-title tokens into custom vocabulary for the offline batch re-pass (multilingual path only). Boosting doesn't just hint — it overwrites speech that resembles a term, so short and ordinary words are held back or rejected. The list below shows exactly what this meeting would boost.")
                    if settings.boostAttendeeNames {
                        vocabularyPreview
                    }
                }

                Section("Speaker separation") {
                    HStack(spacing: Theme.Spacing.medium) {
                        Slider(value: $settings.diarizationThreshold, in: 0.40...0.80, step: 0.05)
                            .frame(maxWidth: 260)
                            .disabled(recording.isRecording)
                        Text(String(format: "%.2f", settings.diarizationThreshold))
                            .font(Theme.Typography.mono).foregroundStyle(.secondary)
                    }
                    helpText("How readily two voice samples are treated as the same person during in-session clustering. Too high merges distinct speakers into one; too low fragments a single person's natural variation into several \"speakers\". ~0.6–0.7 suits most calls — only nudge it if you see one of those failure modes.")
                }

                speakerRecognitionSection

                Section("Live transcript") {
                    if FluidAsrRouting.usesParakeetUnified(settings: settings) {
                        Text("Parakeet Unified 2080 ms streaming (English). Latency tier applies to the Nemotron multilingual path only.")
                            .font(Theme.Typography.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("Latency", selection: Binding(
                            get: { settings.liveStreamingTier },
                            set: { settings.liveStreamingTier = $0 }
                        )) {
                            ForEach(FluidStreamingTier.allCases) { Text($0.label).tag($0) }
                        }
                        .disabled(recording.isRecording)
                    }
                    Picker("Language", selection: $settings.liveStreamingLanguage) {
                        Text("Auto (all languages)").tag("auto")
                        Text("English").tag("en-US")
                        Text("Spanish").tag("es")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Italian").tag("it")
                        Text("Portuguese").tag("pt")
                        Text("Chinese").tag("zh-CN")
                        Text("Japanese").tag("ja")
                    }
                    .disabled(recording.isRecording)
                    helpText("Cache-aware streaming ASR shows the transcript within ~one chunk while recording — far faster than the old sliding-window (~11 s) approach. Smaller chunks = lower latency, larger = higher accuracy. \"Auto\" uses the full multilingual model (covers Chinese/Japanese); picking a Latin-script language loads a smaller, faster model. The accurate final transcript still comes from the re-pass below.")
                }

                Section("Final transcript") {
                    Toggle("Re-transcribe the whole recording after stopping", isOn: $settings.offlineAsrRepass)
                    helpText("A full-context batch pass over the recorded audio — more accurate than the live streaming chunks. Runs once at stop (adds a few seconds) and rewrites the saved transcript. Turn off to keep the live transcript as-is.")
                }

                Section("Advanced") {
                    Toggle("GPU encoder (Parakeet v3 offline)", isOn: $settings.fluidGpuEncoder)
                        .disabled(recording.isRecording)
                    helpText("Runs the multilingual TDT v3 conformer encoder on GPU during the offline re-pass (~8% faster, WER-neutral). Parakeet Unified manages placement internally.")
                }

            Section("Memory") {
                SettingRow("Unload the model when idle",
                           description: "Reclaims streaming model memory after inactivity. It reloads on the next detected call or recording — capture starts immediately and the transcript catches up once the model finishes loading.") {
                    Toggle("", isOn: $settings.idleUnloadEnabled).labelsHidden()
                }
                if settings.idleUnloadEnabled {
                    SettingRow("Unload after idle") {
                        Stepper("\(Int(settings.idleUnloadMinutes)) min",
                                value: $settings.idleUnloadMinutes, in: 1...60, step: 1)
                            .fixedSize()
                    }
                }
                SettingRow("Reset model cache",
                           description: "If transcription crashes on load, the compiled-model cache may be corrupt. Resetting rebuilds it on the next load.") {
                    Button("Reset") {
                        FluidModelManager.clearCompiledCache()
                        Task { _ = await recording.fluidModels.prepare() }
                    }
                    .disabled(recording.isRecording)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Vault reconciliation

    @State private var knowledgeStatus: String?

    private var vaultTab: some View {
        let rec = vault.reconcileCustomers()
        return Form {
            Section("Filing locations") {
                helpText("Scan roots (one per line) — their subfolders become the filing destinations offered in the picker.")
                editorStyle(TextEditor(text: $settings.scanRootsRaw), height: 44)
                LabeledContent("Contacts file") {
                    TextField("Rolodex.md", text: $settings.contactsFileName)
                        .textFieldStyle(.parley)
                }
            }

            Section("Knowledge export / import") {
                if let knowledgeStatus {
                    Text(knowledgeStatus)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Export JSON…") { exportKnowledgeJSON() }
                    Button("Import JSON…") { importKnowledgeJSON() }
                    Button("Import from Rolodex") { importRolodexToDB() }
                    Button("Export Rolodex.md") { exportDBToRolodex() }
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
        .onAppear {
            vault.refresh()
            vault.importRolodexIfDBEmpty()
        }
    }

    private func exportKnowledgeJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "parley-knowledge.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try KnowledgeExportImport.exportJSON()
            try data.write(to: url)
            knowledgeStatus = "Exported knowledge to \(url.lastPathComponent)."
        } catch {
            knowledgeStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importKnowledgeJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try KnowledgeExportImport.importJSON(Data(contentsOf: url))
            vault.refresh(waitForCompletion: true)
            knowledgeStatus = "Imported knowledge from \(url.lastPathComponent)."
        } catch {
            knowledgeStatus = "Import failed: \(error.localizedDescription)"
        }
    }

    private func importRolodexToDB() {
        vault.importRolodexToKnowledgeDB(force: true)
        knowledgeStatus = "Imported Rolodex into knowledge database."
    }

    private func exportDBToRolodex() {
        vault.exportKnowledgeDBToRolodex()
        knowledgeStatus = "Wrote contacts to \(settings.contactsFileName)."
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

    // MARK: Notes

    private var notesTab: some View {
        Form {
            Section {
                LabeledContent("CLI") {
                    TextField("~/.local/bin/claude", text: $settings.claudeBinaryPath)
                        .textFieldStyle(.parley).font(Theme.Typography.mono)
                }
                LabeledContent("Model") {
                    TextField("sonnet", text: $settings.claudeModel)
                        .textFieldStyle(.parley).font(Theme.Typography.mono)
                        .frame(maxWidth: 220)
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("Meeting notes are generated from the Preview tab after a recording — use the “Generate meeting notes” button on the action bar.")
            }
            Section("Prompt template") {
                editorStyle(TextEditor(text: $settings.claudePromptTemplate), height: 120)
            }
        }
        .formStyle(.grouped)
    }
}

/// Status for the Cursor CLI used by Composer / Cursor Grok summary backends.
private struct CursorConnectionView: View {
    @ObservedObject private var connection = CursorConnection.shared

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: badge.symbol)
                .foregroundStyle(badge.color)
                .font(.system(size: 13, weight: .semibold))
            Text(badge.title).font(Theme.Typography.controlLabel)
            if connection.isChecking {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Re-check") { connection.refresh() }
                .disabled(connection.isChecking)
        }
        .onAppear { connection.refresh() }
    }

    private var badge: (symbol: String, color: Color, title: String) {
        switch connection.status {
        case .unknown:
            return ("questionmark.circle", .secondary, "Checking Cursor CLI…")
        case .notInstalled:
            return ("xmark.circle.fill", .red, "Cursor CLI not found")
        case .ready:
            let path = connection.resolvedBinaryPath.map { " — \($0)" } ?? ""
            return ("checkmark.circle.fill", .green, "Cursor ready\(path)")
        case .failed(let detail):
            return ("exclamationmark.triangle.fill", .orange, detail)
        }
    }
}

private struct FluidModelSection: View {
    @ObservedObject var models: FluidModelManager
    @ObservedObject var settings: AppSettings
    let isRecording: Bool

    private var modelLabel: String {
        if FluidAsrRouting.usesParakeetUnified(settings: settings) {
            return "Parakeet Unified 0.6B (English)"
        }
        return "Parakeet TDT 0.6b v3 (multilingual)"
    }

    var body: some View {
        Section("Speech model") {
            Text("FluidAudio runs Parakeet on-device for transcription, plus diarization and speaker identification.")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .onAppear { models.refreshPresence() }

            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(modelLabel)
                        .font(Theme.Typography.controlLabel)
                    Text("Streaming on-device ASR. Downloads on first use.")
                        .font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                }
                Spacer()
                statusControl
            }

            if models.status == .downloaded {
                Label("Active — used automatically when you record. Start a recording to use it.",
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
        case .loading:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView().controlSize(.small)
                Text("Loading…")
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

/// Makes the Settings window freely resizable and clamps max size to the screen.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    var maxSize: CGSize

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window, coordinator: context.coordinator) }
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        if !coordinator.didConfigure {
            coordinator.didConfigure = true
            window.styleMask.insert(.resizable)
            window.title = "Settings"
            window.minSize = NSSize(width: 680, height: 420)
        }
        window.maxSize = NSSize(width: maxSize.width, height: maxSize.height)
    }

    final class Coordinator {
        var didConfigure = false
    }
}
