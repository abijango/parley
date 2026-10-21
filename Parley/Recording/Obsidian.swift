import AppKit

enum Obsidian {
    /// Opens the note in Obsidian using the `vault=<id>&file=<relative>` form,
    /// which is far more reliable than `path=<absolute>` (that scans registered
    /// vaults and often reports "vault not found"). Falls back to Finder.
    @MainActor
    static func open(_ url: URL) {
        if let obsidianURL = openURL(for: url, configuredVault: AppSettings.shared.vaultURL) {
            NSWorkspace.shared.open(obsidianURL)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Builds `obsidian://open?vault=<id|name>&file=<relative>`. Prefers the
    /// vault **id** from Obsidian's own config (always resolves); falls back to
    /// the configured vault's folder name.
    static func openURL(for note: URL, configuredVault: URL) -> URL? {
        // The configured vault path is often a symlink (e.g. into iCloud), but
        // Obsidian registers the real path, so compare resolved paths.
        let notePath = note.resolvingSymlinksInPath().path

        if let match = registeredVault(containing: notePath) {
            return makeOpenURL(vault: match.id, file: relativePath(notePath, under: match.path))
        }
        let base = configuredVault.resolvingSymlinksInPath().path
        if notePath.hasPrefix(base) {
            return makeOpenURL(vault: configuredVault.lastPathComponent,
                               file: relativePath(notePath, under: base))
        }
        return nil
    }

    private static func makeOpenURL(vault: String, file: String) -> URL? {
        guard !file.isEmpty,
              let v = vault.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let f = file.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "obsidian://open?vault=\(v)&file=\(f)")
    }

    private static func relativePath(_ path: String, under base: String) -> String {
        var rel = String(path.dropFirst(min(base.count, path.count)))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    /// Reads `~/Library/Application Support/obsidian/obsidian.json` and returns the
    /// registered vault (id + path) whose path is the longest prefix of `notePath`.
    private static func registeredVault(containing notePath: String) -> (id: String, path: String)? {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: config),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = root["vaults"] as? [String: [String: Any]] else { return nil }

        var best: (id: String, path: String)?
        for (id, info) in vaults {
            guard let path = info["path"] as? String,
                  notePath == path || notePath.hasPrefix(path.hasSuffix("/") ? path : path + "/") else { continue }
            if best == nil || path.count > best!.path.count { best = (id, path) }
        }
        return best
    }
}
