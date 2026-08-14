import Foundation

/// Puts the full CLI prompt on stdin (a temp file handle) so it never appears in
/// `ps` argv and cannot hit ARG_MAX. The argv slot is a short instruction only.
enum PromptStdin {
    static let argvPlaceholder = "Follow the instructions on stdin."

    /// Opens a temp file as the process stdin, then unlinks it. The process can
    /// still read until it closes the handle.
    static func attach(_ prompt: String, to process: Process) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-prompt-\(UUID().uuidString).txt")
        try prompt.write(to: url, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forReadingFrom: url)
        try FileManager.default.removeItem(at: url)
        process.standardInput = handle
    }
}

/// Lets a UI cancel path terminate a `Process` started on a detached queue.
final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let process = self.process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}
