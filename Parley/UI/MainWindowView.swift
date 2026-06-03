import SwiftUI
import AppKit

/// The app's main window: a sidebar that switches between the live "Record"
/// experience and the "History" browser, each shown in the detail pane.
struct MainWindowView: View {
    @EnvironmentObject private var recording: RecordingController
    @ObservedObject private var store = RecordingController.shared.store
    @ObservedObject private var summaryService = RecordingController.shared.summaryService
    @State private var selection: SidebarSection? = .record
    @State private var showingRecovery = false
    @AppStorage("parley.sidebarCollapsed") private var sidebarCollapsed = false

    /// Badge on the History nav item: summaries running + staged-and-waiting-for-review.
    private var historyBadge: Int {
        let ready = store.items.filter { $0.summaryReadyURL != nil }.count
        let pending = summaryService.jobs.values.filter { if case .pending = $0 { return true } else { return false } }.count
        return ready + pending
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
        .environmentObject(recording.store)
        // Crash recovery: offer any interrupted sessions on launch; auto-dismiss
        // once they're all handled (resumed / recovered / discarded).
        .sheet(isPresented: $showingRecovery) {
            RecoveryView { showingRecovery = false }
                .environmentObject(recording)
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
            // Collapse / expand toggle.
            Button {
                withAnimation(Theme.Motion.quick) { sidebarCollapsed.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(Theme.Typography.body)
                    .frame(maxWidth: .infinity, alignment: sidebarCollapsed ? .center : .trailing)
                    .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.xSmall)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")

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
                HStack(spacing: Theme.Spacing.small) {
                    Label(title, systemImage: symbol)
                    Spacer()
                    if badge > 0 { CountBadge(count: badge) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(Theme.Typography.body)
    }
}

/// The live recording experience: recording controls + session metadata on top,
/// the live transcription stream filling the body, and a result/footer bar.
struct RecordDetailView: View {
    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var vault: VaultDirectory
    @State private var apps: [CapturableApp] = []
    @State private var mode: WindowMode = .live
    @State private var pendingPerson: PendingPerson?
    @State private var showSpeakerReview = false

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
                Divider()
                inspector
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            offlinePassBar
            footer
        }
        .frame(minWidth: 480, minHeight: 520)
        .animation(Theme.Motion.gentle, value: recording.offlinePass)
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
        ScrollView {
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
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 300)
        .chromeSurface()
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
    }

    /// The model label shown beside the "Audio" disclosure. For WhisperKit, the live
    /// transcript is produced by the *live* model when it's enabled; only the final
    /// (at-stop) model runs in offline-only mode. FluidAudio uses a single model.
    private var audioModelLabel: String {
        if settings.transcriptionEngine == .fluidAudio { return "FluidAudio · Parakeet v3" }
        return settings.liveTranscriptEnabled ? settings.liveModel.label : settings.model.label
    }

    /// Audio capture controls, always visible directly under the record button:
    /// the capture-mode picker (full width), the per-app picker when relevant, and
    /// the live Me/Remote level meters while recording.
    private var audioControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            capturePicker
            if settings.captureMode == .perApp { appPicker }
            if recording.isRecording {
                levelMeters   // confirm both tracks are actually capturing
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var levelMeters: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            meter("Me", level: recording.micLevel, color: Theme.Palette.accent)
            meter("Remote", level: recording.remoteLevel, color: .green)
        }
    }

    private func meter(_ label: String, level: Float, color: Color) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(label).font(Theme.Typography.captionSecondary).foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(width: 130, height: 6)
                Capsule().fill(color).frame(width: max(2, CGFloat(min(1, level)) * 130), height: 6)
            }
        }
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
                    .onChange(of: recording.meetingTitle) { recording.scheduleMetadataSync() }
            }
            railField("Filing") {
                DestinationField(path: $recording.destinationPath,
                                 destinations: vault.destinations,
                                 firstRoot: settings.scanRoots.first ?? "Internal")
                    .onChange(of: recording.destinationPath) { recording.scheduleMetadataSync() }
            }
            railField("Attendees") {
                TokenField(tokens: attendeesBinding,
                           completions: vault.people,
                           placeholder: "Add attendees",
                           onCreateNew: { name in pendingPerson = PendingPerson(name: name) })
                    .onChange(of: recording.attendees) { recording.scheduleMetadataSync() }
            }
            railField("Notes") {
                TextEditor(text: $recording.manualNotes)
                    .font(Theme.Typography.body)
                    .frame(height: 64)
                    .overlay(Theme.Radius.rect(Theme.Radius.small).strokeBorder(.quaternary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// A thin strip under the transcript showing the post-stop whole-recording
    /// diarization pass: a spinner while it runs, then what it changed. Lingers
    /// until the next recording starts so a fast pass is still noticed.
    @ViewBuilder private var offlinePassBar: some View {
        switch recording.offlinePass {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView().controlSize(.small).scaleEffect(0.7, anchor: .center)
                Text("Offline Speaker Detection…").font(Theme.Typography.caption)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.small)
            .background(.quaternary.opacity(Theme.Opacity.surface))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .done(let note):
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.Severity.success.color).font(Theme.Typography.caption)
                Text(note).font(Theme.Typography.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.small)
            .background(.quaternary.opacity(Theme.Opacity.surface))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Live word count across all transcript segments (shown until a result line appears).
    private var wordCount: Int {
        recording.segments.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.medium) {
            if let result = recording.lastResult {
                Text(result).font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text("\(wordCount) \(wordCount == 1 ? "word" : "words")")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
            Spacer()
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
