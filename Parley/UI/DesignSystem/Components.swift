import SwiftUI

// MARK: - Shared presentation components
//
// Small, reusable views built from the tokens. They consolidate patterns the audit
// found hand-rolled in several places. They are defined here for views to adopt in
// Phase 2+ — no existing screen is wired to them yet.

/// A standardized status / advisory strip: a tinted, rounded surface with a leading
/// icon, a message, and an optional trailing action. Consolidates the separate
/// advisory-banner / error-row / summary-status banners catalogued in the audit.
///
/// Example:
/// `StatusBanner(.danger, "Microphone access is off.", actionLabel: "Open Settings", action: …)`
struct StatusBanner: View {
    let severity: Theme.Severity
    let message: String
    var symbol: String? = nil
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    init(_ severity: Theme.Severity,
         _ message: String,
         symbol: String? = nil,
         actionLabel: String? = nil,
         action: (() -> Void)? = nil) {
        self.severity = severity
        self.message = message
        self.symbol = symbol
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: symbol ?? severity.symbol)
                .foregroundStyle(severity.color)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .font(Theme.Typography.caption)
            }
        }
        .padding(Theme.Spacing.small)
        .background(severity.color.opacity(Theme.Opacity.tintSubtle),
                    in: Theme.Radius.rect(Theme.Radius.medium))
    }
}

/// A thin horizontal input-level meter: a labeled track whose fill is proportional
/// to `level` (0…1). Uses the accent color normally and the danger color when
/// `warn` is set (e.g. a mic that has gone silent mid-call).
struct InputLevelBar: View {
    let label: String
    let level: Float
    var warn: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(warn ? Theme.Severity.danger.color : Color.accentColor)
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, level)))))
                }
            }
            .frame(height: 4)
            .animation(.linear(duration: 0.08), value: level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(warn ? "silent" : "\(Int(min(1, max(0, level)) * 100)) percent")
    }
}

/// A small capsule status badge (e.g. Review / Processed / Unprocessed, or a count).
/// Consolidates the History status badge and the sidebar count badge.
struct StatusBadge: View {
    let label: String
    let severity: Theme.Severity

    init(_ label: String, severity: Theme.Severity) {
        self.label = label
        self.severity = severity
    }

    var body: some View {
        Text(label)
            .font(.caption2).bold()
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.xxSmall)
            .background(severity.color.opacity(Theme.Opacity.tintFill), in: Capsule())
            .foregroundStyle(severity.color)
    }
}

/// A pane-level section header: a consistently styled title with optional caption,
/// for the settings tabs and grouped content. (Role token: `sectionHeader`.)
struct SectionHeader: View {
    let title: String
    var caption: String? = nil

    init(_ title: String, caption: String? = nil) {
        self.title = title
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text(title).font(Theme.Typography.sectionHeader)
            if let caption {
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A settings row in the Cursor idiom: a title with an optional secondary
/// description on the leading edge, and its control (toggle / picker / button)
/// trailing. Consolidates the old "Toggle + separate helpText below" pattern into
/// one cohesive, consistently-spaced row. Built on `LabeledContent` so it adopts the
/// grouped-Form card chrome and stays aligned with native rows. Theme-driven, so it
/// reads correctly in both the Native and Cursor looks.
///
/// Example:
/// `SettingRow("Menu bar icon", description: "Show Parley in the menu bar") { Toggle("", isOn: $x).labelsHidden() }`
struct SettingRow<Control: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder var control: () -> Control

    init(_ title: String, description: String? = nil,
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.description = description
        self.control = control
    }

    var body: some View {
        LabeledContent {
            control()
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(title).font(Theme.Typography.body)
                if let description {
                    Text(description)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxSmall)
    }
}

/// A solid count / notification badge for navigation items (e.g. a sidebar item
/// count of things needing attention). Distinct from `StatusBadge` (a *tinted*
/// status label) — this is a filled accent pill, the conventional count treatment.
struct CountBadge: View {
    let count: Int

    init(count: Int) { self.count = count }

    var body: some View {
        Text("\(count)")
            .font(.caption2).bold().monospacedDigit()
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.xxSmall)
            .background(Theme.Palette.accent, in: Capsule())
            .foregroundStyle(.white)
    }
}

/// Canonical empty / placeholder state: an icon in a soft accent disc, a bold title,
/// an optional supporting line, and an optional primary action. Three clear tiers so
/// the state reads as "ready" rather than "nothing here". Set `animateIcon` for a
/// subtle, purposeful icon animation (e.g. a live "Listening…" waveform). Omit the
/// action when a persistent primary control already exists on screen.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var animateIcon: Bool = false
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    init(icon: String, title: String, detail: String? = nil, animateIcon: Bool = false,
         actionLabel: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.animateIcon = animateIcon
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Palette.accent)
                .symbolEffect(.variableColor.iterative.reversing, isActive: animateIcon)
                .frame(width: 76, height: 76)
                .background(Theme.Palette.accent.opacity(Theme.Opacity.tintFill), in: Circle())

            VStack(spacing: Theme.Spacing.xSmall) {
                Text(title)
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .glassProminentButton()
                    .padding(.top, Theme.Spacing.xSmall)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xLarge)
    }
}
