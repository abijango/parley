import SwiftUI

/// A wrapping stack: lays subviews left-to-right and wraps to a new row when the row
/// width is exceeded. Pure and stateless.
///
/// `maxWidth` is passed explicitly (measured by the caller via a `GeometryReader`) and
/// used by BOTH `sizeThatFits` and `placeSubviews`, so the reported height always matches
/// the placement — the bug class where a `Layout` answers a one-row height for an
/// unconstrained proposal and then lays out many rows (chips overflowing their box). When
/// `maxWidth <= 0` (not measured yet, first frame) it falls back to the proposed width.
struct FlowLayout: Layout {
    var maxWidth: CGFloat = 0
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = wrapWidth(proposal.width)
        // Fail SAFE TALL: when the width is genuinely unknown (no measured `maxWidth`
        // and an unbounded proposal), reserve the worst case — every subview on its
        // own row — so the reported height is never LESS than what `placeSubviews`
        // draws at a finite bounds width. Under-reporting here is the chips-overflow-
        // the-box bug; over-reporting just leaves transient slack that collapses the
        // moment the real width is measured (one frame later).
        if width == .greatestFiniteMagnitude {
            let heights = subviews.map { $0.sizeThatFits(.unspecified).height }
            let height = heights.reduce(0, +) + rowSpacing * CGFloat(max(0, heights.count - 1))
            return CGSize(width: proposal.width ?? 0, height: height)
        }
        let rows = rows(maxWidth: width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height }
            + rowSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for row in rows(maxWidth: wrapWidth(bounds.width), subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    /// The width to wrap at: the explicit measured width when available, else the proposal.
    private func wrapWidth(_ proposed: CGFloat?) -> CGFloat {
        if maxWidth > 0 { return maxWidth }
        if let proposed, proposed.isFinite, proposed > 0 { return proposed }
        return .greatestFiniteMagnitude
    }

    // MARK: Row packing

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let lead = current.indices.isEmpty ? 0 : spacing
            if !current.indices.isEmpty, current.width + lead + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            let gap = current.indices.isEmpty ? 0 : spacing
            current.indices.append(i)
            current.width += gap + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
