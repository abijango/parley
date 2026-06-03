import SwiftUI

/// Form for adding a new contact (name + title + company + LinkedIn) that gets
/// written to the rolodex. Presented when an unknown attendee name is committed.
struct NewPersonSheet: View {
    let onAdd: (_ name: String, _ title: String, _ company: String, _ linkedin: String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var title = ""
    @State private var company: String
    @State private var linkedin = ""
    @FocusState private var titleFocused: Bool

    init(initialName: String,
         defaultCompany: String,
         onAdd: @escaping (String, String, String, String) -> Void,
         onCancel: @escaping () -> Void) {
        self.onAdd = onAdd
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
        _company = State(initialValue: defaultCompany)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("New contact").font(Theme.Typography.sheetTitle)

            Grid(alignment: .leading,
                 horizontalSpacing: Theme.Spacing.medium,
                 verticalSpacing: Theme.Spacing.small) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("Full name", text: $name)
                }
                GridRow {
                    Text("Title").foregroundStyle(.secondary)
                    TextField("e.g. Head of Architecture", text: $title).focused($titleFocused)
                }
                GridRow {
                    Text("Company").foregroundStyle(.secondary)
                    TextField("e.g. Vanguard", text: $company)
                }
                GridRow {
                    Text("LinkedIn").foregroundStyle(.secondary)
                    TextField("https://www.linkedin.com/in/…", text: $linkedin)
                }
            }
            .textFieldStyle(.roundedBorder)

            Text("Saved to the rolodex" + (company.isEmpty ? "." : " under “\(company)”."))
                .font(Theme.Typography.captionSecondary).foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .glassButton()
                    .keyboardShortcut(.cancelAction)
                Button("Add") { onAdd(trimmed(name), trimmed(title), trimmed(company), trimmed(linkedin)) }
                    .glassProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed(name).isEmpty)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 380)
        .onAppear { titleFocused = true }   // name is prefilled; jump to Title
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
