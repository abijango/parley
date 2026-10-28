import SwiftUI

// MARK: - Shell sidebar + center
//
// The main window is one three-pane shell (Claude-desktop style): this sidebar lists
// past meetings grouped by date under a few nav rows, and the center pane shows the
// live recording screen, the selected meeting, or People. It is written as an
// extension of `HistoryView` so the list keeps sharing the browser's selection,
// filters, queue actions, and file-op sheets with the note detail.

extension HistoryView {

    static let sidebarWidth: CGFloat = 260

    // MARK: Sidebar

    var shellSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 1) {
                if recording.isRecording {
                    liveRow
                } else {
                    navRow("New recording", symbol: "plus",
                           selected: shell.route == .live) { showLive() }
                }
                navRow("People", symbol: "person.2", selected: shell.route == .people) {
                    selection = []
                    shell.route = .people
                }
                sidebarSearchField
                    .padding(.top, Theme.Spacing.xSmall)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.top, Theme.Spacing.small)

            meetingsHeader
            queueBanner

            if filteredItems.isEmpty {
                listEmptyState
            } else {
                meetingList
            }

            Divider()
            sidebarFooter
        }
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity)
        .chromeSurface()
    }

    func showLive() {
        selection = []
        shell.route = .live
    }

    /// A top-of-sidebar navigation row (New recording, People).
    func navRow(_ title: String, symbol: String, selected: Bool,
                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).frame(width: 18)
            }
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textPrimary)
        }
        .buttonStyle(.row(selected: selected))
    }

    /// Replaces "New recording" while a recording runs: jumps back to the live screen.
    var liveRow: some View {
        Button(action: showLive) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(Theme.Severity.danger.color)
                    .frame(width: 18)
                Text("Recording")
                Spacer(minLength: Theme.Spacing.xSmall)
                LiveElapsedLabel()
            }
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textPrimary)
        }
        .buttonStyle(.row(selected: shell.route == .live))
        .help("Back to the live transcript")
    }

    static func elapsedString(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    var sidebarSearchField: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 18)
            TextField("Search meetings", text: $searchQuery)
                .textFieldStyle(.plain)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .font(Theme.Typography.body)
        .padding(.horizontal, Theme.Spacing.small)
        .frame(height: 28)
        .background(Theme.Radius.rect(Theme.Radius.small).fill(Theme.Palette.panelBg))
        .overlay(Theme.Radius.rect(Theme.Radius.small)
            .strokeBorder(Theme.Palette.divider, lineWidth: 0.5))
    }

    /// "Meetings" label with the status filter menu (All / Processing / Needs you / Done).
    var meetingsHeader: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Text(filter == .all ? "Meetings" : filter.rawValue)
                .font(Theme.Typography.captionSecondary)
                .foregroundStyle(Theme.Palette.textTertiary)
            if filter == .all, needsYouCount > 0 {
                Button { filter = .needsYou } label: {
                    Text("\(needsYouCount) need you")
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(Theme.Palette.accent)
                }
                .buttonStyle(.plain)
                .help("Show meetings that need you")
            }
            Spacer()
            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { f in
                        Text(f == .needsYou && needsYouCount > 0 ? "Needs you (\(needsYouCount))" : f.rawValue)
                            .tag(f)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Search inside transcripts", isOn: $searchInContents)
            } label: {
                Image(systemName: filter == .all
                      ? "line.3.horizontal.decrease"
                      : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(filter == .all ? Theme.Palette.textTertiary : Theme.Palette.accent)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter meetings")
        }
        .padding(.horizontal, Theme.Spacing.medium + 2)
        .padding(.top, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.xSmall)
    }

    /// The meeting list: date sections, or the queue order in the Processing filter
    /// (where drag-to-reorder applies).
    var meetingList: some View {
        List(selection: $selection) {
            if filter == .processing {
                ForEach(filteredItems) { item in
                    sidebarRow(item).tag(item.id)
                        .contextMenu { rowMenu(item) }
                }
                .onMove(perform: moveAction)
            } else {
                ForEach(groupedItems, id: \.group) { section in
                    Section {
                        ForEach(section.items) { item in
                            sidebarRow(item).tag(item.id)
                                .contextMenu { rowMenu(item) }
                        }
                    } header: {
                        Text(section.group.title)
                            .font(Theme.Typography.captionSecondary)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .tint(Theme.Palette.selection)
        .onDeleteCommand { if !selectedItems.isEmpty { beginDelete(selectedItems) } }
    }

    var groupedItems: [(group: MeetingDateGroup, items: [TranscriptItem])] {
        let now = Date()
        let buckets = Dictionary(grouping: filteredItems) { MeetingDateGroup($0.meta.date, now: now) }
        return buckets.keys.sorted().map { (group: $0, items: buckets[$0] ?? []) }
    }

    /// Compact one-line row: title, then an attention icon / status badge only when the
    /// meeting isn't simply done. In-flight work shows as a thin stage bar underneath.
    func sidebarRow(_ item: TranscriptItem) -> some View {
        let model = rowIndex.row(for: item)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack(spacing: Theme.Spacing.small) {
                Text(item.meta.title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.Spacing.xSmall)
                rowIndicator(item)
                if model.stage != .processed, model.rowIndicator == nil {
                    StatusBadge(model.statusLabel, severity: model.statusSeverity)
                }
            }
            PipelineStageBar(item: item, style: .mini)
        }
        .padding(.vertical, Theme.Spacing.xxSmall)
        .help("\(item.meta.title) · \(Self.dateString(item.meta.date))")
    }

    /// Bottom of the sidebar: a processing-queue chip (jumps to the Processing filter)
    /// and Settings.
    var sidebarFooter: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            SettingsLink {
                Label {
                    Text("Settings")
                } icon: {
                    Image(systemName: "gearshape").frame(width: 18)
                }
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            }
            .buttonStyle(.row())
            let busy = processingOrderedItems.count
            if busy > 0 {
                Button { filter = .processing } label: {
                    HStack(spacing: Theme.Spacing.xSmall) {
                        ProgressView().controlSize(.mini)
                        Text("\(busy) processing")
                    }
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize()
                }
                .buttonStyle(.chip)
                .help("Show the processing queue")
            }
        }
        .padding(Theme.Spacing.small)
    }

    // MARK: Center

    @ViewBuilder var shellCenter: some View {
        switch shell.route {
        case .live:
            RecordDetailView()
        case .people:
            PeopleView(voiceprintStore: recording.voiceprints)
        case .notes:
            VStack(spacing: 0) {
                detail
                if recording.isRecording {
                    stillRecordingBar
                }
            }
        }
    }

    /// Where the composer sits on the live screen: a reminder that a call is still
    /// being recorded while you read another note, with a way back.
    var stillRecordingBar: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(Theme.Severity.danger.color)
            Text(meetingTitleWhileRecording)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
            LiveElapsedLabel()
            Spacer(minLength: Theme.Spacing.small)
            Button("Back to live", action: showLive)
                .glassButton()
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(Theme.Radius.rect(Theme.Radius.large).fill(Theme.Palette.panelBg))
        .overlay(Theme.Radius.rect(Theme.Radius.large)
            .strokeBorder(Theme.Severity.danger.color.opacity(0.35), lineWidth: 0.5))
        .frame(maxWidth: 820)
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.bottom, Theme.Spacing.large)
        .padding(.top, Theme.Spacing.small)
    }

    var meetingTitleWhileRecording: String {
        let title = RecordingController.shared.meeting.meetingTitle
        return title.isEmpty ? "Still recording" : "Still recording “\(title)”"
    }
}

/// Elapsed time for the pinned "Recording" row. Its own observer of the live state, so
/// the shell doesn't re-render with every live-transcript update.
private struct LiveElapsedLabel: View {
    @ObservedObject private var live = RecordingController.shared.live

    var body: some View {
        if let started = live.recordingStarted {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text(HistoryView.elapsedString(from: started, to: context.date))
                    .font(Theme.Typography.mono)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }
}

/// A meeting's pipeline stage bar (detecting / queued / summarizing / failed), hidden
/// when idle. Observes the queue services itself so progress ticks only redraw the bar.
struct PipelineStageBar: View {
    enum Style { case mini, full }
    let item: TranscriptItem
    let style: Style
    @ObservedObject private var offline = RecordingController.shared.offlineService
    @ObservedObject private var summary = RecordingController.shared.summaryService

    var body: some View {
        if let bar = StageBarModel.derive(item: item, offline: offline, summary: summary) {
            switch style {
            case .mini:
                SegmentedStageBar(segments: bar.segments, style: .mini)
            case .full:
                SegmentedStageBar(segments: bar.segments,
                                  statusLabel: bar.statusLabel, sublabel: bar.sublabel)
            }
        }
    }
}
