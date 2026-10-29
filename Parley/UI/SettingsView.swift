import SwiftUI
import AppKit

/// The Settings window (Claude-app style): a sidebar with search and grouped pages, and
/// a roomy content column of titled sections with label-left / control-right rows (see
/// `SettingsLayout.swift`). Searching shows every matching row across all pages.
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
    /// AX trust has no change notification — refreshed when the Permissions page appears.
    @State private var axTrusted = PermissionManager.accessibilityAuthorized()
    @StateObject private var groundTruthEval = SummaryGroundTruthEval()
    @State private var knowledgeStatus: String?

    @State private var page: Page = .general
    @State private var searchText = ""
    @State private var pageMatchCounts: [Page: Int] = [:]
    @State private var editing: LongEditor?
    /// Glossary editor text; written back to the knowledge DB when the sheet closes.
    @State private var glossaryDraft = ""
    @FocusState private var searchFocused: Bool

    enum Page: String, CaseIterable, Identifiable {
        case general, detection, transcription, summaries, contacts, storage, permissions, developer
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general:       return "General"
            case .detection:     return "Call detection"
            case .transcription: return "Transcription"
            case .summaries:     return "Summaries"
            case .contacts:      return "Contacts and filing"
            case .storage:       return "Storage"
            case .permissions:   return "Permissions"
            case .developer:     return "Developer"
            }
        }
        var icon: String {
            switch self {
            case .general:       return "gearshape"
            case .detection:     return "phone.connection"
            case .transcription: return "waveform"
            case .summaries:     return "sparkles"
            case .contacts:      return "person.crop.rectangle.stack"
            case .storage:       return "internaldrive"
            case .permissions:   return "lock.shield"
            case .developer:     return "chevron.left.forwardslash.chevron.right"
            }
        }
        var group: String {
            switch self {
            case .general, .detection, .transcription, .summaries: return "Settings"
            case .contacts, .storage: return "Library"
            case .permissions, .developer: return "Advanced"
            }
        }
    }

    /// Long text settings, edited in a sheet.
    enum LongEditor: String, Identifiable {
        case summaryPrompt, checkerInstructions, notesPrompt, conferencingApps, scanRoots, glossary
        var id: String { rawValue }
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Cap the settings window to the visible screen (never larger than display).
    private var screenMaxSize: CGSize {
        let frame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(width: max(760, frame.width - 80), height: max(520, frame.height - 80))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().ignoresSafeArea(.container, edges: .top)
            content
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Theme.Palette.windowBg)
        .toggleStyle(.switch)
        .tint(Theme.Palette.ink)
        .background(SettingsWindowConfigurator(maxSize: screenMaxSize))
        .sheet(item: $editing) { editor in editorSheet(editor) }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            searchField
                .padding(.bottom, Theme.Spacing.small)
            ForEach(["Settings", "Library", "Advanced"], id: \.self) { group in
                Text(group)
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.top, Theme.Spacing.medium)
                    .padding(.bottom, Theme.Spacing.xSmall)
                ForEach(Page.allCases.filter { $0.group == group }) { p in
                    navRow(p)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.top, Theme.Spacing.small)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.sidebarBg.ignoresSafeArea())
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField("Search settings", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onAppear { searchFocused = true }
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .font(Theme.Typography.body)
        .padding(.horizontal, Theme.Spacing.small + 2)
        .frame(height: 30)
        .background(Theme.Radius.rect(Theme.Radius.small).fill(Theme.Palette.panelBg))
        .overlay(Theme.Radius.rect(Theme.Radius.small).strokeBorder(Theme.Palette.divider, lineWidth: 0.5))
    }

    private func navRow(_ p: Page) -> some View {
        let count = pageMatchCounts[p] ?? 0
        let dimmed = !query.isEmpty && count == 0
        return Button {
            searchText = ""
            page = p
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: p.icon)
                    .frame(width: 20)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(p.title)
                    .foregroundStyle(Theme.Palette.textBody)
                Spacer(minLength: 0)
                if !query.isEmpty, count > 0 {
                    Text("\(count)")
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .monospacedDigit()
                }
            }
            .font(Theme.Typography.body)
        }
        .buttonStyle(.row(selected: query.isEmpty && page == p))
        .opacity(dimmed ? 0.4 : 1)
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if query.isEmpty {
                    pageTitle(page.title)
                    pageBody(page)
                } else {
                    pageTitle("Results for “\(searchText.trimmingCharacters(in: .whitespaces))”")
                    ForEach(Page.allCases) { p in
                        SearchPageGroup(page: p, query: query) { pageBody(p) }
                    }
                    if pageMatchCounts.values.reduce(0, +) == 0 {
                        Text("No settings match. Try “audio”, “summary”, or “log”.")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .padding(.top, Theme.Spacing.large)
                    }
                }
            }
            .environment(\.settingsQuery, query)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.xxLarge)
            .padding(.top, Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.xxLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onPreferenceChange(PageMatchCountsKey.self) { pageMatchCounts = $0 }
        }
        .scrollContentBackground(.hidden)
    }

    private func pageTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.screenTitle)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.bottom, Theme.Spacing.xSmall)
    }

    @ViewBuilder private func pageBody(_ p: Page) -> some View {
        switch p {
        case .general:       generalPage
        case .detection:     detectionPage
        case .transcription: transcriptionPage
        case .summaries:     summariesPage
        case .contacts:      contactsPage
        case .storage:       storagePage
        case .permissions:   permissionsPage
        case .developer:     developerPage
        }
    }

    // MARK: Shared bits

    /// A compact menu picker sized for the control column.
    private func menuPicker<V: Hashable, Content: View>(_ selection: Binding<V>,
                                                        @ViewBuilder _ options: () -> Content) -> some View {
        Picker("", selection: selection, content: options)
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
    }

    private func editButton(_ editor: LongEditor) -> some View {
        Button("Edit…") { editing = editor }.glassButton()
    }

    private func pathField(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.parley)
            .font(Theme.Typography.mono)
            .frame(width: 280)
    }

    @ViewBuilder private func editorSheet(_ editor: LongEditor) -> some View {
        switch editor {
        case .summaryPrompt:
            SettingsEditorSheet(
                title: "Summary prompt",
                detail: "The instructions the summarizer follows (same for every backend). Tokens: {{transcript}} {{contacts}} {{attendees}} {{invitees}} {{glossary}} {{me}} {{my_company}} {{destination}}. A token with no data renders a placeholder; without {{glossary}} the glossary is added before the transcript.",
                text: $settings.summaryPromptTemplate,
                resetValue: AppSettings.defaultSummaryPrompt)
        case .checkerInstructions:
            SettingsEditorSheet(
                title: "Checker instructions",
                detail: "Rules the checker follows when reviewing the writer's draft. The transcript, contacts, attendees, and draft are appended automatically — no {{tokens}} here.",
                text: $settings.summaryCheckerPromptTemplate,
                resetValue: SummaryCheckerPromptBuilder.defaultInstructions)
        case .notesPrompt:
            SettingsEditorSheet(
                title: "Meeting notes prompt",
                detail: "Agent command for generating meeting notes from a recording. Tokens: {{file}} {{destination}} {{attendees}} {{invitees}} {{me}} {{my_company}}.",
                text: $settings.claudePromptTemplate,
                resetValue: AppSettings.defaultClaudePrompt)
        case .glossary:
            SettingsEditorSheet(
                title: "Glossary",
                detail: "Canonical spellings for companies, products, and terms, one per line as `Canonical: misheard, other spelling` — e.g. `LSEG: Elseg, L Seg, LSEC`. Sent to summaries as {{glossary}} and boosted in the offline transcript. Customer-specific corrections made during summary review are kept separately.",
                text: $glossaryDraft)
                .onDisappear { TerminologyStore().replaceGlobalGlossary(with: glossaryDraft) }
        case .conferencingApps:
            SettingsEditorSheet(
                title: "Known conferencing apps",
                detail: "Bundle IDs, one per line. Known apps can auto-record; others only notify.",
                text: $settings.conferencingBundleIDsRaw,
                resetValue: AppSettings.defaultConferencingBundleIDs)
        case .scanRoots:
            SettingsEditorSheet(
                title: "Filing locations",
                detail: "Scan roots, one per line. Their subfolders become the filing destinations offered in the picker.",
                text: $settings.scanRootsRaw)
        }
    }

    // MARK: General

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Vault") {
                SettingRow("Obsidian vault", description: "Where notes, transcripts, and contacts live.",
                           keywords: "path folder") {
                    pathField("path to your vault", $settings.vaultPath)
                }
                SettingRow("Transcripts folder", description: AppPaths.unprocessedURL.path) {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.unprocessedURL])
                    }
                    .glassButton()
                }
            }
            SettingsSection("Recording") {
                SettingRow("Default other-audio capture",
                           description: "How the far side of a call is captured when a recording starts.",
                           keywords: "system audio per app") {
                    PillPicker(selection: Binding(
                        get: { settings.captureMode }, set: { settings.captureMode = $0 }
                    ), options: CaptureMode.allCases) { Text($0.label) }
                }
                SettingRow("Start or stop recording",
                           description: "Keyboard shortcut, from anywhere in Parley.",
                           keywords: "shortcut hotkey keyboard") {
                    Text(RecordingCommands.shortcutLabel)
                        .font(Theme.Typography.controlLabel)
                        .padding(.horizontal, Theme.Spacing.small)
                        .frame(height: 24)
                        .background(Theme.Radius.rect(Theme.Radius.chip).fill(Theme.Palette.selection))
                }
            }
        }
    }

    // MARK: Call detection

    private var detectionPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Detection") {
                SettingRow("Detect calls automatically",
                           description: "Watches which apps hold the microphone to spot a call.",
                           keywords: "teams zoom webex meet") {
                    Toggle("", isOn: $settings.callDetectionEnabled)
                }
                SettingRow("Auto-record when a known app starts a call",
                           description: "When off, a notification with a Start button appears instead.") {
                    Toggle("", isOn: $settings.autoRecordEnabled)
                        .disabled(!settings.callDetectionEnabled)
                }
                SettingRow("Suggest meeting title and attendees",
                           description: "Reads the meeting window via Accessibility. In-call people are added automatically; invite-list names (Teams) are not, but go to summaries as invitees with their RSVP.",
                           keywords: "accessibility metadata") {
                    Toggle("", isOn: $settings.metadataDiscoveryEnabled)
                        .disabled(!settings.callDetectionEnabled)
                }
                SettingRow("Call-end grace",
                           description: "How long after the app releases the microphone before the call is treated as ended and recording stops.") {
                    HStack(spacing: Theme.Spacing.small) {
                        Slider(value: $settings.callEndGraceSeconds, in: 5...60, step: 1)
                            .frame(width: 160)
                        Text("\(Int(settings.callEndGraceSeconds))s")
                            .font(Theme.Typography.mono).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                    }
                    .disabled(!settings.callDetectionEnabled)
                }
            }
            SettingsSection("After a meeting") {
                SettingRow("Clear for the next call",
                           description: "Once a recording finishes, reset the title, attendees, filing, notes, and transcript. Any edit cancels it.") {
                    menuPicker($settings.autoClearSeconds) {
                        Text("Off").tag(0.0)
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("2 minutes").tag(120.0)
                    }
                }
                SettingRow("Idle before background work",
                           description: "How long to stay idle after a call before summaries and speaker detection start. A new recording cancels the wait.") {
                    menuPicker($settings.idleDrainSeconds) {
                        Text("Off").tag(0.0)
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("2 minutes").tag(120.0)
                    }
                }
                SettingRow("Quiet hours for held jobs",
                           description: "Held speaker passes and summaries stay parked during the day. From 22:00–07:00 they may run after the idle wait.") {
                    Toggle("", isOn: $settings.quietHoursEnabled)
                }
            }
        }
    }

    // MARK: Transcription

    private var transcriptionPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Speech model") {
                FluidModelRow(models: recording.fluidModels, settings: settings, isRecording: recording.isRecording)
            }
            SettingsSection("Live transcript") {
                SettingRow("Batch mode",
                           description: "Record audio only; transcribe when the call ends. English uses the accurate offline model, other languages Parakeet v3.") {
                    Toggle("", isOn: $settings.batchMode)
                }
                if settings.batchMode {
                    SettingRow("Transcribe", description: "When batch transcription runs.") {
                        PillPicker(selection: Binding(
                            get: { settings.transcriptionTiming },
                            set: { settings.transcriptionTiming = $0 }
                        ), options: [TranscriptionTiming.afterCall, .window]) {
                            Text($0 == .afterCall ? "After each call" : "Daily window")
                        }
                    }
                    if settings.transcriptionTiming == .window {
                        SettingRow("Window",
                                   description: "Outside this window, recordings wait. Overnight windows are allowed, e.g. 22:00 to 07:00.") {
                            HStack(spacing: Theme.Spacing.medium) {
                                Stepper(value: $settings.transcriptionWindowStartHour, in: 0...23) {
                                    Text(String(format: "%02d:00", settings.transcriptionWindowStartHour)).monospacedDigit()
                                }
                                Text("to").foregroundStyle(.secondary)
                                Stepper(value: $settings.transcriptionWindowEndHour, in: 0...23) {
                                    Text(String(format: "%02d:00", settings.transcriptionWindowEndHour)).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                if FluidAsrRouting.usesParakeetUnified(settings: settings) {
                    SettingRow("Latency", description: "Parakeet Unified streams at 2080 ms (English). Latency tiers apply to the multilingual model only.") {
                        EmptyView()
                    }
                } else {
                    SettingRow("Latency", description: "Smaller chunks show text sooner; larger chunks are more accurate.") {
                        menuPicker(Binding(
                            get: { settings.liveStreamingTier },
                            set: { settings.liveStreamingTier = $0 }
                        )) {
                            ForEach(FluidStreamingTier.allCases) { Text($0.label).tag($0) }
                        }
                        .disabled(recording.isRecording)
                    }
                }
                SettingRow("Language",
                           description: "Auto uses the full multilingual model; a Latin-script language loads a smaller, faster one.") {
                    menuPicker($settings.liveStreamingLanguage) {
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
                }
            }
            SettingsSection("English") {
                SettingRow("Parakeet Unified",
                           description: "For English sessions: ~2 s streaming latency and a full-attention offline pass.") {
                    Toggle("", isOn: $settings.useParakeetUnified)
                        .disabled(recording.isRecording)
                }
                SettingRow("Boost attendee names",
                           description: "Adds attendee and title words to the offline re-pass vocabulary (multilingual path). Short, ordinary words are held back.",
                           keywords: "vocabulary") {
                    Toggle("", isOn: $settings.boostAttendeeNames)
                        .disabled(recording.isRecording)
                }
                if settings.boostAttendeeNames {
                    SettingsBlock { vocabularyPreview }
                }
            }
            SettingsSection("Final transcript") {
                SettingRow("Re-transcribe after stopping",
                           description: "A full-context pass over the recording, more accurate than the live chunks. Adds a few seconds at stop.",
                           keywords: "repass accuracy") {
                    Toggle("", isOn: $settings.offlineAsrRepass)
                }
                SettingRow("GPU encoder",
                           description: "Runs the Parakeet v3 encoder on the GPU during the offline pass (~8% faster).") {
                    Toggle("", isOn: $settings.fluidGpuEncoder)
                        .disabled(recording.isRecording)
                }
            }
            SettingsSection("Speakers") {
                SettingRow("Your mic is you on calls",
                           description: "Regular mode only: lines from your microphone are labelled Me and only the call audio is split into speakers. Room mode always splits the single mic into speakers.",
                           keywords: "me microphone diarization room remote") {
                    Toggle("", isOn: $settings.micIsOwnerOnCalls)
                }
                SettingRow("Speaker separation",
                           description: "How readily two voices are treated as the same person. Too high merges speakers; too low splits one person. ~0.6–0.7 suits most calls.",
                           keywords: "diarization threshold") {
                    sliderControl($settings.diarizationThreshold, 0.40...0.80, step: 0.05,
                                  label: String(format: "%.2f", settings.diarizationThreshold))
                        .disabled(recording.isRecording)
                }
                SettingRow("Recognition threshold",
                           description: "How close a voice must be to a saved person before it's auto-named. Higher is stricter.",
                           keywords: "voiceprint identify") {
                    sliderControl($settings.identificationThreshold, 0.40...0.85, step: 0.05,
                                  label: String(format: "%.2f", settings.identificationThreshold))
                }
                SettingRow("Speech before naming",
                           description: "Clean speech needed before a speaker is auto-identified.",
                           keywords: "voiceprint identify") {
                    sliderControl($settings.minSpeechToIdentify, 2...15, step: 1,
                                  label: "\(Int(settings.minSpeechToIdentify)) s")
                }
                SettingsNote("Manage voiceprints — rebuild, delete, and back up — in People.")
            }
            SettingsSection("Memory") {
                SettingRow("Unload the model when idle",
                           description: "Frees memory between calls. It reloads on the next call; capture starts immediately.") {
                    Toggle("", isOn: $settings.idleUnloadEnabled)
                }
                if settings.idleUnloadEnabled {
                    SettingRow("Unload after") {
                        Stepper("\(Int(settings.idleUnloadMinutes)) min",
                                value: $settings.idleUnloadMinutes, in: 1...60, step: 1)
                            .labelsHidden()
                        Text("\(Int(settings.idleUnloadMinutes)) min").monospacedDigit()
                    }
                }
                SettingRow("Reset model cache",
                           description: "If transcription crashes on load, the compiled-model cache may be corrupt. Resetting rebuilds it.") {
                    Button("Reset") {
                        FluidModelManager.clearCompiledCache()
                        Task { _ = await recording.fluidModels.prepare() }
                    }
                    .glassButton()
                    .disabled(recording.isRecording)
                }
            }
        }
    }

    private func sliderControl(_ value: Binding<Double>, _ range: ClosedRange<Double>,
                               step: Double, label: String) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Slider(value: value, in: range, step: step).frame(width: 160)
            Text(label)
                .font(Theme.Typography.mono).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    /// Shows the terms this meeting would boost, and why the rejects were rejected.
    /// The 2026-09-14 corruption was invisible precisely because nothing surfaced
    /// that "Steps", "Next" and "Carlos" had been handed to the recogniser.
    @ViewBuilder
    private var vocabularyPreview: some View {
        let candidates = FluidVocabularyBuilder.candidates(
            attendees: recording.meeting.attendees,
            meetingTitle: recording.meeting.meetingTitle,
            glossary: TerminologyStore()
                .glossary(forScope: TerminologyStore.customerScope(fromFiling: recording.meeting.destinationPath))
                .map(\.canonical),
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
        }
    }

    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Summaries

    private var summariesPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("You") {
                SettingRow("Your name",
                           description: "Who \"Me\" is in transcripts ({{me}}).",
                           keywords: "owner me name") {
                    TextField("Full name", text: $settings.ownerName)
                        .textFieldStyle(.parley).frame(width: 240)
                }
                SettingRow("Your company",
                           description: "Canonical spelling ({{my_company}}). Your colleagues are always sent as contacts.",
                           keywords: "owner company my_company") {
                    TextField("Company", text: $settings.ownerCompany)
                        .textFieldStyle(.parley).frame(width: 240)
                }
            }
            SettingsSection("Behaviour") {
                SettingRow("Pipeline",
                           description: "v1 runs one backend. v2 runs a writer, then a checker that proposes edits for markup review.") {
                    menuPicker($settings.summaryPipelineRaw) {
                        ForEach(SummaryPipeline.allCases) { p in Text(p.label).tag(p.rawValue) }
                    }
                }
                SettingRow("Auto-summarize after speakers are assigned",
                           description: "When off, summaries run only when you press Summarize on a meeting.") {
                    Toggle("", isOn: $settings.autoRunClaude)
                }
                SettingRow("Ask before summarizing a batch",
                           description: "When several notes become ready at once, ask once rather than running them all.") {
                    Stepper(value: $settings.summaryBulkThreshold, in: 2...50) {
                        Text("\(settings.summaryBulkThreshold) notes").monospacedDigit()
                    }
                }
                SettingRow("Auto-resume after a usage limit",
                           description: "Resume the paused queue when the CLI's usage limit lifts. Off keeps it paused until you press Resume.") {
                    Toggle("", isOn: $settings.summaryAutoResumeAfterLimit)
                }
                SettingRow("Delete audio after filing",
                           description: "The filed note includes the transcript, so the audio is redundant. Frees significant disk.") {
                    Toggle("", isOn: $settings.deleteAudioAfterFiling)
                }
            }

            SettingsSection("Provider") {
                if settings.summaryPipeline == .v2 {
                    SettingRow("Writer", description: settings.summaryWriterBackend.blurb, keywords: "model backend") {
                        menuPicker($settings.summaryWriterBackendRaw) {
                            ForEach(SummaryBackend.writerBackends) { b in Text(b.displayName).tag(b.rawValue) }
                        }
                    }
                    SettingRow("Checker", description: settings.summaryCheckerBackend.blurb, keywords: "model backend") {
                        menuPicker($settings.summaryCheckerBackendRaw) {
                            ForEach(SummaryBackend.checkerBackends) { b in Text(b.displayName).tag(b.rawValue) }
                        }
                    }
                } else {
                    SettingRow("Summarize with", description: settings.summaryBackend.blurb, keywords: "model backend") {
                        menuPicker($settings.summaryBackendRaw) {
                            ForEach(SummaryBackend.allCases) { b in Text(b.displayName).tag(b.rawValue) }
                        }
                    }
                }
            }

            SettingsSection("Claude") {
                SettingsBlock(keywords: "claude cli connection status") { ClaudeConnectionView() }
                SettingRow("Model", description: "Used for summaries and meeting notes.", keywords: "claude") {
                    TextField("sonnet", text: $settings.claudeModel)
                        .textFieldStyle(.parley).font(Theme.Typography.mono).frame(width: 200)
                }
                SettingRow("CLI path", description: "Runs `claude -p` (raw prompt, no tools).", keywords: "claude binary") {
                    pathField("~/.local/bin/claude", $settings.claudeBinaryPath)
                }
            }

            if settings.summaryPipeline == .v2
                || (settings.summaryPipeline == .classic && settings.summaryBackend.isCursorAgent) {
                SettingsSection("Cursor Agent") {
                    SettingsBlock(keywords: "cursor cli connection status") { CursorConnectionView() }
                    if settings.summaryPipeline == .classic {
                        SettingRow("Model id", keywords: "cursor") {
                            Text(settings.summaryBackend.rawValue)
                                .font(Theme.Typography.mono).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    SettingRow("CLI path",
                               description: "Runs `cursor agent -p --mode ask` with your Cursor subscription (read-only).",
                               keywords: "cursor binary") {
                        pathField("/usr/local/bin/cursor", $settings.cursorBinaryPath)
                    }
                }
            }

            if settings.summaryPipeline == .classic && settings.summaryBackend == .grok {
                SettingsSection("Grok") {
                    SettingsBlock(keywords: "grok cli connection status") { GrokConnectionView() }
                    SettingRow("Model", keywords: "grok") {
                        TextField("grok-4.6", text: $settings.grokModel)
                            .textFieldStyle(.parley).font(Theme.Typography.mono).frame(width: 200)
                    }
                    SettingRow("CLI path", description: "Runs `grok -p` (raw prompt, JSON on stdout).", keywords: "grok binary") {
                        pathField("~/.grok/bin/grok", $settings.grokBinaryPath)
                    }
                }
            }

            SettingsSection("Attachments") {
                SettingRow("Include in summaries", description: settings.attachmentUnderstanding.blurb,
                           keywords: "screenshots images vision") {
                    menuPicker($settings.attachmentUnderstandingRaw) {
                        ForEach(AttachmentUnderstanding.allCases) { m in Text(m.label).tag(m.rawValue) }
                    }
                }
                if settings.attachmentUnderstanding == .vision {
                    SettingRow("Vision backend",
                               description: "A read-only Cursor agent pass describes images before summarizing.") {
                        menuPicker($settings.attachmentVisionBackendRaw) {
                            ForEach(SummaryBackend.allCases.filter(\.isCursorAgent)) { b in
                                Text(b.displayName).tag(b.rawValue)
                            }
                        }
                    }
                }
            }

            SettingsSection("Prompts") {
                SettingRow("Summary prompt", description: "The instructions every summarizer follows.",
                           keywords: "template") {
                    editButton(.summaryPrompt)
                }
                if settings.summaryPipeline == .v2 {
                    SettingRow("Checker instructions", description: "Rules the checker follows when reviewing a draft.",
                               keywords: "template") {
                        editButton(.checkerInstructions)
                    }
                }
                SettingRow("Meeting notes prompt", description: "Used when Claude generates meeting notes.",
                           keywords: "template") {
                    editButton(.notesPrompt)
                }
            }

            SettingsSection("Ground truth check") {
                SettingRow("Example", description: SummaryGroundTruth.rationale) {
                    Text(SummaryGroundTruth.displayTitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 240, alignment: .trailing)
                }
                SettingRow(settings.summaryPipeline == .v2 ? "Run with the writer" : "Run with the summarizer",
                           description: "Re-runs one approved meeting and scores fact recall against the filed note. Doesn't file a note.",
                           keywords: "evaluate benchmark recall") {
                    Button(groundTruthEval.phase == .running ? "Running…" : "Run check") {
                        let backend = settings.summaryPipeline == .v2
                            ? settings.summaryWriterBackend
                            : settings.summaryBackend
                        groundTruthEval.run(backend: backend, settings: settings)
                    }
                    .glassButton()
                    .disabled(groundTruthEval.phase == .running)
                }
                if case .failed(let reason) = groundTruthEval.phase {
                    SettingsBlock { helpText(reason) }
                }
                if let report = groundTruthEval.report {
                    let recall = Int((report.score.recall * 100).rounded())
                    SettingRow(report.backendName,
                               description: [SummaryMetricsFormat.compactLine(metrics: report.metrics)?.text,
                                             report.score.missedPreviews.isEmpty ? nil
                                                : "Missed: " + report.score.missedPreviews.prefix(4).joined(separator: " · ")]
                                   .compactMap { $0 }.joined(separator: "\n")) {
                        Text("\(recall)% recall (\(report.score.matched)/\(report.score.total))")
                            .font(Theme.Typography.body).monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: Contacts and filing

    private var contactsPage: some View {
        let rec = vault.reconcileCustomers()
        return VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Filing") {
                SettingRow("Filing locations",
                           description: "Scan roots whose subfolders become filing destinations: \(settings.scanRoots.joined(separator: ", ")).",
                           keywords: "scan roots folders destinations") {
                    editButton(.scanRoots)
                }
                SettingRow("Contacts file", description: "Your rolodex, inside the vault.", keywords: "rolodex") {
                    TextField("Rolodex.md", text: $settings.contactsFileName)
                        .textFieldStyle(.parley).frame(width: 200)
                }
            }
            SettingsSection("Knowledge") {
                SettingRow("Knowledge database",
                           description: knowledgeStatus ?? "Move contacts and knowledge between machines as JSON.",
                           keywords: "export import json") {
                    HStack(spacing: Theme.Spacing.small) {
                        Button("Export…") { exportKnowledgeJSON() }.glassButton()
                        Button("Import…") { importKnowledgeJSON() }.glassButton()
                    }
                }
                SettingRow("Rolodex",
                           description: "Sync the knowledge database with \(settings.contactsFileName).",
                           keywords: "contacts import export") {
                    HStack(spacing: Theme.Spacing.small) {
                        Button("Import") { importRolodexToDB() }.glassButton()
                        Button("Write file") { exportDBToRolodex() }.glassButton()
                    }
                }
                SettingRow("Glossary",
                           description: "Canonical spellings of companies and terms, with the ways they get misheard.",
                           keywords: "terminology aliases spelling vocabulary") {
                    Button("Edit…") {
                        glossaryDraft = TerminologyStore().globalGlossaryText()
                        editing = .glossary
                    }
                    .glassButton()
                }
            }
            SettingsSection("Customer reconciliation") {
                SettingRow("Customers",
                           description: "\(vault.customerFolderNames.count) folders ⟷ \(vault.fileCustomers.count) listed in \(settings.contactsFileName).",
                           keywords: "reconcile folders") {
                    Button("Refresh") { vault.refresh() }.glassButton()
                }
                SettingsBlock(keywords: "reconcile customers") {
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
                                        .buttonStyle(.chip)
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
                }
            }
        }
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

    // MARK: Storage (manual recordings management)

    private var storagePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Recordings") {
                SettingRow("Recorded audio",
                           description: "\(recordings.sessions.count) sessions · \(storageTotalLabel). Raw audio is kept for re-transcribing; deleting a session never touches its transcript or note.",
                           keywords: "disk space size") {
                    HStack(spacing: Theme.Spacing.small) {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([AppPaths.recordingsDirectory])
                        }
                        .glassButton()
                        Button("Refresh") { recordings.refresh() }.glassButton()
                    }
                }
            }
            SettingsSection("Cleanup") {
                SettingRow("Delete recordings older than",
                           description: "Moves old session audio to the Trash.",
                           keywords: "purge free space") {
                    HStack(spacing: Theme.Spacing.small) {
                        menuPicker($purgeDays) {
                            ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                        }
                        Button("Delete", role: .destructive) { confirmPurge() }.glassButton()
                    }
                }
                let orphans = orphanedSessions
                if !orphans.isEmpty {
                    let orphanBytes = orphans.compactMap(\.sizeBytes).reduce(Int64(0), +)
                    let orphanSuffix = orphans.contains { $0.sizeBytes == nil } ? "+" : ""
                    SettingRow("Orphaned audio",
                               description: "\(orphans.count) sessions · \(byteText(orphanBytes))\(orphanSuffix) with no transcript in History.",
                               keywords: "orphan") {
                        Button("Delete", role: .destructive) {
                            storageStatus = nil; pendingBulkDelete = orphans
                        }
                        .glassButton()
                    }
                }
                if !selectedSessions.isEmpty {
                    SettingRow("Selected sessions", description: "\(selectedSessions.count) chosen below.") {
                        Button("Delete selected", role: .destructive) { confirmDeleteSelected() }.glassButton()
                    }
                }
                if let storageStatus {
                    SettingsBlock { helpText(storageStatus) }
                }
            }
            SettingsSection("Sessions") {
                SettingsBlock(keywords: "sessions recordings list") {
                    if recordings.sessions.isEmpty {
                        helpText("No recordings yet. Session folders appear here after you record a meeting.")
                    } else {
                        ForEach(recordings.sessions) { folder in
                            sessionRow(folder)
                        }
                    }
                }
            }
        }
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

    // MARK: Permissions

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Access") {
                permissionRow("Microphone", detail: "Records your side of the call.",
                              ok: !recording.micDenied, fix: PermissionManager.openMicrophoneSettings)
                permissionRow("System audio", detail: "Records the far side and powers call detection.",
                              ok: recording.systemAudioAvailable ?? true,
                              unknown: recording.systemAudioAvailable == nil,
                              fix: PermissionManager.openPrivacySettings)
                permissionRow("Accessibility", detail: "Only for meeting title and attendee suggestions; recording works without it.",
                              ok: axTrusted, fix: PermissionManager.openAccessibilitySettings)
            }
        }
        .onAppear { axTrusted = PermissionManager.accessibilityAuthorized() }
    }

    /// A granted/denied status row with a one-tap "Open Settings" when denied.
    private func permissionRow(_ label: String, detail: String, ok: Bool, unknown: Bool = false,
                               fix: @escaping () -> Void) -> some View {
        SettingRow(label, description: detail, keywords: "permission privacy") {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: unknown ? "questionmark.circle" : (ok ? "checkmark.circle.fill" : "xmark.circle.fill"))
                    .foregroundStyle(unknown ? Color.secondary
                                     : (ok ? Theme.Severity.success.color : Theme.Severity.danger.color))
                Text(unknown ? "Checking…" : (ok ? "Allowed" : "Not allowed"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if !ok && !unknown {
                    Button("Open Settings", action: fix).glassButton()
                }
            }
        }
    }

    // MARK: Developer

    private var developerPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Logs") {
                SettingRow("Diagnostic log", description: AppLog.fileURL.path) {
                    HStack(spacing: Theme.Spacing.small) {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
                        }
                        .glassButton()
                        Button("Clear") { AppLog.clear() }.glassButton()
                    }
                }
                SettingRow("Verbose detection logging",
                           description: "Log every microphone and window check call detection makes.") {
                    Toggle("", isOn: $settings.verboseDetectionLogging)
                }
            }
            SettingsSection("Call detection") {
                SettingRow("Known conferencing apps",
                           description: "Bundle IDs watched for calls. Known apps can auto-record; others only notify.",
                           keywords: "bundle teams zoom") {
                    editButton(.conferencingApps)
                }
                SettingRow("Live detector status",
                           description: detector.capturing.isEmpty
                               ? "No apps capturing the microphone right now."
                               : detector.capturing.map { $0.bundleID ?? "pid \($0.pid)" }.joined(separator: ", ")) {
                    if let call = detector.activeCall {
                        Label("Active: \(call.displayName)", systemImage: "phone.connection.fill")
                            .foregroundStyle(Theme.Severity.success.color)
                            .font(Theme.Typography.caption)
                    } else {
                        Text("No active call")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
        }
    }
}

// MARK: - Search results grouping

/// Match counts per page, collected while searching (every page renders at once).
private struct PageMatchCountsKey: PreferenceKey {
    static let defaultValue: [SettingsView.Page: Int] = [:]
    static func reduce(value: inout [SettingsView.Page: Int], nextValue: () -> [SettingsView.Page: Int]) {
        value.merge(nextValue(), uniquingKeysWith: +)
    }
}

/// One page's matching rows in the search results, under a "Page" heading that hides
/// when nothing on the page matches.
private struct SearchPageGroup<Content: View>: View {
    let page: SettingsView.Page
    let query: String
    @ViewBuilder let content: () -> Content
    @State private var count = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if count > 0 {
                Label(page.title, systemImage: page.icon)
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.top, Theme.Spacing.xLarge)
            }
            content()
                .environment(\.settingsContext, page.title)
                .onPreferenceChange(SettingsMatchCountKey.self) { count = $0 }
        }
        .preference(key: PageMatchCountsKey.self, value: [page: count])
    }
}

// MARK: - Provider status

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
                .glassButton()
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

/// The on-device speech model as one settings row: name and storage on the left,
/// download / status on the right.
private struct FluidModelRow: View {
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
        SettingRow(modelLabel,
                   description: "On-device transcription, diarization, and speaker ID via FluidAudio. Stored in \(FluidModelManager.modelsDirectory.path).",
                   keywords: "parakeet fluidaudio download asr") {
            statusControl
        }
        .onAppear { models.refreshPresence() }
    }

    @ViewBuilder private var statusControl: some View {
        switch models.status {
        case .unknown, .notDownloaded:
            Button("Download") { models.download() }.glassButton().disabled(isRecording)
        case .downloading:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView().controlSize(.small)
                Text("Downloading…").font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
        case .downloaded:
            Label("Active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.Severity.success.color)
                .font(Theme.Typography.caption)
        case .failed(let msg):
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxSmall) {
                Button("Retry") { models.download() }.glassButton().disabled(isRecording)
                Text(msg)
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(Theme.Severity.danger.color).lineLimit(2)
            }
        }
    }
}

/// Makes the Settings window freely resizable, hides its title text (the sidebar and
/// page titles carry the context), and clamps max size to the screen.
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
            window.titleVisibility = .hidden
            // Let the sidebar and page run up under the (transparent) title bar, as in
            // the Claude app, instead of a separate white strip above them.
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.minSize = NSSize(width: 760, height: 520)
        }
        window.maxSize = NSSize(width: maxSize.width, height: maxSize.height)
    }

    final class Coordinator {
        var didConfigure = false
    }
}
