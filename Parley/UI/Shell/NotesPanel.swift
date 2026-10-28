import SwiftUI
import AppKit

/// The right-hand notes panel of the shell: a resizable rail of stacked, collapsible
/// sections (My notes / Details / Summary). Shared by the live screen and the note
/// detail so both read and resize the same way. Width is view-local presentation state
/// (UserDefaults), and visibility is toggled from the window toolbar.
struct NotesPanel<Content: View>: View {
    /// UserDefaults key for the panel's visibility (toolbar toggle).
    static var visibleKey: String { "parley.notesPanelVisible" }

    @AppStorage("parley.inspectorWidth") private var width: Double = 340
    @State private var dragBaseWidth: Double?
    private static var widthRange: ClosedRange<Double> { 280...440 }
    private static var defaultWidth: Double { 340 }

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            resizeDivider
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .chromeSurface()
        }
    }

    /// The hairline between center and panel, doubled as a resize handle: a slim
    /// transparent grab area straddles it, shows the resize cursor on hover, and drags
    /// the width within range. Dragging left widens the panel; double-click resets.
    private var resizeDivider: some View {
        Divider()
            .ignoresSafeArea(.container, edges: .top)   // continue under the toolbar
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
                                if dragBaseWidth == nil { dragBaseWidth = width }
                                let proposed = (dragBaseWidth ?? width) - value.translation.width
                                width = min(max(proposed, Self.widthRange.lowerBound),
                                            Self.widthRange.upperBound)
                            }
                            .onEnded { _ in dragBaseWidth = nil }
                    )
                    .onTapGesture(count: 2) { width = Self.defaultWidth }
            }
    }
}

/// One collapsible section of the notes panel: a quiet header row with a chevron,
/// then its content. `fills` lets an expanded section take the panel's remaining
/// height (the notes editor, the summary preview).
struct NotesPanelSection<Content: View>: View {
    let title: String
    let symbol: String
    @Binding var isExpanded: Bool
    var fills = false
    private let content: Content

    init(_ title: String, symbol: String, isExpanded: Binding<Bool>, fills: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self._isExpanded = isExpanded
        self.fills = fills
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Button {
                withAnimation(Theme.Motion.quick) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: symbol)
                        .frame(width: 18)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Text(title)
                        .font(Theme.Typography.controlLabel)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
                    .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .frame(maxHeight: fills && isExpanded ? .infinity : nil, alignment: .top)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Palette.divider).frame(height: 0.5)
        }
    }
}

/// Toolbar button that shows/hides the notes panel (the right-hand twin of the
/// sidebar toggle).
struct NotesPanelToggle: View {
    @AppStorage(NotesPanel<EmptyView>.visibleKey) private var visible = true

    var body: some View {
        Button {
            withAnimation(Theme.Motion.quick) { visible.toggle() }
        } label: {
            Image(systemName: "sidebar.right")
        }
        .help(visible ? "Hide notes panel" : "Show notes panel")
    }
}
