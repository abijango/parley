import Foundation

/// One-time removal of WhisperKit weights left under Application Support.
/// FluidAudio stores its models in a different directory, so this never touches them.
enum WhisperModelCleanup {
    static let flagKey = "parley.removedWhisperModels.v1"

    static func runIfNeeded(defaults: UserDefaults = .standard, modelsDirectory: URL? = nil) {
        guard !defaults.bool(forKey: flagKey) else { return }
        let directory = modelsDirectory
            ?? AppPaths.supportDirectory.appendingPathComponent("models", isDirectory: true)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue {
            do {
                try fm.removeItem(at: directory)
                AppLog.log("Removed leftover WhisperKit models at \(directory.path)", category: "migrate")
            } catch {
                AppLog.log("Could not remove leftover WhisperKit models: \(error.localizedDescription)", category: "migrate")
                return
            }
        }
        defaults.set(true, forKey: flagKey)
    }
}
