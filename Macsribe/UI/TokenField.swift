import SwiftUI
import AppKit

/// Multi-value attendee field (NSTokenField): chips with native substring
/// completion against the known people list. New names are allowed (free text).
struct TokenField: NSViewRepresentable {
    @Binding var tokens: [String]
    var completions: [String]
    var placeholder: String
    /// Called when an unknown name is committed — lets the caller open a
    /// "new contact" form instead of adding a bare token.
    var onCreateNew: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.tokenStyle = .rounded
        field.objectValue = tokens
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        // Never reassign objectValue while the user is actively editing: doing so
        // ends the field editor and commits the currently-highlighted completion as
        // a token. During a live recording, segment updates re-render this view
        // constantly, so without this guard each re-render hijacks the in-progress
        // keystroke (the reported "random attendee got added" bug).
        if field.currentEditor() != nil { return }
        let current = (field.objectValue as? [String]) ?? []
        if current != tokens { field.objectValue = tokens }
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TokenField
        init(_ parent: TokenField) { self.parent = parent }

        func tokenField(_ tokenField: NSTokenField,
                        completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int,
                        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let q = substring.lowercased()
            guard !q.isEmpty else { return [] }
            return parent.completions.filter { $0.lowercased().hasPrefix(q) }
        }

        /// Intercept committed tokens: keep known names, and route the first
        /// unknown name to the "new contact" form instead of adding it raw.
        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            let known = Set(parent.completions.map { $0.lowercased() })
            var keep: [Any] = []
            var firstNew: String?
            for case let s as String in tokens {
                if known.contains(s.lowercased()) {
                    keep.append(s)
                } else if firstNew == nil {
                    firstNew = s
                }
            }
            if let firstNew {
                let parent = self.parent
                DispatchQueue.main.async { parent.onCreateNew(firstNew) }
            }
            return keep
        }

        func controlTextDidChange(_ note: Notification) { sync(note) }
        func controlTextDidEndEditing(_ note: Notification) { sync(note) }

        private func sync(_ note: Notification) {
            guard let field = note.object as? NSTokenField else { return }
            let values = (field.objectValue as? [String]) ?? []
            DispatchQueue.main.async {
                if self.parent.tokens != values { self.parent.tokens = values }
            }
        }
    }
}
