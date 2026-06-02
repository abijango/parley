import Foundation

/// Filesystem locations the app owns under ~/Library/Application Support/<App>.
enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(AppInfo.supportDirectoryName, isDirectory: true)  // TODO(app-name)
    }

    /// Where WhisperKit models are stored (explicit, not the HF default).
    static var modelsDirectory: URL {
        supportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    /// Raw audio archives, one folder per recording session.
    static var recordingsDirectory: URL {
        supportDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: App-owned vault folder (canonical transcript record)

    /// `<vault>/<AppInfo.name>` — the app-owned folder inside the user's vault.
    /// TODO(app-name): folder name follows the app name.
    static func appVaultFolderURL(vault: URL) -> URL {
        vault.appendingPathComponent(AppInfo.name, isDirectory: true)
    }

    /// `<vault>/<App>/Unprocessed` — freshly written transcripts (status: unprocessed).
    static func unprocessedURL(vault: URL) -> URL {
        appVaultFolderURL(vault: vault).appendingPathComponent("Unprocessed", isDirectory: true)
    }

    /// `<vault>/<App>/Processed` — transcripts whose note has been produced.
    static func processedURL(vault: URL) -> URL {
        appVaultFolderURL(vault: vault).appendingPathComponent("Processed", isDirectory: true)
    }

    /// `<vault>/<App>/.staging` — hidden scratch dir for re-process diffs; excluded from scans.
    static func stagingURL(vault: URL) -> URL {
        appVaultFolderURL(vault: vault).appendingPathComponent(".staging", isDirectory: true)
    }

    /// Creates the Unprocessed/Processed folders (and the parent) if missing.
    static func ensureVaultFolders(vault: URL) {
        ensureDirectory(unprocessedURL(vault: vault))
        ensureDirectory(processedURL(vault: vault))
    }

    // MARK: @MainActor conveniences reading the current vault from settings

    @MainActor static var appVaultFolderURL: URL { appVaultFolderURL(vault: AppSettings.shared.vaultURL) }
    @MainActor static var unprocessedURL: URL { unprocessedURL(vault: AppSettings.shared.vaultURL) }
    @MainActor static var processedURL: URL { processedURL(vault: AppSettings.shared.vaultURL) }
    @MainActor static var stagingURL: URL { stagingURL(vault: AppSettings.shared.vaultURL) }
    @MainActor static func ensureVaultFolders() { ensureVaultFolders(vault: AppSettings.shared.vaultURL) }
}
