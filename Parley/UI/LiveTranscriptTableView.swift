import AppKit
import Combine
import SwiftUI

/// Live transcript as an AppKit table. `sizeThatFits` returns the SwiftUI proposal so
/// row count is not a term in the window's layout pass. The coordinator observes
/// `LiveSegmentStore` directly; `[Segment]` never crosses a SwiftUI `body`.
struct LiveTranscriptTable: NSViewRepresentable {
    let store: LiveSegmentStore
    var isRecording: Bool
    var people: [String]
    var attendees: [String]
    var onNameSpeaker: ((String, String) -> Void)?
    var liveDisabled: Bool
    var hidesEmptyState: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true

        let table = NSTableView()
        table.headerView = nil
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.usesAutomaticRowHeights = true
        table.intercellSpacing = NSSize(width: 0, height: Theme.Spacing.small)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scroll.documentView = table
        context.coordinator.attach(scroll: scroll, table: table)
        context.coordinator.applyChrome(
            isRecording: isRecording,
            liveDisabled: liveDisabled,
            hidesEmptyState: hidesEmptyState,
            people: people,
            attendees: attendees,
            onNameSpeaker: onNameSpeaker)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.applyChrome(
            isRecording: isRecording,
            liveDisabled: liveDisabled,
            hidesEmptyState: hidesEmptyState,
            people: people,
            attendees: attendees,
            onNameSpeaker: onNameSpeaker)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.bounds.width,
               height: proposal.height ?? nsView.bounds.height)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private let store: LiveSegmentStore
        private var rows: [Segment] = []
        private var cancellable: AnyCancellable?
        private var boundsObserver: NSObjectProtocol?
        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private var emptyHost: NSHostingView<EmptyStateView>?
        private var pinnedToBottom = true
        private var applyingProgrammaticScroll = false

        var people: [String] = []
        var attendees: [String] = []
        var onNameSpeaker: ((String, String) -> Void)?
        var isRecording = false
        var liveDisabled = false
        var hidesEmptyState = false

        init(store: LiveSegmentStore) {
            self.store = store
            super.init()
        }

        func attach(scroll: NSScrollView, table: NSTableView) {
            scrollView = scroll
            tableView = table
            let host = NSHostingView(rootView: Self.emptyView(isRecording: false, liveDisabled: false))
            host.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(host)
            NSLayoutConstraint.activate([
                host.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
                host.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
                host.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -32),
            ])
            emptyHost = host

            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.noteUserScroll()
                }
            }

            cancellable = store.$segments.sink { [weak self] new in
                Task { @MainActor in
                    self?.apply(new)
                }
            }
            apply(store.segments)
        }

        func applyChrome(
            isRecording: Bool,
            liveDisabled: Bool,
            hidesEmptyState: Bool,
            people: [String],
            attendees: [String],
            onNameSpeaker: ((String, String) -> Void)?
        ) {
            self.isRecording = isRecording
            self.liveDisabled = liveDisabled
            self.hidesEmptyState = hidesEmptyState
            self.people = people
            self.attendees = attendees
            self.onNameSpeaker = onNameSpeaker
            refreshEmpty()
        }

        func teardown() {
            cancellable?.cancel()
            cancellable = nil
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            boundsObserver = nil
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("line")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? LiveTranscriptRowView
                ?? LiveTranscriptRowView()
            cell.identifier = id
            let segment = rows[row]
            let canName = segment.speakerId != nil && onNameSpeaker != nil
            cell.apply(segment, textWidth: Self.textWidth(in: tableView), canName: canName) { [weak self] in
                self?.presentNamer(for: segment, from: cell.speakerButton)
            }
            return cell
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table = tableView, table.numberOfRows > 0 else { return }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        }

        private func apply(_ new: [Segment]) {
            guard let table = tableView else {
                rows = new
                return
            }
            let edit = LiveTranscriptTableDiff.edit(from: rows, to: new)
            rows = new
            let columns = IndexSet(integer: 0)
            switch edit {
            case .none:
                break
            case .reloadAll:
                table.reloadData()
            case .append(let indexes):
                table.insertRows(at: indexes, withAnimation: [])
            case .reload(let indexes):
                table.reloadData(forRowIndexes: indexes, columnIndexes: columns)
            case .reloadAndAppend(let reload, let append):
                table.reloadData(forRowIndexes: reload, columnIndexes: columns)
                table.insertRows(at: append, withAnimation: [])
            }
            refreshEmpty()
            scrollToTailIfPinned()
        }

        private func refreshEmpty() {
            let show = rows.isEmpty && !hidesEmptyState
            emptyHost?.rootView = Self.emptyView(isRecording: isRecording, liveDisabled: liveDisabled)
            emptyHost?.isHidden = !show
        }

        private func scrollToTailIfPinned() {
            guard pinnedToBottom, let table = tableView, table.numberOfRows > 0 else { return }
            applyingProgrammaticScroll = true
            table.scrollRowToVisible(table.numberOfRows - 1)
            applyingProgrammaticScroll = false
        }

        private func noteUserScroll() {
            guard !applyingProgrammaticScroll, let scroll = scrollView, let table = tableView else { return }
            let visible = scroll.contentView.bounds
            let gap = table.bounds.maxY - visible.maxY
            pinnedToBottom = gap < 48
        }

        private func presentNamer(for segment: Segment, from anchor: NSView) {
            guard let id = segment.speakerId, let commit = onNameSpeaker else { return }
            var popover: NSPopover?
            let root = TranscriptSpeakerNamer(
                draft: segment.speakerName ?? "",
                people: people,
                attendees: attendees,
                onCommit: { name in
                    commit(id, name)
                    popover?.performClose(nil)
                }
            )
            let hosting = NSHostingController(rootView: root)
            let pop = NSPopover()
            pop.behavior = .transient
            pop.contentViewController = hosting
            popover = pop
            pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }

        private static func textWidth(in table: NSTableView) -> CGFloat {
            max(80, table.bounds.width
                - Theme.Spacing.large * 2
                - LiveTranscriptRowView.timeWidth
                - LiveTranscriptRowView.speakerWidth
                - Theme.Spacing.medium * 2)
        }

        private static func emptyView(isRecording: Bool, liveDisabled: Bool) -> EmptyStateView {
            if liveDisabled {
                return EmptyStateView(
                    icon: isRecording ? "waveform.badge.magnifyingglass" : "doc.text",
                    title: isRecording ? "Recording" : "Offline-only mode",
                    detail: isRecording ? "The transcript is generated when you stop."
                        : "The transcript appears after you stop recording.",
                    animateIcon: isRecording)
            }
            return EmptyStateView(
                icon: isRecording ? "waveform" : "text.bubble",
                title: isRecording ? "Listening…" : "Start recording",
                detail: isRecording ? "Transcribed text will appear here in real time."
                    : "Your live transcript will appear here as people speak.",
                animateIcon: isRecording)
        }
    }
}

final class LiveTranscriptRowView: NSView {
    static let timeWidth: CGFloat = 88
    static let speakerWidth: CGFloat = 80

    private let timeField = NSTextField(labelWithString: "")
    let speakerButton = NSButton(title: "", target: nil, action: nil)
    private let textField = NSTextField(wrappingLabelWithString: "")
    private var onName: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        timeField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeField.textColor = .tertiaryLabelColor
        timeField.translatesAutoresizingMaskIntoConstraints = false
        timeField.setContentHuggingPriority(.required, for: .horizontal)
        timeField.setContentCompressionResistancePriority(.required, for: .horizontal)

        speakerButton.isBordered = false
        speakerButton.bezelStyle = .inline
        speakerButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        speakerButton.alignment = .left
        speakerButton.lineBreakMode = .byTruncatingTail
        speakerButton.translatesAutoresizingMaskIntoConstraints = false
        speakerButton.target = self
        speakerButton.action = #selector(nameSpeaker)
        speakerButton.setContentHuggingPriority(.required, for: .horizontal)
        speakerButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        textField.font = NSFont(name: "New York", size: 15) ?? NSFont.systemFont(ofSize: 15)
        textField.textColor = .labelColor
        textField.isSelectable = true
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(timeField)
        addSubview(speakerButton)
        addSubview(textField)

        NSLayoutConstraint.activate([
            timeField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.large),
            timeField.widthAnchor.constraint(equalToConstant: Self.timeWidth),
            timeField.firstBaselineAnchor.constraint(equalTo: textField.firstBaselineAnchor),

            speakerButton.leadingAnchor.constraint(equalTo: timeField.trailingAnchor, constant: Theme.Spacing.medium),
            speakerButton.widthAnchor.constraint(equalToConstant: Self.speakerWidth),
            speakerButton.firstBaselineAnchor.constraint(equalTo: textField.firstBaselineAnchor),

            textField.leadingAnchor.constraint(equalTo: speakerButton.trailingAnchor, constant: Theme.Spacing.medium),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.large),
            textField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ segment: Segment, textWidth: CGFloat, canName: Bool, onName: @escaping () -> Void) {
        self.onName = canName ? onName : nil
        timeField.stringValue = segment.timestamp
        speakerButton.title = segment.displaySpeaker
        speakerButton.contentTintColor = Self.nsColor(for: segment)
        speakerButton.toolTip = canName ? "Click to name this speaker" : nil
        textField.stringValue = segment.text
        textField.preferredMaxLayoutWidth = textWidth
        textField.textColor = segment.confirmed ? .labelColor : .secondaryLabelColor
        alphaValue = segment.confirmed ? 1 : 0.6
    }

    @objc private func nameSpeaker() {
        onName?()
    }

    private static func nsColor(for segment: Segment) -> NSColor {
        if let id = segment.speakerId {
            let palette: [NSColor] = [.systemGreen, .systemOrange, .systemPurple, .systemPink,
                                      .systemTeal, .systemIndigo, .systemBrown, .systemCyan]
            return palette[abs(id.hashValue) % palette.count]
        }
        switch segment.track {
        case .me: return .controlAccentColor
        case .remote: return .systemGreen
        }
    }
}
