import Foundation

/// Incremental table mutation derived from two timeline snapshots.
///
/// The engine still publishes a full `[Segment]` array. This recovers the actual
/// event — rows inserted or removed by id, rows whose content changed in place — so
/// `NSTableView` keeps measured row heights and the reader's scroll position instead
/// of `reloadData()`-ing whenever diarization re-splits the open tail.
enum LiveTranscriptTableEdit: Equatable {
    case none
    case reloadAll
    /// `remove` indexes the old rows, `insert` the new rows (NSTableView's
    /// begin/endUpdates semantics); `reload` indexes the new rows.
    case update(remove: IndexSet, insert: IndexSet, reload: IndexSet)
}

enum LiveTranscriptTableDiff {
    static func edit(from old: [Segment], to new: [Segment]) -> LiveTranscriptTableEdit {
        if old.isEmpty {
            return new.isEmpty ? .none : .reloadAll
        }
        if new.isEmpty { return .reloadAll }

        let diff = new.map(\.id).difference(from: old.map(\.id))
        var remove = IndexSet()
        var insert = IndexSet()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): remove.insert(offset)
            case .insert(let offset, _, _): insert.insert(offset)
            }
        }
        // Nothing survived: a reset, not an edit.
        if remove.count == old.count { return .reloadAll }

        let oldById = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let reload = IndexSet(new.indices.filter { i in
            !insert.contains(i) && oldById[new[i].id].map { $0 != new[i] } == true
        })
        if remove.isEmpty, insert.isEmpty, reload.isEmpty { return .none }
        return .update(remove: remove, insert: insert, reload: reload)
    }
}
