#if DEBUG
import SwiftUI

/// A non-shipping gallery that exercises every design-system token and component,
/// so the system compiles and can be reviewed in Xcode previews in isolation —
/// without touching any real screen. Wrapped in `#if DEBUG`; never built into
/// Release.
private struct DesignSystemGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {

                section("Type roles") {
                    Text("Screen title").font(Theme.Typography.screenTitle)
                    Text("Sheet title").font(Theme.Typography.sheetTitle)
                    Text("Section header").font(Theme.Typography.sectionHeader)
                    Text("Body text").font(Theme.Typography.body)
                    Text("Field label").font(Theme.Typography.fieldLabel).foregroundStyle(.secondary)
                    Text("Secondary").font(Theme.Typography.secondary).foregroundStyle(.secondary)
                    Text("Caption").font(Theme.Typography.caption).foregroundStyle(.secondary)
                    Text("Reading — transcript & notes (New York serif)").font(Theme.Typography.reading)
                    Text("00:42 · path/to/file").font(Theme.Typography.mono).foregroundStyle(.tertiary)
                }

                section("Buttons") {
                    HStack(spacing: Theme.Spacing.medium) {
                        Button("Secondary") {}.glassButton()
                        Button("Primary") {}.glassProminentButton()
                    }
                    VStack(spacing: Theme.Spacing.xxSmall) {
                        Button { } label: { Label("Record", systemImage: "record.circle") }
                            .buttonStyle(.row())
                        Button { } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                            .buttonStyle(.row(selected: true))
                    }
                }

                section("Status banners") {
                    StatusBanner(.info, "A neutral, informational note.")
                    StatusBanner(.success, "Notes ready.")
                    StatusBanner(.warning, "Speakers aren't assigned yet.")
                    StatusBanner(.danger, "Microphone access is off.",
                                 actionLabel: "Open Settings") {}
                }

                section("Badges") {
                    HStack(spacing: Theme.Spacing.small) {
                        StatusBadge("Review", severity: .info)
                        StatusBadge("Processed", severity: .success)
                        StatusBadge("Unprocessed", severity: .warning)
                        CountBadge(count: 3)
                    }
                }

                section("Empty state") {
                    EmptyStateView(icon: "text.bubble",
                                   title: "Start recording",
                                   detail: "Your live transcript will appear here as people speak.")
                        .frame(height: 220)
                }

                section("Surfaces") {
                    Text("Card surface")
                        .padding(Theme.Spacing.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                    Text("Glass surface (Liquid Glass)")
                        .padding(Theme.Spacing.medium)
                        .glassSurface(in: Theme.Radius.rect(Theme.Radius.medium))
                    SectionHeader("Section header component",
                                  caption: "With an optional secondary caption line.")
                }
            }
            .padding(Theme.Spacing.large)
        }
        .frame(width: 440, height: 760)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(title.uppercased())
                .font(Theme.Typography.captionSecondary)
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Design System — Light") {
    DesignSystemGallery().preferredColorScheme(.light)
}

#Preview("Design System — Dark") {
    DesignSystemGallery().preferredColorScheme(.dark)
}
#endif
