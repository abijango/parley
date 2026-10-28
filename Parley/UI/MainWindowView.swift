import SwiftUI
import AppKit

/// The app's main window: a three-pane shell (Claude-desktop style). The sidebar lists
/// past meetings by date; the center shows the live recording screen, the selected
/// meeting, or People. The shell itself lives in `HistoryView` + `MeetingSidebar.swift`
/// so the list and the note detail share one selection and set of actions.
struct MainWindowView: View {
    @EnvironmentObject private var recording: RecordingController
    @StateObject private var shell = MainShellModel()
    @State private var showingRecovery = false
    @AppStorage("parley.sidebarCollapsed") private var sidebarCollapsed = false

    var body: some View {
        // A plain HStack shell (NOT NavigationSplitView): in this fixed menu-bar
        // utility window, NavigationSplitView's adaptive column-collapsing and
        // integrated title bar misrendered on narrow built-in displays (blank band,
        // window title bleeding over the content). A fixed HStack renders identically
        // at every size.
        HistoryView()
            .frame(minWidth: 720, minHeight: 560)
            .background(Theme.Palette.windowBg)
            // Sidebar collapse toggle lives in the toolbar (in the title bar, by the
            // traffic lights) — the native placement, so it isn't floating in the column.
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(Theme.Motion.quick) { sidebarCollapsed.toggle() }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help(sidebarCollapsed ? "Show sidebar" : "Hide sidebar")
                }
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .automatic) {
                    NotesPanelToggle()
                }
            }
            .background(WindowConfigurator())   // hide the "Parley" title text
            .environmentObject(recording.store)
            .environmentObject(shell)
            // Crash recovery: offer any interrupted sessions on launch; auto-dismiss
            // once they're all handled (resumed / recovered / discarded).
            .sheet(isPresented: $showingRecovery) {
                RecoveryView { showingRecovery = false }
                    .environmentObject(recording)
            }
            // Post-call batch enrichment sheet (Slice B): one-time prompt to add Company
            // for attendees with no known rolodex entry. The setter handles OS-level
            // dismiss (Escape) by calling finishEnrichment(save:false), which ensures the
            // deferred non-speaker summary always fires even when the user skips.
            .sheet(isPresented: Binding(
                get: { recording.autoPresentEnrichment && recording.pendingEnrichment != nil },
                set: { if !$0 && recording.pendingEnrichment != nil { recording.finishEnrichment(save: false) } })) {
                AttendeeEnrichmentSheet(recording: recording)
            }
            .onChange(of: recording.pendingRecoveries.isEmpty) {
                showingRecovery = !recording.pendingRecoveries.isEmpty
            }
            .onAppear {
                if !recording.pendingRecoveries.isEmpty { showingRecovery = true }
            }
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
        guard let window else { return }
        window.titleVisibility = .hidden
        window.title = ""
    }
}

/// The live recording screen: the transcript fills the center with a rounded composer
/// bar (Start/Stop, timer, meters, audio sources) floating at the bottom, and the
/// meeting details + notes in the right rail. When a recording finishes, the shell
/// jumps to the new note in the sidebar.
struct RecordDetailView: View {
    @EnvironmentObject private var recording: RecordingController
    @ObservedObject private var live = RecordingController.shared.live
    @ObservedObject private var meeting = RecordingController.shared.meeting
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var vault: VaultDirectory
    @State private var apps: [CapturableApp] = []
    @State private var showingSources = false
    @State private var pendingPerson: PendingPerson?
    /// Distinguishes the user's typing in the Title field from programmatic
    /// auto-fill (discovered titles): only focused changes count as user edits.
    @FocusState private var titleFocused: Bool
    @AppStorage("parley.axBannerDismissed") private var axBannerDismissed = false
    /// Cached AX trust, matching how `SettingsView` reads it. `AXIsProcessTrusted()` is
    /// a synchronous system call, and reading it inline in `advisoryRows` meant making
    /// it on the main thread on *every* body evaluation of the always-mounted inspector
    /// rail. AX trust only changes via System Settings, so re-reading on activation
    /// (plus at appear) catches it. See docs/RECORDING_FREEZE_INVESTIGATION.md.
    @State private var axTrusted = PermissionManager.accessibilityAuthorized()
    // Notes panel (right rail) visibility + section disclosure — view-local
    // presentation state, deliberately not in AppSettings.
    @AppStorage(NotesPanel<EmptyView>.visibleKey) private var notesPanelVisible = true
    @AppStorage("parley.liveNotesExpanded") private var liveNotesExpanded = true
    @AppStorage("parley.meetingDetailsExpanded") private var meetingDetailsExpanded = false
    @AppStorage("parley.liveSummaryExpanded") private var liveSummaryExpanded = false

    /// Pre-first-recording: no live segments yet and not actively recording.
    private var isPreRecordIdle: Bool {
        !recording.isRecording && live.segments.isEmpty
    }

    /// Once the finished transcript is written (and any enrichment sheet is closed),
    /// select it in the sidebar so the note — and its summary — take the center.
    private func showPreviewIfSettled() {
        guard let url = recording.lastTranscriptURL, !recording.isRecording else { return }
        guard recording.pendingEnrichment == nil else { return }
        recording.historyFocusPath = url.path
    }

    /// A new attendee name awaiting rich-contact entry.
    struct PendingPerson: Identifiable {
        let id = UUID()
        let name: String
    }

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if notesPanelVisible {
                inspector
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(minWidth: 480, minHeight: 520)
        .onAppear {
            apps = ProcessLister.capturableApps()
            axTrusted = PermissionManager.accessibilityAuthorized()
        }
        // The user grants AX in System Settings and comes back — that return is the only
        // moment the cached trust can go stale.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = PermissionManager.accessibilityAuthorized()
        }
        // Jump to the finished note when a recording writes it — but never while a
        // (new) recording is already live, so a back-to-back auto-started call isn't
        // yanked to the previous call's note.
        .onChange(of: recording.lastTranscriptURL) { showPreviewIfSettled() }
        .onChange(of: recording.pendingEnrichment?.id) { showPreviewIfSettled() }
        .onChange(of: recording.isRecording) {
            if recording.isRecording {
                withAnimation(Theme.Motion.quick) { meetingDetailsExpanded = true }
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
        meeting.destinationPath.split(separator: "/").last.map(String.init) ?? ""
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let load = modelLoadingInfo {
                modelLoadingBar(stage: load.stage, fraction: load.fraction)
                    .padding(.horizontal, Theme.Spacing.large)
                    .padding(.vertical, Theme.Spacing.small)
            }
            // An overlay, not a ZStack: during recording the idle message is absent, so
            // a ZStack was a stack level that held one child and bought nothing but
            // layout cost. The transcript sits at the bottom of a seven-level nest and
            // every level multiplies the sizing work — see
            // docs/LAYOUT_EXPLOSION_AUDIT.md.
            LiveTranscriptView(
                isRecording: recording.isRecording,
                people: vault.people,
                attendees: TranscriptWriter.splitAttendees(meeting.attendees),
                onNameSpeaker: settings.batchMode
                    ? nil : { id, name in recording.nameSpeaker(id, as: name) },
                onMergeSpeaker: settings.batchMode
                    ? nil : { id, target in recording.mergeSpeaker(id, into: target) },
                liveDisabled: settings.batchMode,
                hidesEmptyState: isPreRecordIdle
            )
            .overlay {
                // Scoped to the message that actually animates, so flipping
                // isPreRecordIdle doesn't animate a layout pass over the transcript.
                Group {
                    if isPreRecordIdle {
                        preRecordIdleMessage
                            .transition(.opacity)
                    }
                }
                .animation(Theme.Motion.spring, value: isPreRecordIdle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            OfflinePassBar()
            VStack(spacing: Theme.Spacing.small) {
                advisoryRows
                if case .error(let message) = live.state {
                    StatusBanner(.danger, message,
                                 actionLabel: message.localizedCaseInsensitiveContains("microphone") ? "Open Settings" : nil,
                                 action: message.localizedCaseInsensitiveContains("microphone") ? PermissionManager.openMicrophoneSettings : nil)
                }
                afterCallRow
                composer
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.top, Theme.Spacing.small)
            .padding(.bottom, Theme.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Composer

    /// The floating transport bar (Claude-composer style): audio sources on the left,
    /// status + timer, then word count, model, and Start/Stop. Level meters ride on top
    /// while recording.
    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            levelMeters
            HStack(spacing: Theme.Spacing.medium) {
                sourcesButton
                statusBadge
                timerView
                Spacer(minLength: Theme.Spacing.small)
                if live.liveWordCount > 0 {
                    Text("\(live.liveWordCount) \(live.liveWordCount == 1 ? "word" : "words")")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .monospacedDigit()
                }
                audioModelBadge
                recordButton
                    .frame(width: 104)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small + 2)
        .glassSurface(in: Theme.Radius.rect(Theme.Radius.large))
    }

    /// "+ Mic · All apps ⌄": opens the capture-source and mic-mode controls.
    private var sourcesButton: some View {
        Button { showingSources.toggle() } label: {
            HStack(spacing: Theme.Spacing.xSmall) {
                Image(systemName: "plus")
                    .font(Theme.Typography.controlLabel)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.Palette.selection))
                Text(sourcesSummary)
                    .font(Theme.Typography.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.Palette.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Audio sources")
        .popover(isPresented: $showingSources, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                railField("Other audio") {
                    audioControls
                }
                railField("Microphone") {
                    micModePicker
                }
                if recording.isRecording {
                    Text("Audio sources are fixed while recording.")
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .padding(Theme.Spacing.large)
            .frame(width: 320)
        }
    }

    private var sourcesSummary: String {
        let other: String
        switch settings.captureMode {
        case .perApp:
            other = apps.first(where: { $0.id == recording.selectedAppPID })?.name ?? settings.captureMode.label
        default:
            other = settings.captureMode.label
        }
        return "\(live.micInputMode.label) mic · \(other)"
    }

    /// After a call: where the note went, the auto-clear countdown (with Keep), and
    /// "Ready for next" to reset the live screen.
    @ViewBuilder private var afterCallRow: some View {
        if let url = recording.lastTranscriptURL, !recording.isRecording {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(Theme.Severity.success.color)
                Text(recording.lastResult ?? "Saved")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.chip)
                    .font(Theme.Typography.caption)
                Spacer(minLength: Theme.Spacing.small)
                // Escape hatch for the post-meeting auto-clear: while the countdown
                // ticks, show the remaining seconds and a Keep button that cancels it.
                if let pc = recording.pendingClear {
                    Text("Clearing in \(pc.remaining)s").monospacedDigit()
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Button("Keep") { recording.cancelPendingClear() }
                        .buttonStyle(.chip)
                        .font(Theme.Typography.caption)
                }
                Button("Ready for next") { recording.clearForNextMeeting() }
                    .glassButton()
                    .controlSize(.small)
            }
            .padding(.horizontal, Theme.Spacing.xSmall)
        }
    }

    // MARK: Notes panel

    /// The right-hand notes panel: My notes (fills the rail), meeting details, and the
    /// summary placeholder. Start/Stop and audio sources live in the composer.
    private var inspector: some View {
        NotesPanel {
            NotesPanelSection("My notes", symbol: "square.and.pencil",
                              isExpanded: $liveNotesExpanded, fills: true) {
                notesField
            }
            NotesPanelSection("Details", symbol: "doc.text", isExpanded: $meetingDetailsExpanded) {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    metadataFields   // editable during recording too (e.g. a mid-call joiner)
                    liveAttachmentsField
                }
            }
            NotesPanelSection("Summary", symbol: "sparkles", isExpanded: $liveSummaryExpanded) {
                Text("Meeting notes are generated after the call ends. The finished note opens here when it's ready.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !liveNotesExpanded { Spacer(minLength: 0) }
        }
    }

    /// Informational empty state; Start/Stop is in the composer below.
    private var preRecordIdleMessage: some View {
        VStack(spacing: Theme.Spacing.large) {
            Image(systemName: settings.batchMode ? "waveform" : "text.bubble")
                .font(.system(size: 30, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 76, height: 76)
                .background(Theme.Palette.accent.opacity(Theme.Opacity.tintFill), in: Circle())

            VStack(spacing: Theme.Spacing.xSmall) {
                Text(settings.batchMode ? "Batch mode" : "Ready to record")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(.primary)
                Text(settings.batchMode
                     ? "Audio is saved as you record. The transcript is written after the call."
                     : "Your live transcript will appear here as people speak.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xLarge)
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
        MicSilenceBanner()
        // One-time nudge: meeting-detail suggestions are on but can't work
        // without the Accessibility permission (recording is unaffected).
        if settings.metadataDiscoveryEnabled, !axBannerDismissed, !axTrusted {
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

    /// Compact model badge for the transport bar. FluidAudio uses one Parakeet model.
    private var audioModelBadge: some View {
        let info = audioModelBadgeInfo
        return HStack(spacing: Theme.Spacing.xxSmall) {
            if let engine = info.engine {
                Text(engine)
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(.tertiary)
            }
            Text(info.model)
                .font(Theme.Typography.controlLabel)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.xxSmall + 1)
        .background(Capsule().fill(.quaternary.opacity(Theme.Opacity.surface)))
        .lineLimit(1)
        .truncationMode(.tail)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(-1)
    }

    private struct AudioModelBadgeInfo {
        let engine: String?
        let model: String
    }

    private var audioModelBadgeInfo: AudioModelBadgeInfo {
        if settings.batchMode {
            let profileName = BatchModePolicy.profile(language: settings.liveStreamingLanguage) == .parakeetUnified
                ? "Parakeet Unified"
                : "Parakeet v3"
            return AudioModelBadgeInfo(engine: profileName, model: "Batch mode")
        }
        return AudioModelBadgeInfo(engine: nil, model: FluidAsrRouting.displayModelName(settings: settings))
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
        Button(action: toggleRecording) {
            Label(recording.isRecording ? "Stop" : "Start",
                  systemImage: recording.isRecording ? "stop.fill" : "record.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(InkButtonStyle(role: recording.isRecording ? .primary : .clay))
        .disabled(live.state == .preparing || live.state == .stopping)
    }

    private func toggleRecording() {
        Task {
            if recording.isRecording { recording.stop() }
            else { await recording.start() }
        }
    }

    /// Live elapsed timer, ticking once a second while recording.
    @ViewBuilder private var timerView: some View {
        if let started = live.recordingStarted {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text(Self.elapsed(from: started, to: context.date))
                    .font(Theme.Typography.mono)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
    }

    /// Live mic + remote input levels, shown only while recording so a dead or
    /// wrong input device is visible at a glance. The mic bar turns red when the
    /// sustained-silence heuristic (`micSeemsSilent`) trips.
    @ViewBuilder private var levelMeters: some View {
        if recording.isRecording {
            RecordLevelMeters()
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

    private var micModePicker: some View {
        Picker("Mic", selection: Binding(
            get: { live.micInputMode },
            set: { recording.setMicInputMode($0) }
        )) {
            ForEach(MicInputMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Regular = normal mic level. Room = +6 dB boost for distant speakers (applied to the mic track).")
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
                TextField("Meeting title", text: $meeting.meetingTitle)
                    .textFieldStyle(.parley)
                    .focused($titleFocused)
                    .onChange(of: meeting.meetingTitle) {
                        if titleFocused { recording.userEditedTitle() }
                        recording.scheduleMetadataSync()
                        recording.userInteracted()
                    }
                // Discovery found a (different) title after the user edited the
                // field — offer it without overwriting.
                if let discovered = meeting.discoveredTitle,
                   discovered != meeting.meetingTitle {
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
                DestinationField(path: $meeting.destinationPath,
                                 destinations: vault.destinations,
                                 firstRoot: settings.scanRoots.first ?? "Internal")
                    .onChange(of: meeting.destinationPath) {
                        recording.scheduleMetadataSync()
                        recording.userInteracted()
                    }
            }
            railField("Attendees") {
                TokenField(tokens: attendeesBinding,
                           completions: vault.people,
                           placeholder: "Add attendees",
                           onCreateNew: { name in pendingPerson = PendingPerson(name: name) })
                    .onChange(of: meeting.attendees) {
                        recording.admission.tokenFieldChanged(
                            to: TranscriptWriter.splitAttendees(meeting.attendees))
                        recording.scheduleMetadataSync()
                        recording.userInteracted()
                    }
                if !attendeesBinding.wrappedValue.isEmpty {
                    Button("Clear all attendees") { meeting.attendees = "" }
                        .buttonStyle(.chip)
                        .help("Remove every attendee. In-call people you remove stay excluded for this session.")
                }
                SuggestionChips(
                    meeting: meeting,
                    onAccept: { recording.acceptSuggestion($0) },
                    onDismiss: { recording.dismissSuggestion($0) },
                    onAcceptAll: { recording.acceptAllSuggestions() })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @State private var attachmentError: String?

    /// Screenshots / whiteboard photos during a live recording.
    private var liveAttachmentsField: some View {
        MeetingAttachmentsView(
            attachments: meeting.attachments,
            vaultURL: settings.vaultURL,
            onPaste: {
                if let err = recording.pasteLiveAttachment() { attachmentError = err }
            },
            onPickFiles: { recording.pickAndAddLiveAttachments() },
            onRemove: { recording.removeLiveAttachment(id: $0) },
            onCaptionChange: { id, caption in
                recording.updateLiveAttachmentCaption(id: id, caption: caption)
            }
        )
        .alert("Attachment", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK", role: .cancel) { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
    }

    /// The My notes editor (serif prose) — fills the panel's remaining height and
    /// scrolls its own content once notes exceed the frame.
    private var notesField: some View {
        TextEditor(text: $meeting.manualNotes)
            .font(Theme.Typography.prose)
            .scrollContentBackground(.hidden)
            .padding(Theme.Spacing.small)
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
            .background(Theme.Radius.rect(Theme.Radius.small).fill(Theme.Palette.panelBg))
            .overlay(Theme.Radius.rect(Theme.Radius.small)
                .strokeBorder(Theme.Palette.divider, lineWidth: 0.5))
            .overlay(alignment: .topLeading) {
                if meeting.manualNotes.isEmpty {
                    Text("Jot down anything worth remembering…")
                        .font(Theme.Typography.prose)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.horizontal, Theme.Spacing.small + 5)
                        .padding(.vertical, Theme.Spacing.small)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: meeting.manualNotes) { recording.userInteracted() }
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
                meeting.attendees
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            },
            set: { meeting.attendees = $0.joined(separator: ", ") }
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
        switch recording.fluidModels.status {
        case .downloading: return ("Downloading…", 0.3)
        case .loading: return ("Loading…", 0.6)
        default: return nil
        }
    }

    // MARK: Status helpers

    private var statusText: String {
        if recording.isRecording || live.state == .preparing || live.state == .stopping {
            switch live.state {
            case .preparing: return "Preparing…"
            case .recording: return "Recording"
            case .stopping: return "Stopping…"
            case .error: return "Error"
            case .idle: return recording.appActivity.statusText
            }
        }
        if case .error = live.state { return "Error" }
        switch recording.fluidModels.status {
        case .downloading: return "Downloading model…"
        case .loading: return "Loading model…"
        case .failed: return "Model error"
        default: return recording.appActivity.statusText
        }
    }

    private var statusColor: Color {
        if recording.isRecording || live.state == .preparing || live.state == .stopping {
            switch live.state {
            case .recording: return .red
            case .preparing, .stopping: return .orange
            case .error: return .red
            case .idle: return .secondary
            }
        }
        if case .error = live.state { return .red }
        switch recording.appActivity {
        case .recording: return .red
        case .settling: return .orange
        case .processing: return .orange
        case .idle:
            switch recording.fluidModels.status {
            case .downloading, .loading: return .orange
            case .failed: return .red
            default: return .secondary
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

/// Level meters observe `RecordingMeterState` directly so 5 Hz ticks stay inside
/// this subtree instead of rebuilding the record pane.
private struct RecordLevelMeters: View {
    @ObservedObject private var meters = RecordingController.shared.live.meters

    var body: some View {
        HStack(spacing: Theme.Spacing.large) {
            InputLevelBar(label: "Mic", level: meters.micLevel, warn: meters.micSeemsSilent)
            InputLevelBar(label: "Remote", level: meters.remoteLevel)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MicSilenceBanner: View {
    @ObservedObject private var meters = RecordingController.shared.live.meters

    var body: some View {
        if meters.micSeemsSilent {
            StatusBanner(.danger,
                         "Your mic has been silent while the call has audio — check the input device.",
                         symbol: "mic.slash.fill",
                         actionLabel: "Sound Settings", action: PermissionManager.openSoundSettings)
        }
    }
}

private struct OfflinePassBar: View {
    @ObservedObject private var offline = RecordingController.shared.offlineService
    @ObservedObject private var recording = RecordingController.shared.live
    @ObservedObject private var controller = RecordingController.shared

    private var waitingCount: Int {
        offline.jobs.values.filter { $0 == .queued || $0 == .paused || $0 == .held }.count
    }

    var body: some View {
        Group {
            if controller.isRecording, waitingCount > 0, !controller.sessionBatchMode {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "pause.circle")
                    Text("Speaker pass paused · \(waitingCount) waiting")
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.small)

            } else if offline.runningProgress != nil {
                let running = offline.runningProgress.flatMap {
                    StageBarModel.fuse(offlineState: .running, offlineProgress: $0,
                                       summaryRunning: false, summaryQueued: false,
                                       summaryFailed: nil, summaryPaused: false, summaryActivity: nil)
                }
                if let model = running {
                    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                        SegmentedStageBar(segments: model.segments,
                                          statusLabel: model.statusLabel, sublabel: model.sublabel)
                        if offline.queuedCount > 0 {
                            Text("+\(offline.queuedCount) queued")
                                .font(Theme.Typography.captionSecondary)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.small)
    
                }
            } else if waitingCount > 0, !controller.sessionBatchMode, let remaining = controller.idleDrainRemaining {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "clock")
                    Text("Speaker pass in \(remaining)s")
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.small)

            }
        }
        .animation(Theme.Motion.gentle, value: waitingCount)
    }
}
