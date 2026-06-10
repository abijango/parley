import Foundation

/// Tracks whether the local Claude Code CLI is installed, reachable, and logged in, so
/// Settings can show a live status badge and the summary flow can give actionable errors
/// instead of opaque failures.
///
/// There is no reliable non-interactive `claude auth status` (open gap: claude-code#1886),
/// so status is derived from signals we *can* read cheaply:
///   1. Is the `claude` binary present + executable (configured path, else common installs)?
///   2. Does it run (`claude --version`)?
///   3. Logged-in heuristic, no spend: does `~/.claude.json` carry an `oauthAccount`?
/// plus two authoritative-but-spending signals folded in on demand / after real runs:
///   4. `testConnection()` — a tiny `claude -p` probe, classified via the auth / usage-limit
///      detectors.
///   5. `noteRunOutcome(...)` — the result of an actual summary run.
@MainActor
final class ClaudeConnection: ObservableObject {

    enum Status: Equatable {
        case unknown
        case notInstalled
        case installedNotLoggedIn(detail: String?)
        case connected(account: String?)
        case limited(resumeAt: Date?)
    }

    static let shared = ClaudeConnection()

    @Published private(set) var status: Status = .unknown
    /// The path `claude` was actually found at (may differ from the configured path when
    /// we fall back to a common install location). nil when not found.
    @Published private(set) var resolvedBinaryPath: String?
    @Published private(set) var isChecking = false

    /// Common install locations checked when the configured path isn't executable.
    /// `~/.local/bin` is the native-installer default (and the app's default setting);
    /// the Homebrew/`/usr/local` paths cover cask / legacy installs.
    nonisolated static var fallbackPaths: [String] {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    // MARK: Passive refresh (no token spend)

    /// Resolve the binary, confirm it runs, and apply the `~/.claude.json` login heuristic.
    /// Never spends tokens. Safe to call on Settings appear.
    func refresh() {
        guard !isChecking else { return }
        isChecking = true
        let configured = AppSettings.shared.claudeBinaryPath
        Task.detached { [weak self] in
            let resolved = Self.resolveBinary(
                configured: configured,
                candidates: Self.fallbackPaths,
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
            let runs = resolved.map { Self.runsOK($0) } ?? false
            let login = Self.accountFromClaudeJSON()
            await MainActor.run {
                guard let self else { return }
                self.resolvedBinaryPath = resolved
                if resolved == nil || !runs {
                    self.status = .notInstalled
                } else if login.loggedIn {
                    self.status = .connected(account: login.account)
                } else {
                    self.status = .installedNotLoggedIn(detail: nil)
                }
                self.isChecking = false
            }
        }
    }

    // MARK: Authoritative probe (tiny token spend)

    /// Run a minimal `claude -p` probe and classify the outcome. Spends a trivial amount of
    /// usage, so it's only invoked from the explicit "Test connection" button / after login.
    func testConnection() {
        guard !isChecking else { return }
        isChecking = true
        let configured = AppSettings.shared.claudeBinaryPath
        Task.detached { [weak self] in
            let resolved = Self.resolveBinary(
                configured: configured,
                candidates: Self.fallbackPaths,
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
            guard let binary = resolved else {
                await MainActor.run {
                    self?.resolvedBinaryPath = nil
                    self?.status = .notInstalled
                    self?.isChecking = false
                }
                return
            }
            let outcome = Self.runProbe(binary: binary)
            let login = Self.accountFromClaudeJSON()
            await MainActor.run {
                guard let self else { return }
                self.resolvedBinaryPath = binary
                switch outcome {
                case .ok:
                    self.status = .connected(account: login.account)
                case .limited(let resumeAt):
                    self.status = .limited(resumeAt: resumeAt)
                case .notLoggedIn(let detail):
                    self.status = .installedNotLoggedIn(detail: detail)
                case .otherError(let detail):
                    // Reachable but the probe failed for a non-auth reason — surface it
                    // without claiming "logged in".
                    self.status = .installedNotLoggedIn(detail: detail)
                }
                self.isChecking = false
            }
        }
    }

    // MARK: Fold in real-run outcomes

    /// Update the badge from an actual summary run so a real failure (or success) keeps the
    /// status honest without an extra probe. Called by `SummaryService`.
    func noteRunSucceeded(account: String? = nil) {
        status = .connected(account: account ?? accountIfKnown())
    }
    func noteUsageLimited(resumeAt: Date?) { status = .limited(resumeAt: resumeAt) }
    func noteAuthFailure(detail: String?) { status = .installedNotLoggedIn(detail: detail) }

    private func accountIfKnown() -> String? {
        if case .connected(let a) = status { return a }
        return nil
    }

    // MARK: Pure helpers (unit-testable)

    /// First executable path among [configured] + candidates, or nil if none.
    nonisolated static func resolveBinary(
        configured: String,
        candidates: [String],
        isExecutable: (String) -> Bool
    ) -> String? {
        ([configured] + candidates).first(where: { !$0.isEmpty && isExecutable($0) })
    }

    /// Parse a `~/.claude.json` body for an `oauthAccount`. `loggedIn` is true when the key
    /// is present; `account` is the email/org when available.
    nonisolated static func parseClaudeJSON(_ data: Data) -> (loggedIn: Bool, account: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["oauthAccount"] as? [String: Any] else {
            return (false, nil)
        }
        let account = (oauth["emailAddress"] as? String)
            ?? (oauth["email"] as? String)
            ?? (oauth["organizationName"] as? String)
        return (true, account)
    }

    // MARK: Private process helpers

    nonisolated private static func accountFromClaudeJSON() -> (loggedIn: Bool, account: String?) {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url) else { return (false, nil) }
        return parseClaudeJSON(data)
    }

    /// Runs `claude --version` with a short timeout; true on a clean exit. No token spend.
    nonisolated private static func runsOK(_ binary: String) -> Bool {
        guard let result = runSync(binary: binary, args: ["--version"], timeout: 10) else { return false }
        return result.exitCode == 0
    }

    private enum ProbeOutcome {
        case ok
        case limited(resumeAt: Date?)
        case notLoggedIn(detail: String?)
        case otherError(detail: String?)
    }

    /// Minimal `-p` probe: cheapest model, tiny prompt, no tools / MCP / session.
    nonisolated private static func runProbe(binary: String) -> ProbeOutcome {
        guard let r = runSync(
            binary: binary,
            args: ["-p", "Reply with the single word OK.",
                   "--model", "haiku",
                   "--output-format", "text",
                   "--strict-mcp-config", "--no-session-persistence"],
            timeout: 60)
        else { return .otherError(detail: "Claude didn't respond to a test prompt.") }

        if r.exitCode == 0 { return .ok }
        if ClaudeUsageLimit.detect(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode) != nil {
            // resumeAt parsing is best-effort; the badge only needs the limited state here.
            return .limited(resumeAt: nil)
        }
        if let phrase = ClaudeAuthError.detect(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode) {
            return .notLoggedIn(detail: phrase)
        }
        let detail = r.stderr.isEmpty ? "claude exited with code \(r.exitCode)" : String(r.stderr.prefix(160))
        return .otherError(detail: detail)
    }

    private struct SyncResult { var exitCode: Int32; var stdout: String; var stderr: String }

    /// Spawn `binary args…`, read stdout/stderr to EOF, terminate if it overruns `timeout`.
    /// Returns nil only if the process fails to launch.
    nonisolated private static func runSync(binary: String, args: [String], timeout: TimeInterval) -> SyncResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return SyncResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "")
    }
}
