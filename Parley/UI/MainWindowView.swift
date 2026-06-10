import SwiftUI
import AppKit

/// The app's main window: a sidebar that switches between the live "Record"
/// experience and the "History" browser, each shown in the detail pane.
struct MainWindowView: View {
    @EnvironmentObject private var recording: RecordingController
    @ObservedObject private var store = RecordingController.shared.store
    @ObservedObject private var summaryService = RecordingController.shared.summaryService
    @ObservedObject private var offline = RecordingController.shared.offlineService
    @State private var selection: SidebarSection? = .record
    @State private var showingRecovery = false
    @AppStorage("parley.sidebarCollapsed") private var sidebarCollapsed = false

    /// Badge on the History nav item: notes needing the user (unassigned speakers,
    /// summaries to review, failures) — matching the "Needs you" tab.
    private var historyBadge: Int {
        store.items.filter {
            PipelineStage.derive(item: $0, offline: offline, summary: summaryService).needsYou
        }.count
    }

    enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
        case record = "Record", history = "History"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .record: return "record.circle"
            case .history: return "clock.arrow.circlepath"
            }
        }
    }

    var body: some View {
        // A plain sidebar + detail (NOT NavigationSplitView): in this fixed menu-bar
        // utility window, NavigationSplitView's adaptive column-collapsing and
        // integrated title bar misrendered on narrow built-in displays (blank band,
        // window title bleeding over the content). A fixed HStack renders identically
        // at every size.
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch selection ?? .record {
                case .record:
                    RecordDetailView()
                case .history:
                    HistoryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 560)
        // Sidebar collapse toggle lives in the toolbar (in the title bar, by the
        // traffic lights) — the native placement, so it isn't floating in the column.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(Theme.Motion.quick) { sidebarCollapsed.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
            }
        }
        .background(WindowConfigurator())   // hide the "Parley" title text
        .environmentObject(recording.store)
        // Crash recovery: offer any interrupted sessions on launch; auto-dismiss
        // once they're all handled (resumed / recovered / discarded).
        .sheet(isPresented: $showingRecovery) {
            RecoveryView { showingRecovery = false }
                .environmentObject(recording)
        }
        // Assign-speakers review for a History "Detect speakers" run. Hosted here, at
        // the always-mounted window root, so it survives switching tabs/notes — the
        // History view used to own this sheet and tore it (and the only way back to
        // the review) down on navigation, forcing a full re-run of the offline pass.
        .sheet(isPresented: Binding(
            get: { recording.autoPresentSpeakerReview && recording.pendingSpeakerReview != nil },
            set: { if !$0 { recording.autoPresentSpeakerReview = false } })) {
            if let review = recording.pendingSpeakerReview {
                AssignSpeakersView(review: review)
            }
        }
        .onChange(of: recording.pendingRecoveries.isEmpty) {
            showingRecovery = !recording.pendingRecoveries.isEmpty
        }
        .onAppear {
            if !recording.pendingRecoveries.isEmpty { showingRecovery = true }
        }
    }

    /// Navigation sidebar (Record / History) with Settings pinned at the bottom.
    /// Collapses to a thin icon-only rail.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            ForEach(SidebarSection.allCases) { section in
                navButton(section)
            }

            Spacer()

            // Settings pinned to the bottom-left (opens the Settings window).
            SettingsLink {
                navRow(symbol: "gearshape", title: "Settings")
            }
            .buttonStyle(.row())
            .foregroundStyle(.primary)
            .help(sidebarCollapsed ? "Settings" : "")
        }
        .padding(Theme.Spacing.small)
        .frame(width: sidebarCollapsed ? 52 : 170)
        .frame(maxHeight: .infinity)
        .chromeSurface()
    }

    private func navButton(_ section: SidebarSection) -> some View {
        let isSelected = (selection ?? .record) == section
        return Button {
            selection = section
        } label: {
            navRow(symbol: section.symbol, title: section.rawValue,
                   badge: section == .history ? historyBadge : 0)
        }
        .buttonStyle(.row(selected: isSelected))
        .foregroundStyle(isSelected ? Theme.Palette.accent : .primary)
        .animation(Theme.Motion.quick, value: isSelected)
        .help(sidebarCollapsed ? section.rawValue : "")
    }

    /// A sidebar row's content: icon-only when collapsed, icon + label when expanded.
    /// An optional badge count (summaries in progress / ready to review) is shown on
    /// the trailing edge, or as a dot when collapsed. Selection / hover styling is
    /// provided by `RowButtonStyle` (`.buttonStyle(.row(selected:))`).
    @ViewBuilder private func navRow(symbol: String, title: String, badge: Int = 0) -> some View {
        Group {
            if sidebarCollapsed {
                Image(systemName: symbol)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Circle().fill(Theme.Palette.accent).frame(width: 7, height: 7).offset(x: 2, y: -1)
                        }
                    }
            } else {
                // Label centred across the row; icon pinned to the leading edge and
                // the badge to the trailing edge (overlays, so they don't shift the
                // centred text).
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .overlay(alignment: .leading) { Image(systemName: symbol) }
                    .overlay(alignment: .trailing) {
                        if badge > 0 { CountBadge(count: badge) }
                    }
            }
        }
        .font(Theme.Typography.body)
    }
}

/// Hides the window's title text (so no "Parley" sits in the title bar) while keeping
/// the standard, content-insetting title bar — so the columns align cleanly beneath it.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }
    private func configure(_ window: NSWindow?) {
        window?.titleVisibility = .hidden
    }
}

/// The live recording experience: recording controls + session metadata on top,
/// the live transcription stream filling the body, and a result/footer bar.
struct RecordDetailView: View {
    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var vault: VaultDirectory
    /// Observed so the offline-queue strip republishes as jobs come and go.
    @ObservedObject private var offline = RecordingController.shared.offlineService
    @State private var apps: [CapturableApp] = []
    @State private var mode: WindowMode = .live
    @State private var pendingPerson: PendingPerson?
    @State private var showSpeakerReview = false
    /// Distinguishes the user's typing in the Title field from programmatic
    /// auto-fill (discovered titles): only focused changes count as user edits.
    @FocusState private var titleFocused: Bool
    @AppStorage("parley.axBannerDismissed") private var axBannerDismissed = false
    /// User-resizable inspector width (drag the divider). View-local presentation
    /// state — deliberately not in AppSettings. Default 340 (a touch roomier than
    /// the old fixed 300); double-clicking the divider resets to it.
    @AppStorage("parley.inspectorWidth") private var inspectorWidth: Double = 340
    @State private var dragBaseWidth: Double?
    private static let inspectorWidthRange: ClosedRange<Double> = 280...440
    private static let defaultInspectorWidth: Double = 340

    enum WindowMode: String, CaseIterable, Identifiable {
        case live = "Live", preview = "Preview"
        var id: String { rawValue }
    }

    /// A new attendee name awaiting rich-contact entry.
    struct PendingPerson: Identifiable {
        let id = UUID()
        let name: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                inspectorDivider
                inspector
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            offlinePassBar
                // Scope the offline-queue animation to this bar only. Previously it sat
                // on the whole VStack, so the footer's text swap (word count →
                // "Transcript saved") rode the same transaction and crossfaded the two
                // on top of each other. Confining it here keeps the footer swap instant.
                .animation(Theme.Motion.gentle, value: offlineActiveCount)
            footer
        }
        .frame(minWidth: 480, minHeight: 520)
        .onAppear {
            apps = ProcessLister.capturableApps()
            recording.launchWarmup()   // warm the model + surface both permission prompts up front
        }
        // Auto-switch to the rendered note when a recording finishes writing it.
        .onChange(of: recording.lastTranscriptURL) {
            if recording.lastTranscriptURL != nil { mode = .preview }
        }
        // At-stop "Assign speakers" review (FluidAudio).
        // Speaker review is opt-in (a footer button), not an auto-popup after every call.
        .sheet(isPresented: $showSpeakerReview) {
            if let review = recording.pendingSpeakerReview {
                AssignSpeakersView(review: review)
            }
        }
        .sheet(item: $pendingPerson) { pending in
            NewPersonSheet(
                initialName: pending.name,
                defaultCompany: currentCustomerLeaf,
                onAdd: { name, title, company, link in
                    vault.addPerson(name: name, title: title, company: company, linkedin: link)
                    var names = attendeesBinding.wrappedValue
                    if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                        names.append(name)
                        attendeesBinding.wrappedValue = names
                    }
                    pendingPerson = nil
                },
                onCancel: { pendingPerson = nil }
            )
        }
    }

    /// The customer/leaf of the current filing path, used to prefill Company.
    private var currentCustomerLeaf: String {
        recording.destinationPath.split(separator: "/").last.map(String.init) ?? ""
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .live:
            LiveTranscriptView(
                segments: recording.segments,
                isRecording: recording.isRecording,
                people: vault.people,
                attendees: TranscriptWriter.splitAttendees(recording.attendees),
                onNameSpeaker: settings.transcriptionEngine == .fluidAudio
                    ? { id, name in recording.nameSpeaker(id, as: name) } : nil,
                liveDisabled: settings.transcriptionEngine == .whisperKit && !settings.liveTranscriptEnabled
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .preview:
            VStack(spacing: 0) {
                NotesActionBar(
                    generator: recording.notes,
                    destination: recording.destinationPath,
                    attendees: recording.attendees,
                    model: settings.claudeModel,
                    onGenerate: {
                        recording.notes.generate(
                            transcriptURL: recording.lastTranscriptURL,
                            destination: recording.destinationPath,
                            attendees: recording.attendees,
                            settings: settings
                        )
                    }
                )
                Divider()
                TranscriptPreviewView(url: recording.lastTranscriptURL, reloadToken: recording.transcriptRevision)
            }
        }
    }

    // MARK: Inspector rail

    /// The right-hand control rail: record button, status + model, then the meeting
    /// metadata and audio controls. The transcript is the main pane to its left, so
    /// setup recedes and the transcript stays the star.
    private var inspector: some View {
        // A VStack (not a ScrollView): the controls + metadata keep their natural
        // size and the Notes editor fills the remaining height. (A ScrollView would
        // give every child only its ideal height, so Notes could never grow.)
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            recordButton
            timerView
            audioControls

            statusRow

            if let load = modelLoadingInfo {
                modelLoadingBar(stage: load.stage, fraction: load.fraction)
            }

            advisoryRows

            if case .error(let message) = recording.state {
                StatusBanner(.danger, message,
                             actionLabel: message.localizedCaseInsensitiveContains("microphone") ? "Open Settings" : nil,
                             action: message.localizedCaseInsensitiveContains("microphone") ? PermissionManager.openMicrophoneSettings : nil)
            }

            Divider().padding(.vertical, Theme.Spacing.xSmall)

            metadataFields   // editable during recording too (e.g. a mid-call joiner)
            notesField       // fills the rest of the rail
        }
        .padding(Theme.Spacing.large)
        .frame(width: inspectorWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .chromeSurface()
    }

    /// The divider between the transcript and the inspector, doubled as a resize
    /// handle: a slim transparent grab area straddles the 1pt line, shows the
    /// horizontal-resize cursor on hover, and drags the rail width within range.
    /// Dragging left (negative translation) widens the rail; double-click resets.
    private var inspectorDivider: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragBaseWidth == nil { dragBaseWidth = inspectorWidth }
                                let proposed = dragBaseWidth! - value.translation.width
                                inspectorWidth = min(max(proposed, Self.inspectorWidthRange.lowerBound),
                                                     Self.inspectorWidthRange.upperBound)
                            }
                            .onEnded { _ in dragBaseWidth = nil }
                    )
                    .onTapGesture(count: 2) { inspectorWidth = Self.defaultInspectorWidth }
            }
    }

    /// Status dot + text on the left, the active model on the right.
    private var statusRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            statusBadge
            Spacer()
            Text(audioModelLabel)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Persistent warnings the user should fix before recording: denied
    /// permissions and a memory guard for heavy model loads. Shown whenever the
    /// condition holds (not only after a failed Start), each with a one-tap fix.
    @ViewBuilder private var advisoryRows: some View {
        if recording.micDenied {
            StatusBanner(.danger,
                         "Microphone access is off — recordings will capture no voice.",
                         symbol: "mic.slash.fill",
                         actionLabel: "Open Settings", action: PermissionManager.openMicrophoneSettings)
        }
        if recording.systemAudioAvailable == false {
            StatusBanner(.danger,
                         "System-audio recording is off — the Remote track and call detection won't work.",
                         symbol: "speaker.slash.fill",
                         actionLabel: "Open Settings", action: PermissionManager.openPrivacySettings)
        }
        if let advisory = models.memoryAdvisory {
            StatusBanner(.warning, advisory, symbol: "memorychip")
        }
        // One-time nudge: meeting-detail suggestions are on but can't work
        // without the Accessibility permission (recording is unaffected).
        if settings.metadataDiscoveryEnabled, !axBannerDismissed,
           !PermissionManager.accessibilityAuthorized() {
            HStack(alignment: .top, spacing: Theme.Spacing.xSmall) {
                StatusBanner(.info,
                             "Grant Accessibility to auto-suggest meeting titles & attendees. Already granted? Quit and reopen Parley.",
                             symbol: "person.text.rectangle",
                             actionLabel: "Open Settings", action: {
                                 // Registers the app in the Accessibility list
                                 // (so the toggle exists) and deep-links to it.
                                 PermissionManager.promptForAccessibility()
                                 PermissionManager.openAccessibilitySettings()
                             })
                Button { axBannerDismissed = true } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Don't show again")
            }
        }
    }

    /// The model label shown beside the "Audio" disclosure. For WhisperKit, the live
    /// transcript is produced by the *live* model when it's enabled; only the final
    /// (at-stop) model runs in offline-only mode. FluidAudio uses a single model.
    private var audioModelLabel: String {
        if settings.transcriptionEngine == .fluidAudio { return "FluidAudio · Parakeet v3" }
        return settings.liveTranscriptEnabled ? settings.liveModel.label : settings.model.label
    }

    /// Audio capture controls, always visible directly under the record button:
    /// the capture-mode picker (full width) and the per-app picker when relevant.
    private var audioControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            capturePicker
            if settings.captureMode == .perApp { appPicker }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordButton: some View {
        Button {
            Task {
                if recording.isRecording { recording.stop() }
                else { mode = .live; await recording.start() }
            }
        } label: {
            Label(recording.isRecording ? "Stop" : "Start",
                  systemImage: recording.isRecording ? "stop.fill" : "record.circle")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .glassProminentButton()
        .tint(recording.isRecording ? .red : .green)
        .disabled(recording.state == .preparing || recording.state == .stopping)
    }

    /// Live elapsed timer, ticking once a second while recording.
    @ViewBuilder private var timerView: some View {
        if let started = recording.recordingStarted {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text(Self.elapsed(from: started, to: context.date))
                    .font(Theme.Typography.monoLarge)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: Theme.Spacing.small) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .animation(Theme.Motion.quick, value: statusColor)
            Text(statusText).font(Theme.Typography.secondary).foregroundStyle(.secondary)
        }
    }

    private var capturePicker: some View {
        Picker("Other audio", selection: Binding(
            get: { settings.captureMode }, set: { settings.captureMode = $0 }
        )) {
            ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .disabled(recording.isRecording)
    }

    private var appPicker: some View {
        HStack(spacing: 4) {
            Picker("App", selection: Binding(
                get: { recording.selectedAppPID }, set: { recording.selectedAppPID = $0 }
            )) {
                Text("Choose…").tag(pid_t?.none)
                ForEach(apps) { Text($0.name).tag(pid_t?.some($0.id)) }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            .disabled(recording.isRecording)
            Button { apps = ProcessLister.capturableApps() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh app list")
        }
    }

    private var metadataFields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            railField("Title") {
                TextField("Meeting title", text: $recording.meetingTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onChange(of: recording.meetingTitle) {
                        if titleFocused { recording.userEditedTitle() }
                        recording.scheduleMetadataSync()
                        recording.userInteracted()
                    }
                // Discovery found a (different) title after the user edited the
                // field — offer it without overwriting.
                if let discovered = recording.discoveredTitle,
                   discovered != recording.meetingTitle {
                    Button {
                        recording.acceptDiscoveredTitle()
                    } label: {
                        HStack(spacing: Theme.Spacing.xSmall) {
                            Image(systemName: "sparkles")
                            Text("Use “\(discovered)”")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.chip)
                    .help("Title discovered from the meeting window")
                }
            }
            railField("Filing") {
                DestinationField(path: $recording.destinationPath,
                                 destinations: vault.destinations,
                                 firstRoot: settings.scanRoots.first ?? "Internal")
                    .onChange(of: recording.destinationPath) {
                        recording.scheduleMetadataSync()
                        recording.userInteracted()
                    }
            }
            railField("Attendees") {
                TokenField(tokens: attendeesBinding,
                           completions: vault.people,
                           placeholder: "Add attendees",
                           onCreateNew: { name in pendingPerson = PendingPerson(name: name) })
                    .onChange(of: recording.attendees) {
                        recording.scheduleMetadataSync()
                        recording.userInteracted()
                    }
                SuggestionChips(recording: recording)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Notes editor — the flexible last element of the inspector, so it grows to
    /// fill the rail's remaining height (and grows further as the window does). The
    /// `TextEditor` scrolls its own content internally once notes exceed the frame.
    private var notesField: some View {
        railField("Notes") {
            TextEditor(text: $recording.manualNotes)
                .font(Theme.Typography.body)
                .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                .overlay(Theme.Radius.rect(Theme.Radius.small).strokeBorder(.quaternary))
                .onChange(of: recording.manualNotes) { recording.userInteracted() }
        }
        .frame(maxHeight: .infinity)
    }

    /// A stacked label-over-control field for the inspector rail.
    @ViewBuilder private func railField<Content: View>(_ label: String,
                                                       @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text(label).font(Theme.Typography.fieldLabel).foregroundStyle(.secondary)
            content()
        }
    }

    /// Bridges the comma-joined `attendees` string to the token field's array.
    private var attendeesBinding: Binding<[String]> {
        Binding(
            get: {
                recording.attendees
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            },
            set: { recording.attendees = $0.joined(separator: ", ") }
        )
    }

    /// Stepping progress bar shown while the model loads into memory. The bar spans
    /// the full rail width with the stage label beneath it.
    private func modelLoadingBar(stage: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
            Text(stage)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Current model load/download progress, if any (drives `modelLoadingBar`).
    private var modelLoadingInfo: (stage: String, fraction: Double)? {
        switch models.status {
        case .downloading(let f): return ("Downloading… \(Int(f * 100))%", f)
        case .loading(let stage, let fraction): return (stage, fraction)
        case .idle, .ready, .failed: return nil
        }
    }

    // MARK: Footer

    /// Count of offline jobs queued or running in the background (across all sessions).
    private var offlineActiveCount: Int {
        offline.jobs.values.filter { $0 == .queued || $0 == .running }.count
    }

    /// A strip under the transcript showing the post-stop pipeline as a segmented
    /// stage bar: the running job's live per-stage progress, or a queued (dim) bar
    /// while a job waits for idle, plus how many more recordings are behind it.
    @ViewBuilder private var offlinePassBar: some View {
        if offlineActiveCount > 0 {
            let running = offline.runningProgress.flatMap {
                StageBarModel.fuse(offlineState: .running, offlineProgress: $0,
                                   summaryRunning: false, summaryQueued: false,
                                   summaryFailed: nil, summaryPaused: false, summaryActivity: nil)
            }
            let model = running ?? StageBarModel.fuse(offlineState: .queued, offlineProgress: nil,
                                                      summaryRunning: false, summaryQueued: false,
                                                      summaryFailed: nil, summaryPaused: false,
                                                      summaryActivity: nil)
            if let model {
                HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                    SegmentedStageBar(segments: model.segments,
                                      statusLabel: model.statusLabel, sublabel: model.sublabel)
                    if running != nil, offline.queuedCount > 0 {
                        Text("+\(offline.queuedCount) queued")
                            .font(Theme.Typography.captionSecondary)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.small)
                .background(.quaternary.opacity(Theme.Opacity.surface))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// Live word count across all transcript segments (shown until a result line appears).
    private var wordCount: Int {
        recording.segments.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.medium) {
            // Word count is always shown; the saved-path line sits beneath it once a
            // transcript has been written (own line, so the two never collide).
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                // Word count matches the sidebar nav type (body) so the bottom row
                // reads consistently with "Settings" beside it.
                Text("\(wordCount) \(wordCount == 1 ? "word" : "words")")
                    .font(Theme.Typography.body).foregroundStyle(.secondary)
                if let result = recording.lastResult {
                    Text(result)
                        .font(Theme.Typography.captionSecondary).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            // Escape hatch for the post-meeting auto-clear: while the countdown
            // ticks, surface the remaining seconds and a Keep button that cancels
            // it, so a finished recording is never discarded out from under the user.
            if let pc = recording.pendingClear {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Clearing in \(pc.remaining)s").monospacedDigit()
                    Button("Keep") { recording.cancelPendingClear() }
                        .buttonStyle(.chip)
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            }
            if let review = recording.pendingSpeakerReview, !review.speakers.isEmpty {
                Button {
                    showSpeakerReview = true
                } label: {
                    Label("Assign speakers (\(review.speakers.count))", systemImage: "person.2.wave.2")
                }
                .font(Theme.Typography.caption)
            }
            if let url = recording.lastTranscriptURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .font(Theme.Typography.caption)
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
        .chromeSurface()
    }

    // MARK: Status helpers

    private var statusText: String {
        switch recording.state {
        case .preparing: return "Preparing…"
        case .recording: return "Recording"
        case .stopping: return "Stopping…"
        case .error: return "Error"
        case .idle:
            switch models.status {
            case .downloading: return "Downloading model…"
            case .loading(let stage, _): return stage
            case .failed: return "Model error"
            case .ready, .idle: return "Ready"
            }
        }
    }

    private var statusColor: Color {
        switch recording.state {
        case .recording: return .red
        case .preparing, .stopping: return .orange
        case .error: return .red
        case .idle:
            switch models.status {
            case .downloading, .loading: return .orange
            case .failed: return .red
            case .ready, .idle: return .secondary
            }
        }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
