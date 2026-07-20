import SwiftUI
import AppKit

/// Settings surface for the Grok CLI connection: status badge, login/test/re-check.
/// Embedded in Settings → Summary when the summary provider is Grok.
struct GrokConnectionView: View {
    @ObservedObject private var connection = GrokConnection.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            statusRow
            guidance
            actionButtons
        }
        .onAppear { connection.refresh() }
    }

    // MARK: Status

    private var statusRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: badge.symbol)
                .foregroundStyle(badge.color)
                .font(.system(size: 13, weight: .semibold))
            Text(badge.title).font(Theme.Typography.controlLabel)
            if connection.isChecking {
                ProgressView().controlSize(.small).padding(.leading, Theme.Spacing.xSmall)
            }
            Spacer()
        }
    }

    private struct Badge { var symbol: String; var color: Color; var title: String }

    private var badge: Badge {
        switch connection.status {
        case .unknown:
            return Badge(symbol: "questionmark.circle", color: .secondary, title: "Checking…")
        case .notInstalled:
            return Badge(symbol: "xmark.circle.fill", color: .red, title: "Grok CLI not installed")
        case .installedNotLoggedIn:
            return Badge(symbol: "exclamationmark.triangle.fill", color: .orange, title: "Installed — not logged in")
        case .connected(let account):
            let who = account.map { " as \($0)" } ?? ""
            return Badge(symbol: "checkmark.circle.fill", color: .green, title: "Connected\(who)")
        case .limited(let resumeAt):
            let when = resumeAt.map { " — resumes \(Self.relative($0))" } ?? ""
            return Badge(symbol: "pause.circle.fill", color: .orange, title: "Usage-limited\(when)")
        }
    }

    private var guidance: some View {
        caption(detailLine.map { "\(guidanceText)\n\($0)" } ?? guidanceText)
    }

    private var guidanceText: String {
        switch connection.status {
        case .notInstalled:
            return "Parley can summarize with the Grok CLI on your Mac. Install Grok Build, then run `grok login` in a terminal."
        case .installedNotLoggedIn:
            return "Grok CLI is installed but not signed in. Click Log in (or run `grok login` in a terminal), then Re-check."
        case .connected:
            return "Parley runs `grok -p` using your own Grok login. Summaries spend against that account."
        case .limited:
            return "Grok hit a usage/rate limit. The summary queue pauses; you can Re-check after it lifts."
        case .unknown:
            return "Checking whether the Grok CLI is installed and logged in…"
        }
    }

    private var detailLine: String? {
        if case .installedNotLoggedIn(let detail) = connection.status, let detail, !detail.isEmpty {
            return "Last error: \(detail)"
        }
        return nil
    }

    // MARK: Actions

    private var actionButtons: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button("Log in") { openLogin() }
                .disabled(loginDisabled)

            Button("Test connection") { connection.testConnection() }
                .disabled(connection.isChecking || isNotInstalled)

            Button("Re-check") { connection.refresh() }
                .disabled(connection.isChecking)
            Spacer()
        }
        .controlSize(.small)
    }

    private var isNotInstalled: Bool { if case .notInstalled = connection.status { return true }; return false }
    private var loginDisabled: Bool { connection.isChecking || isNotInstalled }

    private func openLogin() {
        let binary = connection.resolvedBinaryPath ?? AppSettings.shared.grokBinaryPath
        // Open Terminal with `grok login` so the user can complete OAuth interactively.
        let script = """
        tell application "Terminal"
            activate
            do script "\(binary.replacingOccurrences(of: "\"", with: "\\\"")) login"
        end tell
        """
        if let apple = NSAppleScript(source: script) {
            var err: NSDictionary?
            apple.executeAndReturnError(&err)
            if err != nil {
                // Fallback: open a shell without AppleScript privileges.
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-a", "Terminal", binary]
                try? proc.run()
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
