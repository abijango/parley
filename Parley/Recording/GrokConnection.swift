import Foundation

/// Tracks whether the local Grok CLI is installed, reachable, and logged in, so
/// Settings can show a status badge and the summary flow can give actionable errors.
///
/// Status is derived from:
///   1. Is the `grok` binary present + executable (configured path, else common installs)?
///   2. Does it run (`grok --version`)?
///   3. Logged-in heuristic: does `~/.grok/auth.json` carry a credential entry with email?
/// plus on-demand probe / real-run outcomes:
///   4. `testConnection()` — a tiny `grok -p` probe
///   5. `noteRunSucceeded` / `noteAuthFailure` from `SummaryService`
@MainActor
final class GrokConnection: ObservableObject {

    enum Status: Equatable {
        case unknown
        case notInstalled
        case installedNotLoggedIn(detail: String?)
        case connected(account: String?)
        case limited(resumeAt: Date?)
    }

    static let shared = GrokConnection()

    @Published private(set) var status: Status = .unknown
    @Published private(set) var resolvedBinaryPath: String?
    @Published private(set) var isChecking = false

    nonisolated static var fallbackPaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.grok/bin/grok",
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok",
            "\(home)/.local/bin/grok",
        ]
    }

    // MARK: Passive refresh

    func refresh() {
        guard !isChecking else { return }
        isChecking = true
        let configured = AppSettings.shared.grokBinaryPath
        Task.detached { [weak self] in
            let resolved = Self.resolveBinary(
                configured: configured,
                candidates: Self.fallbackPaths,
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
            let runs = resolved.map { Self.runsOK($0) } ?? false
            let login = Self.accountFromAuthJSON()
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

    // MARK: Probe

    func testConnection() {
        guard !isChecking else { return }
        isChecking = true
        let configured = AppSettings.shared.grokBinaryPath
        let model = AppSettings.shared.grokModel
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
            let outcome = Self.runProbe(binary: binary, model: model)
            let login = Self.accountFromAuthJSON()
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
                    self.status = .installedNotLoggedIn(detail: detail)
                }
                self.isChecking = false
            }
        }
    }

    // MARK: Real-run outcomes

    func noteRunSucceeded(account: String? = nil) {
        status = .connected(account: account ?? accountIfKnown())
    }
    func noteUsageLimited(resumeAt: Date?) { status = .limited(resumeAt: resumeAt) }
    func noteAuthFailure(detail: String?) { status = .installedNotLoggedIn(detail: detail) }

    private func accountIfKnown() -> String? {
        if case .connected(let a) = status { return a }
        return nil
    }

    // MARK: Pure helpers

    nonisolated static func resolveBinary(
        configured: String,
        candidates: [String],
        isExecutable: (String) -> Bool
    ) -> String? {
        ([configured] + candidates).first(where: { !$0.isEmpty && isExecutable($0) })
    }

    /// Parse `~/.grok/auth.json`. Top-level keys are OIDC issuer entries; each value
    /// may carry `email` / `user_id` when logged in.
    nonisolated static func parseAuthJSON(_ data: Data) -> (loggedIn: Bool, account: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !obj.isEmpty else {
            return (false, nil)
        }
        for (_, value) in obj {
            guard let entry = value as? [String: Any] else { continue }
            // Presence of a key or refresh_token is enough to treat as logged in.
            let hasCred = entry["key"] != nil || entry["refresh_token"] != nil
            guard hasCred else { continue }
            let account = (entry["email"] as? String)
                ?? (entry["user_id"] as? String)
            return (true, account)
        }
        return (false, nil)
    }

    // MARK: Private

    nonisolated private static func accountFromAuthJSON() -> (loggedIn: Bool, account: String?) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grok")
            .appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url) else { return (false, nil) }
        return parseAuthJSON(data)
    }

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

    nonisolated private static func runProbe(binary: String, model: String) -> ProbeOutcome {
        guard let r = runSync(
            binary: binary,
            args: [
                "-p", "Reply with the single word OK.",
                "-m", model,
                "--output-format", "json",
                "--no-subagents", "--no-memory", "--disable-web-search",
            ],
            timeout: 90)
        else { return .otherError(detail: "Grok didn't respond to a test prompt.") }

        if r.exitCode == 0 {
            switch GrokRunner.parseJSONResult(stdout: r.stdout) {
            case .text: return .ok
            case .error(let msg):
                if Self.looksLikeAuth(msg) { return .notLoggedIn(detail: msg) }
                return .otherError(detail: msg)
            case .unparseable:
                // Exit 0 with non-JSON is still a good connectivity signal.
                return r.stdout.localizedCaseInsensitiveContains("OK") ? .ok
                    : .otherError(detail: "Unexpected Grok probe output.")
            }
        }

        let blob = r.stdout + "\n" + r.stderr
        if ClaudeUsageLimit.detect(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode) != nil {
            return .limited(resumeAt: nil)
        }
        if Self.looksLikeAuth(blob) {
            return .notLoggedIn(detail: String(blob.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)))
        }
        let detail = r.stderr.isEmpty ? "grok exited with code \(r.exitCode)" : String(r.stderr.prefix(160))
        return .otherError(detail: detail)
    }

    nonisolated private static func looksLikeAuth(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("not logged in")
            || lower.contains("please log in")
            || lower.contains("unauthorized")
            || lower.contains("authentication")
            || lower.contains("sign in")
            || lower.contains("login required")
    }

    private struct SyncResult { var exitCode: Int32; var stdout: String; var stderr: String }

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
