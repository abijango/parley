import SwiftUI

/// Shows a unified line diff between the existing note and a re-processed
/// candidate, computed with Swift's `CollectionDifference` (`Array.difference`).
/// Added lines render green, removed lines red, context lines dimmed. Accept
/// commits the staged note over the real one; Discard deletes the staging file.
struct NoteDiffView: View {
    let existing: String
    let staged: String
    let onAccept: () -> Void
    let onDiscard: () -> Void

    private var rows: [DiffRow] { Self.diff(old: existing, new: staged) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.allSatisfy({ $0.kind == .context }) {
                noChanges
            } else {
                diffScroll
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text("Review re-processed note").font(Theme.Typography.sheetTitle)
                Text("Existing note (red) vs. new draft (green). Accept to overwrite, Discard to keep the current note.")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(Theme.Spacing.large)
    }

    private var diffScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: Theme.Spacing.small) {
                        Text(row.kind.sign)
                            .font(Theme.Typography.mono)
                            .foregroundStyle(row.kind.color)
                            .frame(width: 14, alignment: .center)
                        Text(row.text.isEmpty ? " " : row.text)
                            .font(Theme.Typography.mono)
                            .foregroundStyle(row.kind == .context ? .secondary : row.kind.color)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.vertical, 1)
                    .background(row.kind.background)
                }
            }
            .padding(.vertical, Theme.Spacing.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noChanges: some View {
        EmptyStateView(
            icon: "equal.circle",
            title: "No changes",
            detail: "The re-processed note is identical to the existing one.")
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Spacer()
            Button("Discard", role: .cancel) { onDiscard() }
                .glassButton()
                .keyboardShortcut(.cancelAction)
            Button("Accept") { onAccept() }
                .glassProminentButton()
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Spacing.large)
        .chromeSurface()
    }

    // MARK: Diff model

    private struct DiffRow: Identifiable {
        enum Kind: Equatable {
            case context, added, removed
            var sign: String { self == .added ? "+" : self == .removed ? "−" : " " }
            var color: Color {
                self == .added ? Theme.Severity.success.color
                : self == .removed ? Theme.Severity.danger.color
                : .secondary
            }
            var background: Color {
                switch self {
                case .added: return Theme.Severity.success.color.opacity(Theme.Opacity.tintSubtle)
                case .removed: return Theme.Severity.danger.color.opacity(Theme.Opacity.tintSubtle)
                case .context: return .clear
                }
            }
        }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    /// Produces an ordered unified diff from a line-level `CollectionDifference`.
    /// Removals are placed at their old index, insertions at their new index;
    /// untouched lines carry through as context.
    private static func diff(old: String, new: String) -> [DiffRow] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let difference = newLines.difference(from: oldLines)

        var removalsByOldIndex: [Int: String] = [:]
        var insertionsByNewIndex: [Int: String] = [:]
        for change in difference {
            switch change {
            case let .remove(offset, element, _): removalsByOldIndex[offset] = element
            case let .insert(offset, element, _): insertionsByNewIndex[offset] = element
            }
        }

        var rows: [DiffRow] = []
        var oldIdx = 0
        var newIdx = 0
        while oldIdx < oldLines.count || newIdx < newLines.count {
            if oldIdx < oldLines.count, removalsByOldIndex[oldIdx] != nil {
                rows.append(DiffRow(kind: .removed, text: oldLines[oldIdx]))
                oldIdx += 1
            } else if newIdx < newLines.count, insertionsByNewIndex[newIdx] != nil {
                rows.append(DiffRow(kind: .added, text: newLines[newIdx]))
                newIdx += 1
            } else if oldIdx < oldLines.count, newIdx < newLines.count {
                // Both present and unchanged at this position → context.
                rows.append(DiffRow(kind: .context, text: oldLines[oldIdx]))
                oldIdx += 1
                newIdx += 1
            } else if oldIdx < oldLines.count {
                rows.append(DiffRow(kind: .removed, text: oldLines[oldIdx]))
                oldIdx += 1
            } else {
                rows.append(DiffRow(kind: .added, text: newLines[newIdx]))
                newIdx += 1
            }
        }
        return rows
    }
}
