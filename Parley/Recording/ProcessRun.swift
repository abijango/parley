import Foundation

/// What a finished child process left behind.
struct ProcessOutput {
    var stdout: Data
    var stderr: Data
    var exitCode: Int32
    var timedOut: Bool

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

enum ProcessRun {
    /// Launches `process` and blocks until it exits or `timeout` kills it.
    ///
    /// stderr drains on a background queue while stdout is read here. Reading the two
    /// pipes one after the other deadlocks once the child fills the unread pipe's
    /// buffer (~64 KB). When `onStdout` is set, stdout chunks go to it as they arrive
    /// and `ProcessOutput.stdout` stays empty.
    static func run(
        _ process: Process,
        stdout: Pipe,
        stderr: Pipe,
        timeout: TimeInterval,
        handle: ProcessHandle? = nil,
        onStdout: ((Data) -> Void)? = nil
    ) throws -> ProcessOutput {
        try process.run()
        handle?.set(process)

        let timedOut = Locked(false)
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.value = true
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let errData = Locked(Data())
        let errDrained = DispatchGroup()
        errDrained.enter()
        DispatchQueue.global().async {
            errData.value = stderr.fileHandleForReading.readDataToEndOfFile()
            errDrained.leave()
        }

        var outData = Data()
        let out = stdout.fileHandleForReading
        if let onStdout {
            while true {
                let chunk = out.availableData
                if chunk.isEmpty { break }
                onStdout(chunk)
            }
        } else {
            outData = out.readDataToEndOfFile()
        }

        process.waitUntilExit()
        errDrained.wait()
        watchdog.cancel()
        return ProcessOutput(stdout: outData, stderr: errData.value,
                             exitCode: process.terminationStatus, timedOut: timedOut.value)
    }

    /// Runs `binary args…` with stdin closed. Nil only if the process fails to launch.
    static func capture(binary: String, args: [String], timeout: TimeInterval) -> ProcessOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        return try? run(process, stdout: out, stderr: err, timeout: timeout)
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) { _value = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
