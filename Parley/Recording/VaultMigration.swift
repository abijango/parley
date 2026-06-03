import Foundation

/// One-time migration of legacy vault-root transcript folders into the
/// app-owned `<App>/Unprocessed` + `<App>/Processed` layout.
///
/// - Moves `<vault>/Unsorted Transcripts/*` → `Unprocessed/`.
/// - Moves `<vault>/Processed Transcripts/*` → `Processed/`.
/// - Handles both `.md` and legacy `.txt` files (best-effort frontmatter where missing).
/// - Never touches `.staging` or hidden files.
/// - Guarded by a UserDefaults flag so it runs at most once.
enum VaultMigration {
    private static let flagKey = "parley.migratedToAppFolder"

    /// Runs the migration once. Safe to call on every launch.
    @MainActor
    static func runIfNeeded(vault: URL) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return }

        AppPaths.ensureVaultFolders(vault: vault)
        let unprocessed = AppPaths.unprocessedURL(vault: vault)
        let processed = AppPaths.processedURL(vault: vault)

        var moved = 0
        moved += migrateFolder(
            from: vault.appendingPathComponent("Unsorted Transcripts", isDirectory: true),
            to: unprocessed, status: "unprocessed")
        moved += migrateFolder(
            from: vault.appendingPathComponent("Processed Transcripts", isDirectory: true),
            to: processed, status: "processed")

        // App-rename: if a folder named after an OLD app name exists we don't know
        // the old name here; if one ever does, leave it untouched.
        // TODO(app-name): on rename, also migrate <vault>/<OldName>/ → <vault>/<AppInfo.name>/.

        defaults.set(true, forKey: flagKey)
        AppLog.log("Vault migration complete — \(moved) file(s) moved into \(AppInfo.name)/", category: "migrate")
    }

    /// Moves every `.md`/`.txt` from `source` into `dest`, adding frontmatter where missing.
    /// Returns the number of files moved.
    private static func migrateFolder(from source: URL, to dest: URL, status: String) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return 0 }
        guard let entries = try? fm.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for src in entries {
            let name = src.lastPathComponent
            if name.hasPrefix(".") { continue }                       // never touch hidden / .staging
            let ext = src.pathExtension.lowercased()
            guard ext == "md" || ext == "txt" else { continue }

            // Always land as .md in the app folder.
            let mdName = ext == "txt"
                ? (src.deletingPathExtension().lastPathComponent + ".md")
                : name
            let target = uniqueDestination(for: mdName, in: dest)

            do {
                let text = (try? String(contentsOf: src, encoding: .utf8)) ?? ""
                let withMeta = ensureFrontmatter(text: text, file: src, status: status)
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                try withMeta.write(to: target, atomically: true, encoding: .utf8)
                try fm.removeItem(at: src)
                count += 1
            } catch {
                AppLog.log("Migrate skipped \(name): \(error.localizedDescription)", category: "migrate")
            }
        }
        return count
    }

    /// Returns the text unchanged if it already has frontmatter, otherwise prepends a
    /// best-effort block built from the filename/folder.
    private static func ensureFrontmatter(text: String, file: URL, status: String) -> String {
        if TranscriptWriter.parseFrontmatter(text: text) != nil { return text }

        let stem = file.deletingPathExtension().lastPathComponent
        var title = stem
        var date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        if let dash = stem.range(of: " - ") {
            let prefix = String(stem[stem.startIndex..<dash.lowerBound])
            title = String(stem[dash.upperBound...])
            if let d = TranscriptWriter.parseISODate(String(prefix.prefix(10))) { date = d }
        } else if let d = TranscriptWriter.parseISODate(String(stem.prefix(10))) {
            date = d
        }

        let meta = TranscriptMeta(
            title: title.isEmpty ? stem : title, date: date, attendees: [],
            filing: "", status: status, note: nil, audio: nil, type: "recording")
        return TranscriptWriter.renderFrontmatter(meta) + "\n" + text
    }

    private static func uniqueDestination(for filename: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(filename)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var n = 2
        repeat {
            candidate = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
