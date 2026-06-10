import Foundation
import AppKit

/// Drives the two interactive setup steps for the Claude Code CLI:
///   • **install** — runs the official native installer, streaming its output into a sheet;
///   • **login** — opens Terminal running `claude` so the user can complete the browser
///     OAuth flow (login is inherently interactive, so we hand it to a real terminal).
///
/// `@MainActor` + `ObservableObject`: the install sheet binds to `log` / `isInstalling`.
@MainActor
final class ClaudeInstaller: ObservableObject {

    /// The official native-installer command. Drops `claude` at `~/.local/bin/claude`
    /// (the app's default `claudeBinaryPath`). `nonisolated` so the install sheet can read
    /// it off the main actor and the detached install task can reference it directly.
    nonisolated static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    /// Homebrew alternative, surfaced as copyable text for users who prefer a cask.
    nonisolated static let homebrewCommand = "brew install --cask claude-code"

    @Published private(set) var log: String = ""
    @Published private(set) var isInstalling = false
    /// Set when an install finishes: true on a clean exit, false otherwise. nil while idle.
    @Published private(set) var lastInstallSucceeded: Bool?

    /// Run the native installer in a login shell, streaming combined stdout/stderr into
    /// `log`. `completion` fires with the success flag on the main actor.
    func install(completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isInstalling else { return }
        isInstalling = true
        lastInstallSucceeded = nil
        log = "$ \(Self.installCommand)\n"

        Task.detached { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            // Login shell so the installer sees a normal PATH and writes ~/.local/bin.
            process.arguments = ["-lc", Self.installCommand]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            do { try process.run() } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.append("\nFailed to start the installer: \(error.localizedDescription)\n")
                    self.finish(success: false, completion: completion)
                }
                return
            }

            // Stream output line-by-line as it arrives.
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if let text = String(data: chunk, encoding: .utf8) {
                    await MainActor.run { self?.append(text) }
                }
            }
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            let code = process.terminationStatus
            await MainActor.run {
                guard let self else { return }
                self.append(ok ? "\n✓ Install finished.\n" : "\n✗ Installer exited with code \(code).\n")
                self.finish(success: ok, completion: completion)
            }
        }
    }

    private func append(_ text: String) { log += text }

    private func finish(success: Bool, completion: @escaping (Bool) -> Void) {
        isInstalling = false
        lastInstallSucceeded = success
        completion(success)
    }

    /// Open Terminal.app running the `claude` binary so the user can complete login. First
    /// launch prompts the browser OAuth flow; if it lands at the prompt instead, the user
    /// types `/login`. Returns false if Terminal couldn't be scripted.
    @discardableResult
    func openLoginTerminal(binary: String) -> Bool {
        // Quote the path for the shell command Terminal will run.
        let escaped = binary.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\\"\(escaped)\\""
        end tell
        """
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&error)
        if let error {
            AppLog.log("ClaudeInstaller: failed to open Terminal for login — \(error)", category: "summary")
            return false
        }
        return true
    }
}
