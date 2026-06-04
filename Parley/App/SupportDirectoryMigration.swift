import Foundation

/// One-time migration of the app's Application Support data across an app **rename**.
///
/// `AppPaths.supportDirectory` is keyed by `AppInfo.name`, so renaming the app
/// (Macsribe → Parley) silently repoints *every* data location — models, recordings,
/// voiceprints, summary models — at a fresh, empty directory. The old data isn't
/// deleted; it's abandoned in place under the previous name. This carries it across.
///
/// Conservative + idempotent (mirrors `VaultMigration`):
/// - Guarded by a `UserDefaults` flag, so it runs at most once.
/// - Moves only items **missing** in the new location; an item present in both is
///   kept as-is (the new location wins — never overwritten). This is what makes it
///   safe for the encrypted Speakers store: `.store-key` + `voiceprints.json` are
///   encrypted together with a name-local key, so a half-move would corrupt them.
///   If the new location already has its own Speakers store, the old one is left
///   untouched (preserved as a backup) rather than merged.
/// - Prunes directories that end up empty after the move; any directory still holding
///   skipped (conflicting) items is left intact, so nothing is ever destroyed.
enum SupportDirectoryMigration {
    private static let flagKey = "parley.migratedFromPriorName.v1"

    /// Former app name(s), newest-first. Append here if the app is ever renamed again.
    private static let priorNames = ["Macsribe"]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return }
        defer { defaults.set(true, forKey: flagKey) }

        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let newDir = base.appendingPathComponent(AppInfo.name, isDirectory: true)

        var moved = 0
        for prior in priorNames where prior != AppInfo.name {
            let oldDir = base.appendingPathComponent(prior, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: oldDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            moved += mergeMissing(from: oldDir, into: newDir, fm: fm)
            pruneEmptyDirs(oldDir, fm: fm)
        }
        if moved > 0 {
            AppLog.log("Support-dir migration: moved \(moved) item(s) from a prior app name into \(AppInfo.name)/",
                       category: "migrate")
        }
    }

    /// Recursively move entries absent in `dest`. Entries present in both are kept
    /// (dest wins); directories present in both are merged child-by-child.
    private static func mergeMissing(from src: URL, into dest: URL, fm: FileManager) -> Int {
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }

        var moved = 0
        for entry in entries {
            let target = dest.appendingPathComponent(entry.lastPathComponent)
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !fm.fileExists(atPath: target.path) {
                // Whole item missing in dest — move it across atomically.
                do { try fm.moveItem(at: entry, to: target); moved += 1 }
                catch {
                    AppLog.log("Migrate skipped \(entry.lastPathComponent): \(error.localizedDescription)",
                               category: "migrate")
                }
            } else if isDir {
                // Both sides have this directory — recurse to fill in missing children.
                moved += mergeMissing(from: entry, into: target, fm: fm)
            }
            // else: a file exists in both — keep dest's copy (never overwrite).
        }
        return moved
    }

    /// Remove `dir` and its now-empty subdirectories (bottom-up). Stops at any
    /// directory that still has real contents (e.g. a skipped Speakers store), so
    /// conflicting data is preserved as a backup.
    private static func pruneEmptyDirs(_ dir: URL, fm: FileManager) {
        if let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { pruneEmptyDirs(entry, fm: fm) }
            }
        }
        // Treat a dir holding only .DS_Store as empty.
        let remaining = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0 != ".DS_Store" } ?? []
        if remaining.isEmpty {
            try? fm.removeItem(at: dir.appendingPathComponent(".DS_Store"))
            try? fm.removeItem(at: dir)
        }
    }
}
