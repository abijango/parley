import Foundation

/// Tracks whether the Cursor CLI is installed and usable for `cursor agent -p` summaries.
@MainActor
final class CursorConnection: ObservableObject {

    enum Status: Equatable {
        case unknown
        case notInstalled
        case ready
        case failed(String)
    }

    static let shared = CursorConnection()

    @Published private(set) var status: Status = .unknown
    @Published private(set) var resolvedBinaryPath: String?
    @Published private(set) var isChecking = false

    nonisolated static var fallbackPaths: [String] {
        let home = NSHomeDirectory()
        return [
            "/usr/local/bin/cursor",
            "/opt/homebrew/bin/cursor",
            "\(home)/.local/bin/cursor",
            "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
        ]
    }

    func refresh() {
        guard !isChecking else { return }
        isChecking = true
        let configured = AppSettings.shared.cursorBinaryPath
        Task.detached { [weak self] in
            let resolved = Self.resolveBinary(
                configured: configured,
                candidates: Self.fallbackPaths)
            let ok = resolved.map { Self.runsOK($0) } ?? false
            await MainActor.run {
                guard let self else { return }
                self.resolvedBinaryPath = resolved
                self.status = (resolved != nil && ok) ? .ready : .notInstalled
                self.isChecking = false
            }
        }
    }

    func noteRunSucceeded() {
        if case .notInstalled = status { return }
        status = .ready
    }

    func noteAuthFailure(detail: String) {
        status = .failed(detail)
    }

    nonisolated static func resolveBinary(configured: String, candidates: [String]) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
            return trimmed
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    nonisolated private static func runsOK(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["agent", "--version"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }
}
