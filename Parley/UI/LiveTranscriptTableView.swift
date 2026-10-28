import AppKit
import Combine
import SwiftUI

/// Live transcript as an AppKit table. `sizeThatFits` returns the SwiftUI proposal so
/// row count is not a term in the window's layout pass. The coordinator observes
/// `LiveSegmentStore` directly; `[Segment]` never crosses a SwiftUI `body`.
///
/// Scrolling: at the bottom the table follows new text. Once the reader scrolls up it
/// holds their place (anchored to the top visible row, not a pixel offset) and shows
/// a "new lines" pill; scrolling back down, End, or the pill resumes following. It
/// also holds while a speaker's naming menu is open, so the tinted lines stay put.
struct LiveTranscriptTable: NSViewRepresentable {
    let store: LiveSegmentStore
    var isRecording: Bool
    /// Speaker labels open the strip's naming menu (off in batch mode).
    var canNameSpeakers: Bool
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
        table.postsFrameChangedNotifications = true
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
            canNameSpeakers: canNameSpeakers)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.applyChrome(
            isRecording: isRecording,
            liveDisabled: liveDisabled,
            hidesEmptyState: hidesEmptyState,
            canNameSpeakers: canNameSpeakers)
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
        /// Within this distance of the bottom counts as "at the latest line".
        private static let bottomSlack: CGFloat = 24

        private let store: LiveSegmentStore
        private var rows: [Segment] = []
        private var cancellables: Set<AnyCancellable> = []
        private var observers: [NSObjectProtocol] = []
        private var keyMonitor: Any?
        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private var emptyHost: NSHostingView<EmptyStateView>?
        private var pillHost: NSHostingView<NewLinesPill>?

        /// The reader is at the bottom and wants new text to scroll into view.
        private var following = true
        /// Rows added while holding position, for the pill.
        private var pendingNew = 0
        /// Top visible row and its offset from the viewport top, restored after edits.
        private var anchor: (id: UUID, offset: CGFloat)?
        private var scrollingProgrammatically = false
        private var lastClipSize: NSSize = .zero
        private var focusedSpeakerId: String?

        var isRecording = false
        var liveDisabled = false
        var hidesEmptyState = false
        var canNameSpeakers = false

        private var holding: Bool { !following || focusedSpeakerId != nil }

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

            let pill = NSHostingView(rootView: NewLinesPill(count: 0, action: {}))
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.isHidden = true
            scroll.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
                pill.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -Theme.Spacing.medium),
            ])
            pillHost = pill

            // Synchronous (queue: nil) so our own scrolls are recognised by the flag
            // they run under; a hop would judge them after the flag was cleared.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.clipBoundsChanged() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: table, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.contentResized() }
            })

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handleEndKey(event) ?? event }
            }

            store.$segments
                .sink { [weak self] new in MainActor.assumeIsolated { self?.apply(new) } }
                .store(in: &cancellables)
            store.roster.$focusedSpeakerId
                .removeDuplicates()
                .sink { [weak self] id in MainActor.assumeIsolated { self?.focusChanged(id) } }
                .store(in: &cancellables)
            lastClipSize = scroll.contentView.bounds.size
            apply(store.segments)
        }

        func applyChrome(
            isRecording: Bool,
            liveDisabled: Bool,
            hidesEmptyState: Bool,
            canNameSpeakers: Bool
        ) {
            self.isRecording = isRecording
            self.liveDisabled = liveDisabled
            self.hidesEmptyState = hidesEmptyState
            if self.canNameSpeakers != canNameSpeakers {
                self.canNameSpeakers = canNameSpeakers
                if let table = tableView, table.numberOfRows > 0 {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows),
                                     columnIndexes: IndexSet(integer: 0))
                }
            }
            refreshEmpty()
        }

        func teardown() {
            cancellables.removeAll()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("line")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? LiveTranscriptRowView
                ?? LiveTranscriptRowView()
            cell.identifier = id
            let segment = rows[row]
            let canName = segment.speakerId != nil && canNameSpeakers
            cell.apply(segment, textWidth: Self.textWidth(in: tableView), canName: canName) { [weak self] in
                self?.store.roster.menuRequest = segment.speakerId
            }
            cell.setHighlighted(focusedSpeakerId != nil && segment.speakerId == focusedSpeakerId)
            return cell
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table = tableView, table.numberOfRows > 0 else { return }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        }

        // MARK: Edits

        private func apply(_ new: [Segment]) {
            guard let table = tableView else {
                rows = new
                return
            }
            if holding, anchor == nil { recordAnchor() }
            let edit = LiveTranscriptTableDiff.edit(from: rows, to: new)
            rows = new
            switch edit {
            case .none:
                break
            case .reloadAll:
                table.reloadData()
                pendingNew = 0
                anchor = nil
            case .update(let remove, let insert, let reload):
                table.beginUpdates()
                if !remove.isEmpty { table.removeRows(at: remove, withAnimation: []) }
                if !insert.isEmpty { table.insertRows(at: insert, withAnimation: []) }
                table.endUpdates()
                if !reload.isEmpty {
                    table.reloadData(forRowIndexes: reload, columnIndexes: IndexSet(integer: 0))
                    table.noteHeightOfRows(withIndexesChanged: reload)
                }
                if holding { pendingNew += max(0, insert.count - remove.count) }
            }
            refreshEmpty()
            settlePosition()
            refreshPill()
        }

        private func refreshEmpty() {
            let show = rows.isEmpty && !hidesEmptyState
            emptyHost?.rootView = Self.emptyView(isRecording: isRecording, liveDisabled: liveDisabled)
            emptyHost?.isHidden = !show
        }

        // MARK: Scrolling

        /// After content changed: stick to the bottom, or put the reader's line back.
        private func settlePosition() {
            if holding { restoreAnchor() } else { scrollToBottom() }
        }

        private func contentResized() {
            guard !scrollingProgrammatically else { return }
            settlePosition()
        }

        private func clipBoundsChanged() {
            guard !scrollingProgrammatically, let clip = scrollView?.contentView else { return }
            // A viewport resize (window or split drag) is not the reader scrolling.
            if clip.bounds.size != lastClipSize {
                lastClipSize = clip.bounds.size
                settlePosition()
                return
            }
            following = isAtBottom
            if following { pendingNew = 0 }
            recordAnchor()
            refreshPill()
        }

        private var isAtBottom: Bool {
            guard let clip = scrollView?.contentView, let table = tableView else { return true }
            return table.frame.height - clip.bounds.maxY <= Self.bottomSlack
        }

        private func scrollToBottom() {
            guard let clip = scrollView?.contentView, let table = tableView else { return }
            scroll(toY: table.frame.height - clip.bounds.height)
            pendingNew = 0
        }

        private func recordAnchor() {
            guard let clip = scrollView?.contentView, let table = tableView else { return }
            let visible = table.rows(in: clip.bounds)
            guard visible.length > 0, rows.indices.contains(visible.location) else {
                anchor = nil
                return
            }
            let row = visible.location
            anchor = (rows[row].id, table.rect(ofRow: row).minY - clip.bounds.minY)
        }

        private func restoreAnchor() {
            guard let table = tableView, let anchor else { return }
            guard let row = rows.firstIndex(where: { $0.id == anchor.id }) else {
                recordAnchor()
                return
            }
            scroll(toY: table.rect(ofRow: row).minY - anchor.offset)
        }

        private func scroll(toY y: CGFloat) {
            guard let scroll = scrollView, let table = tableView else { return }
            let clip = scroll.contentView
            let target = min(max(0, y), max(0, table.frame.height - clip.bounds.height))
            guard abs(clip.bounds.origin.y - target) > 0.5 else { return }
            scrollingProgrammatically = true
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
            scroll.reflectScrolledClipView(clip)
            scrollingProgrammatically = false
        }

        private func jumpToLatest() {
            following = true
            anchor = nil
            if focusedSpeakerId != nil { store.roster.focusedSpeakerId = nil }
            scrollToBottom()
            refreshPill()
        }

        /// End (fn-→ on laptops) jumps to the latest line, unless someone is typing.
        private func handleEndKey(_ event: NSEvent) -> NSEvent? {
            let kVKEnd: UInt16 = 119
            guard event.keyCode == kVKEnd, !rows.isEmpty,
                  let window = scrollView?.window, event.window === window,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            else { return event }
            if let editor = window.firstResponder as? NSTextView, editor.isEditable { return event }
            jumpToLatest()
            return nil
        }

        private func refreshPill() {
            guard let pill = pillHost else { return }
            let show = !rows.isEmpty && (!following || (focusedSpeakerId != nil && pendingNew > 0))
            if show {
                pill.rootView = NewLinesPill(count: pendingNew) { [weak self] in self?.jumpToLatest() }
            }
            pill.isHidden = !show
        }

        // MARK: Speaker focus

        private func focusChanged(_ id: String?) {
            if id != nil, focusedSpeakerId == nil { recordAnchor() }
            focusedSpeakerId = id
            tableView?.enumerateAvailableRowViews { rowView, row in
                guard let cell = rowView.view(atColumn: 0) as? LiveTranscriptRowView,
                      self.rows.indices.contains(row) else { return }
                cell.setHighlighted(id != nil && self.rows[row].speakerId == id)
            }
            if id == nil, following {
                anchor = nil
                scrollToBottom()
            }
            refreshPill()
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

/// Floating "↓ N new lines" control shown while the transcript holds the reader's place.
struct NewLinesPill: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(count > 0 ? "\(count) new line\(count == 1 ? "" : "s")" : "Jump to latest",
                  systemImage: "arrow.down")
                .font(Theme.Typography.secondary.weight(.medium))
                .monospacedDigit()
        }
        .glassProminentButton()
        .elevation(Theme.Shadow.floating)
        .help("Jump to the latest line (End)")
        .accessibilityLabel(count > 0 ? "\(count) new lines, jump to latest" : "Jump to latest")
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
        speakerButton.font = BrandFont.nsSans(12, .semibold)
        speakerButton.alignment = .left
        speakerButton.lineBreakMode = .byTruncatingTail
        speakerButton.translatesAutoresizingMaskIntoConstraints = false
        speakerButton.target = self
        speakerButton.action = #selector(nameSpeaker)
        speakerButton.setContentHuggingPriority(.required, for: .horizontal)
        speakerButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        textField.font = BrandFont.nsSans(15)
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

    /// Tint for the speaker whose naming menu is open.
    func setHighlighted(_ on: Bool) {
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.small
        layer?.backgroundColor = on
            ? speakerButton.contentTintColor?.withAlphaComponent(Theme.Opacity.tintFill).cgColor
            : nil
    }

    func apply(_ segment: Segment, textWidth: CGFloat, canName: Bool, onName: @escaping () -> Void) {
        self.onName = canName ? onName : nil
        timeField.stringValue = segment.timestamp
        speakerButton.title = segment.displaySpeaker
        speakerButton.contentTintColor = Self.nsColor(for: segment)
        speakerButton.toolTip = canName ? "Name this speaker" : nil
        textField.stringValue = segment.text
        textField.preferredMaxLayoutWidth = textWidth
        textField.textColor = segment.confirmed ? .labelColor : .secondaryLabelColor
        alphaValue = segment.confirmed ? 1 : 0.6
    }

    @objc private func nameSpeaker() {
        onName?()
    }

    private static func nsColor(for segment: Segment) -> NSColor {
        if let id = segment.speakerId { return SpeakerPalette.nsColor(for: id) }
        switch segment.track {
        case .me: return .controlAccentColor
        case .remote: return .systemGreen
        }
    }
}
