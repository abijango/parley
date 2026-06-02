import SwiftUI
import AppKit

/// The app's main window: a sidebar that switches between the live "Record"
/// experience and the "History" browser, each shown in the detail pane.
struct MainWindowView: View {
    @EnvironmentObject private var recording: RecordingController
    @State private var selection: SidebarSection? = .record
    @State private var showingRecovery = false

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
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 220)
            .listStyle(.sidebar)
        } detail: {
            switch selection ?? .record {
            case .record:
                RecordDetailView()
            case .history:
                HistoryView()
            }
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
            controlBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
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
        .sheet(item: Binding(get: { recording.pendingSpeakerReview },
                             set: { recording.pendingSpeakerReview = $0 })) { review in
            AssignSpeakersView(review: review)
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
                    ? { id, name in recording.nameSpeaker(id, as: name) } : nil
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
                TranscriptPreviewView(url: recording.lastTranscriptURL)
            }
        }
    }

    // MARK: Control bar

    private var controlBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                recordButton
                timerView
                Spacer()
                modePicker
                statusBadge
            }

            HStack(spacing: 12) {
                capturePicker
                if settings.captureMode == .perApp { appPicker }
                Spacer()
                Text(settings.transcriptionEngine == .fluidAudio
                     ? "FluidAudio · Parakeet v3"
                     : settings.model.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let load = modelLoadingInfo {
                modelLoadingBar(stage: load.stage, fraction: load.fraction)
            }

            if recording.isRecording {
                levelMeters   // confirm both tracks are actually capturing
            }

            metadataFields   // editable during recording too (e.g. a mid-call joiner)

            advisoryRows

            if case .error(let message) = recording.state {
                errorRow(message)
            }
        }
        .padding(16)
    }

    /// Persistent warnings the user should fix before recording: denied
    /// permissions and a memory guard for heavy model loads. Shown whenever the
    /// condition holds (not only after a failed Start), each with a one-tap fix.
    @ViewBuilder private var advisoryRows: some View {
        if recording.micDenied {
            advisoryBanner(
                "Microphone access is off — recordings will capture no voice.",
                systemImage: "mic.slash.fill", tint: .red,
                action: PermissionManager.openMicrophoneSettings, actionLabel: "Open Settings")
        }
        if recording.systemAudioAvailable == false {
            advisoryBanner(
                "System-audio recording is off — the Remote track and call detection won't work.",
                systemImage: "speaker.slash.fill", tint: .red,
                action: PermissionManager.openPrivacySettings, actionLabel: "Open Settings")
        }
        if let advisory = models.memoryAdvisory {
            advisoryBanner(advisory, systemImage: "memorychip", tint: .orange)
        }
    }

    private func advisoryBanner(_ message: String, systemImage: String, tint: Color,
                                action: (() -> Void)? = nil, actionLabel: String = "") -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(actionLabel, action: action).font(.caption)
            }
        }
        .padding(8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private var levelMeters: some View {
        HStack(spacing: 16) {
            meter("Me", level: recording.micLevel, color: .accentColor)
            meter("Remote", level: recording.remoteLevel, color: .green)
            Spacer()
        }
    }

    private func meter(_ label: String, level: Float, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(width: 130, height: 6)
                Capsule().fill(color).frame(width: max(2, CGFloat(min(1, level)) * 130), height: 6)
            }
        }
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(WindowMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var recordButton: some View {
        Button {
            Task {
                if recording.isRecording { recording.stop() }
                else { mode = .live; await recording.start() }
            }
        } label: {
            Label(recording.isRecording ? "Stop" : "Start recording",
                  systemImage: recording.isRecording ? "stop.fill" : "record.circle")
                .frame(minWidth: 130)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(recording.isRecording ? .red : .accentColor)
        .disabled(recording.state == .preparing || recording.state == .stopping)
    }

    /// Live elapsed timer, ticking once a second while recording.
    @ViewBuilder private var timerView: some View {
        if let started = recording.recordingStarted {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text(Self.elapsed(from: started, to: context.date))
                    .font(.system(.title3, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var capturePicker: some View {
        Picker("Other audio", selection: Binding(
            get: { settings.captureMode }, set: { settings.captureMode = $0 }
        )) {
            ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
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
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("Meeting title", text: $recording.meetingTitle)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("Filing").font(.caption).foregroundStyle(.secondary)
                DestinationField(path: $recording.destinationPath,
                                 destinations: vault.destinations,
                                 firstRoot: settings.scanRoots.first ?? "Internal")
            }
            GridRow {
                Text("Attendees").font(.caption).foregroundStyle(.secondary)
                TokenField(tokens: attendeesBinding,
                           completions: vault.people,
                           placeholder: "Attendees (type to filter, or add new)",
                           onCreateNew: { name in pendingPerson = PendingPerson(name: name) })
            }
            GridRow(alignment: .top) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $recording.manualNotes)
                    .font(.callout)
                    .frame(height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }
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

    /// Stepping progress bar shown while the model loads into memory.
    private func modelLoadingBar(stage: String, fraction: Double) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
            Text(stage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
        }
    }

    /// Current model load/download progress, if any (drives `modelLoadingBar`).
    private var modelLoadingInfo: (stage: String, fraction: Double)? {
        switch models.status {
        case .downloading(let f): return ("Downloading… \(Int(f * 100))%", f)
        case .loading(let stage, let fraction): return (stage, fraction)
        case .idle, .ready, .failed: return nil
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            if message.localizedCaseInsensitiveContains("microphone") {
                Button("Open Settings") { PermissionManager.openMicrophoneSettings() }
                    .font(.caption)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let result = recording.lastResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text("\(recording.segments.count) segments").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = recording.lastTranscriptURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .font(.caption)
            }
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
