import SwiftUI

/// The app's segmented control (Claude-app style): an inset track with the selected
/// option on a raised white pill that slides between options. Use in place of
/// `.pickerStyle(.segmented)` for in-window switches (Preview / Edit, capture modes).
///
///     PillPicker(selection: $mode, options: Mode.allCases) { Text($0.label) }
struct PillPicker<Value: Hashable, Label: View>: View {
    @Binding var selection: Value
    let options: [Value]
    /// Stretch options to fill the available width (otherwise each hugs its label).
    var fillsWidth = false
    @ViewBuilder let label: (Value) -> Label

    @Environment(\.isEnabled) private var isEnabled
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(Theme.Motion.spring) { selection = option }
                } label: {
                    label(option)
                        .font(Theme.Typography.caption.weight(selected ? .medium : .regular))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Spacing.medium)
                        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 24)
                        .background {
                            if selected {
                                Theme.Radius.rect(Theme.Radius.small - 2)
                                    .fill(Theme.Palette.panelBg)
                                    .overlay(Theme.Radius.rect(Theme.Radius.small - 2)
                                        .strokeBorder(Theme.Palette.divider, lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.Radius.rect(Theme.Radius.small).fill(Theme.Palette.selection))
        .opacity(isEnabled ? 1 : 0.5)
        .fixedSize(horizontal: !fillsWidth, vertical: true)
    }
}
