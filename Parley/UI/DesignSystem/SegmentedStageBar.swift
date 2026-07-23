import SwiftUI

// MARK: - SegmentedStageBar
//
// A five-segment progress bar representing the post-meeting processing pipeline:
// Mix → Transcribe & diarize → Attribute → Compact → Summarize.
//
// Visual constants are derived from the approved mockup at docs/mockups/progress-bar.html.
// All other values (colors, spacing, motion) use Theme tokens only.
//
// Placement: regular variant = Record-screen strip + History detail pane;
// mini variant = History row underline (no label row).

// MARK: Bar geometry constants (from docs/mockups/progress-bar.html)
private let barHeightRegular: CGFloat = 16   // --bar-h
private let barHeightMini: CGFloat    = 5    // --bar-mini-h
private let barCornerRegular: CGFloat = 3    // outer clip corner radius
private let barCornerMini: CGFloat    = 1    // outer clip corner radius (mini)
private let segmentGap: CGFloat       = Theme.Spacing.xxSmall   // 2pt gaps between segments

// MARK: -

/// A segmented stage progress bar for the post-meeting pipeline.
///
/// Render a `SegmentedStageBar` whenever a `StageBarModel` is non-nil; the model
/// already has the correct `segments`, `statusLabel`, and `sublabel` resolved from
/// the live service state.
struct SegmentedStageBar: View {

    // MARK: Types

    enum SegmentState: Equatable {
        case pending
        case running(fraction: Double?)   // nil → indeterminate shimmer
        case done
        case failed
    }

    struct Segment: Identifiable, Equatable {
        /// Stable segment identifier: "mix", "transcribeDiarize", "attribute", "compact", "summarize".
        let id: String
        /// Human-readable tooltip / accessibility label.
        let label: String
        var state: SegmentState
    }

    enum Style {
        case regular   // 16pt bar + caption label row
        case mini      // 5pt bar, no labels (History row underline)
    }

    // MARK: Inputs

    let segments: [Segment]
    var style: Style = .regular
    /// Primary status text: e.g. "Transcribing & detecting speakers — 52%".
    /// Omit (nil) to hide the row; the row is always omitted in `.mini` style.
    var statusLabel: String? = nil
    /// Supporting detail: e.g. "transcribe 52% · speakers 74%" or "Writing Key Topics…".
    var sublabel: String? = nil

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            barRow
            if style == .regular {
                labelRow
            }
        }
        .animation(Theme.Motion.gentle, value: segments)
    }

    // MARK: Bar

    private var barHeight: CGFloat {
        style == .mini ? barHeightMini : barHeightRegular
    }

    private var cornerRadius: CGFloat {
        style == .mini ? barCornerMini : barCornerRegular
    }

    private var barRow: some View {
        // Equal-width segments with 2pt gaps, all clipped to a single outer rounded rect.
        HStack(spacing: segmentGap) {
            ForEach(segments) { segment in
                SegmentView(segment: segment, height: barHeight)
            }
        }
        .frame(height: barHeight)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityBarLabel)
        .accessibilityValue(accessibilityBarValue)
    }

    // MARK: Label row (regular only)

    @ViewBuilder
    private var labelRow: some View {
        if let status = statusLabel {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(status)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let sub = sublabel {
                    Text(sub)
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: Accessibility

    private var accessibilityBarLabel: String {
        let runningIndex = segments.firstIndex { if case .running = $0.state { return true }; return false }
        let stage = runningIndex.map { $0 + 1 } ?? doneCount
        return "Processing, stage \(stage) of \(segments.count)"
    }

    private var accessibilityBarValue: String {
        // Describe the running segment's fraction if available.
        for seg in segments {
            if case .running(let fraction) = seg.state {
                if let f = fraction {
                    return "\(Int((f * 100).rounded())) percent"
                }
                return "in progress"
            }
        }
        if segments.allSatisfy({ $0.state == .done }) { return "complete" }
        return statusLabel ?? ""
    }

    private var doneCount: Int {
        segments.filter { $0.state == .done }.count
    }
}

// MARK: - SegmentView
//
// One segment slot: renders a track background, a fill overlay for `.running`, and
// an indeterminate shimmer for `.running(fraction: nil)`. The accessibility+tooltip
// surface is per-segment.

private struct SegmentView: View {
    let segment: SegmentedStageBar.Segment
    let height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            trackBackground
            switch segment.state {
            case .pending:
                EmptyView()
            case .running(let fraction):
                if let f = fraction {
                    // Determinate: accent fill sized to fraction.
                    GeometryReader { geo in
                        Theme.Palette.accent
                            .frame(width: geo.size.width * f)
                    }
                } else {
                    // Indeterminate: shimmer sweep (or static fill under Reduce Motion).
                    IndeterminateFill(reduceMotion: reduceMotion)
                }
            case .done:
                EmptyView()
            case .failed:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .help(segment.label)
    }

    @ViewBuilder
    private var trackBackground: some View {
        switch segment.state {
        case .pending, .running:
            // Semantic track fill: divider color reads correctly in both Tahoe and Cursor
            // looks, matching the --track CSS variable in docs/mockups/progress-bar.html.
            Theme.Palette.divider
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done:
            Theme.Palette.accent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            Theme.Severity.danger.color
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - IndeterminateFill
//
// Shimmer: a gradient band sweeping left-to-right over the accent track.
// Under Reduce Motion: a static accent fill at tintFill opacity.

private struct IndeterminateFill: View {
    let reduceMotion: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        if reduceMotion {
            Theme.Palette.accent.opacity(Theme.Opacity.tintFill)
        } else {
            GeometryReader { geo in
                let w = geo.size.width
                // Gradient band: transparent–accent–transparent, 40% of the segment wide.
                LinearGradient(
                    stops: [
                        .init(color: .clear,                         location: 0.0),
                        .init(color: Theme.Palette.accent.opacity(0.85), location: 0.5),
                        .init(color: .clear,                         location: 1.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                // Band is 60% of the slot wide; it sweeps from -60% to +100% → full sweep.
                .frame(width: w * 0.6)
                .offset(x: phase * w * 1.6 - w * 0.6)
            }
            .clipped()
            .onAppear {
                withAnimation(
                    .linear(duration: 1.2).repeatForever(autoreverses: false)
                ) {
                    phase = 1
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Stage bar — all states") {
    let stages: [(String, String)] = [
        ("mix",              "Building clean mix"),
        ("transcribeDiarize","Transcribe & detect speakers"),
        ("attribute",        "Attributing words to speakers"),
        ("compact",          "Compacting audio"),
        ("summarize",        "Summarizing"),
    ]

    func makeSegments(_ runIndex: Int, fraction: Double? = nil,
                      failed failIndex: Int? = nil) -> [SegmentedStageBar.Segment] {
        stages.enumerated().map { i, pair in
            let (id, label) = pair
            let state: SegmentedStageBar.SegmentState
            if let fi = failIndex, i == fi { state = .failed }
            else if i < runIndex                { state = .done }
            else if i == runIndex               { state = .running(fraction: fraction) }
            else                                { state = .pending }
            return SegmentedStageBar.Segment(id: id, label: label, state: state)
        }
    }

    func allDone() -> [SegmentedStageBar.Segment] {
        stages.map { SegmentedStageBar.Segment(id: $0.0, label: $0.1, state: .done) }
    }

    func allPending() -> [SegmentedStageBar.Segment] {
        stages.map { SegmentedStageBar.Segment(id: $0.0, label: $0.1, state: .pending) }
    }

    return ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {

            Text("Regular").font(Theme.Typography.sectionHeader)

            SegmentedStageBar(
                segments: allPending(),
                style: .regular,
                statusLabel: "Queued — runs when idle")

            SegmentedStageBar(
                segments: makeSegments(1, fraction: 0.52),
                style: .regular,
                statusLabel: "Transcribing & detecting speakers — 52%",
                sublabel: "transcribe 52% · speakers 74%")

            SegmentedStageBar(
                segments: makeSegments(2, fraction: nil),
                style: .regular,
                statusLabel: "Attributing words to speakers")

            SegmentedStageBar(
                segments: makeSegments(3, fraction: 0.80),
                style: .regular,
                statusLabel: "Compacting audio — 80%")

            SegmentedStageBar(
                segments: makeSegments(4, fraction: nil),
                style: .regular,
                statusLabel: "Summarizing with Composer 2.5 → Cursor Grok 4.5",
                sublabel: "Writer is drafting…")

            SegmentedStageBar(
                segments: makeSegments(0, failed: 1),
                style: .regular,
                statusLabel: "Speaker detection failed — audio unreadable")

            SegmentedStageBar(
                segments: allDone(),
                style: .regular,
                statusLabel: "Complete")

            Divider()

            Text("Mini").font(Theme.Typography.sectionHeader)

            SegmentedStageBar(segments: makeSegments(1, fraction: 0.52), style: .mini)
            SegmentedStageBar(segments: allPending(), style: .mini)
            SegmentedStageBar(segments: makeSegments(0, failed: 1), style: .mini)
        }
        .padding(Theme.Spacing.large)
    }
    .frame(width: 400)
}
