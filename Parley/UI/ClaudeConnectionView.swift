import SwiftUI
import AppKit

/// Settings surface for the Claude Code connection: a live status badge, install/login/
/// re-check actions, and a tally of the usage Parley has spent. Embedded in the
/// Settings → Summary → "Claude" section. Observes the app-wide `ClaudeConnection` and
/// `ClaudeUsageStore` singletons; owns a transient `ClaudeInstaller` for the install sheet.
struct ClaudeConnectionView: View {
    @ObservedObject private var connection = ClaudeConnection.shared
    @ObservedObject private var usage = ClaudeUsageStore.shared
    @StateObject private var installer = ClaudeInstaller()

    @State private var showInstallSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            statusRow
            guidance
            actionButtons
            Divider().padding(.vertical, Theme.Spacing.xxSmall)
            usageBlock
        }
        .onAppear { connection.refresh() }
        .sheet(isPresented: $showInstallSheet) { installSheet }
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
            return Badge(symbol: "xmark.circle.fill", color: .red, title: "Claude Code not installed")
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
            return "Parley summarizes meetings by running Claude Code on your Mac. Install it, then log in with your Claude Pro/Max (or Console) account."
        case .installedNotLoggedIn:
            return "Claude Code is installed but not signed in. Click Log in — a browser opens; pick your account — then Re-check."
        case .connected:
            return "Parley runs `claude -p` using your own Claude Code login. Summaries spend against that account."
        case .limited:
            return "Claude hit a usage/rate limit. The summary queue pauses and resumes automatically; you can Re-check to confirm."
        case .unknown:
            return "Checking whether the Claude Code CLI is installed and logged in…"
        }
    }

    /// Extra error detail from a probe / failed run, when present.
    private var detailLine: String? {
        if case .installedNotLoggedIn(let detail) = connection.status, let detail, !detail.isEmpty {
            return "Last error: \(detail)"
        }
        return nil
    }

    // MARK: Actions

    private var actionButtons: some View {
        HStack(spacing: Theme.Spacing.small) {
            if case .notInstalled = connection.status {
                Button("Install Claude Code") { showInstallSheet = true; installer.install { ok in if ok { connection.refresh() } } }
                    .buttonStyle(.borderedProminent)
            }
            Button("Log in") {
                let binary = connection.resolvedBinaryPath ?? AppSettings.shared.claudeBinaryPath
                _ = installer.openLoginTerminal(binary: binary)
            }
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

    // MARK: Usage

    private var usageBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack {
                Text("Usage (this app)").font(Theme.Typography.controlLabel)
                Spacer()
                Button("Reset") { usage.reset() }
                    .controlSize(.small)
                    .disabled(usage.total.runCount == 0)
            }
            let t = usage.total
            Text("\(t.totalTokens.formatted()) tokens · \(t.runCount) run\(t.runCount == 1 ? "" : "s")\(costSuffix(t.costUSD))")
                .font(Theme.Typography.mono)
            caption("Input \(t.inputTokens.formatted()) · Output \(t.outputTokens.formatted()) · Cache \(((t.cacheCreationTokens + t.cacheReadTokens)).formatted()). What Parley has spent since \(Self.shortDate(t.since)). Cost is Claude Code's estimate — on a subscription there's no incremental charge.")
        }
    }

    private func costSuffix(_ cost: Double) -> String {
        guard cost > 0 else { return "" }
        let s = cost < 0.01 ? String(format: "%.4f", cost) : String(format: "%.2f", cost)
        return " · ≈$\(s) est."
    }

    // MARK: Install sheet

    private var installSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Install Claude Code").font(Theme.Typography.sheetTitle)
            caption("Running the official installer. It places `claude` at ~/.local/bin/claude.")
            ScrollView {
                Text(installer.log.isEmpty ? "Starting…" : installer.log)
                    .font(Theme.Typography.mono)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 460, minHeight: 220)
            .overlay(Theme.Radius.rect(Theme.Radius.small).strokeBorder(.quaternary))

            caption("Prefer Homebrew? Run `\(ClaudeInstaller.homebrewCommand)` in a terminal instead.")

            HStack {
                if installer.isInstalling { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { showInstallSheet = false }
                    .keyboardShortcut(.defaultAction)
                    .disabled(installer.isInstalling)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(minWidth: 520)
    }

    // MARK: Helpers

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func shortDate(_ date: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        return df.string(from: date)
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
