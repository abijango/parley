import Foundation

/// Incremental table mutation derived from two timeline snapshots.
///
/// The engine still publishes a full `[Segment]` array. This is the structure that
/// recovers the actual event (tail revision, confirm+append, identity churn) so
/// `NSTableView` never has to `reloadData()` on a 1 Hz tick.
enum LiveTranscriptTableEdit: Equatable {
    case none
    case reloadAll
    case append(IndexSet)
    case reload(IndexSet)
    case reloadAndAppend(reload: IndexSet, append: IndexSet)
}

enum LiveTranscriptTableDiff {
    static func edit(from old: [Segment], to new: [Segment]) -> LiveTranscriptTableEdit {
        if old.isEmpty {
            return new.isEmpty ? .none : .reloadAll
        }
        if new.isEmpty { return .reloadAll }

        if new.count == old.count, zip(old, new).allSatisfy({ $0.0.id == $0.1.id }) {
            let changed = IndexSet(old.indices.filter { old[$0] != new[$0] })
            return changed.isEmpty ? .none : .reload(changed)
        }

        if new.count > old.count {
            let prefix = old.count
            if zip(old, new.prefix(prefix)).allSatisfy({ $0.0.id == $0.1.id }) {
                let reload = IndexSet(old.indices.filter { old[$0] != new[$0] })
                let append = IndexSet(integersIn: prefix..<new.count)
                if reload.isEmpty { return .append(append) }
                return .reloadAndAppend(reload: reload, append: append)
            }
        }

        return .reloadAll
    }
}
