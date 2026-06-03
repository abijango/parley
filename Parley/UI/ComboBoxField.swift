import SwiftUI
import AppKit

/// Editable combo box (NSComboBox) with native inline autocompletion + a
/// dropdown of known values. Free text is allowed (for new customers).
struct ComboBoxField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var items: [String]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.completes = true
        combo.usesDataSource = false
        combo.delegate = context.coordinator
        combo.placeholderString = placeholder
        combo.addItems(withObjectValues: items)
        combo.stringValue = text
        return combo
    }

    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if combo.stringValue != text { combo.stringValue = text }
        let current = (combo.objectValues as? [String]) ?? []
        if current != items {
            combo.removeAllItems()
            combo.addItems(withObjectValues: items)
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ComboBoxField
        init(_ parent: ComboBoxField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let combo = note.object as? NSComboBox else { return }
            parent.text = combo.stringValue
        }

        func comboBoxSelectionDidChange(_ note: Notification) {
            guard let combo = note.object as? NSComboBox else { return }
            let index = combo.indexOfSelectedItem
            guard index >= 0, index < parent.items.count else { return }
            let value = parent.items[index]
            DispatchQueue.main.async { self.parent.text = value }
        }
    }
}
