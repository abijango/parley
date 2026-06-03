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
        // Don't reassign objectValue while there's UNCOMMITTED text in the field
        // editor: doing so ends editing and commits the highlighted completion as a
        // token (the "random attendee got added" bug during live re-renders). But a
        // merely-focused, idle field (empty editor) must still accept programmatic
        // updates — e.g. auto-identified speakers being added to attendees — so guard
        // on in-progress text, not on focus alone.
        if let editor = field.currentEditor(), !editor.string.isEmpty { return }
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

        /// Intercept committed tokens: keep names that are either a known contact
        /// or already in the bound model, and route the first genuinely-new
        /// (user-typed) name to the "new contact" form instead of adding it raw.
        /// This also fires when the field re-tokenizes its programmatically-set
        /// value, so an auto-identified speaker (a voiceprint name, not yet a vault
        /// contact) must not be dropped just because it isn't in the completions.
        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            let known = Set(parent.completions.map { $0.lowercased() })
            let existing = Set(parent.tokens.map { $0.lowercased() })
            var keep: [Any] = []
            var firstNew: String?
            for case let s as String in tokens {
                let key = s.lowercased()
                if known.contains(key) || existing.contains(key) {
                    keep.append(s)                       // known contact, or already an attendee
                } else if firstNew == nil {
                    firstNew = s                         // first new user-typed name → new-contact form
                } else {
                    keep.append(s)                       // don't silently drop further new names
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
