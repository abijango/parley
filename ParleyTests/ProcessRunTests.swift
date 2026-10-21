import XCTest
@testable import Parley

final class ProcessRunTests: XCTestCase {

    func testChildFloodingStderrDoesNotDeadlock() throws {
        let script = try Self.makeScript("""
        head -c 200000 /dev/zero | tr '\\0' 'e' >&2
        printf '{"text":"ok"}'
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let output = try XCTUnwrap(ProcessRun.capture(binary: script.path, args: [], timeout: 10))

        XCTAssertFalse(output.timedOut)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stderr.count, 200_000)
        XCTAssertEqual(output.stdoutText, #"{"text":"ok"}"#)
    }

    func testStreamingStdoutStillDrainsStderr() throws {
        let script = try Self.makeScript("""
        head -c 200000 /dev/zero | tr '\\0' 'e' >&2
        echo line1
        echo line2
        """)
        defer { try? FileManager.default.removeItem(at: script) }
        let process = Process()
        process.executableURL = script
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        var streamed = Data()
        let output = try ProcessRun.run(process, stdout: out, stderr: err, timeout: 10) { streamed.append($0) }

        XCTAssertFalse(output.timedOut)
        XCTAssertEqual(String(decoding: streamed, as: UTF8.self), "line1\nline2\n")
        XCTAssertTrue(output.stdout.isEmpty)
        XCTAssertEqual(output.stderr.count, 200_000)
    }

    func testOverrunningChildIsKilledAndReportedAsTimedOut() throws {
        let script = try Self.makeScript("sleep 30")
        defer { try? FileManager.default.removeItem(at: script) }
        let started = Date()

        let output = try XCTUnwrap(ProcessRun.capture(binary: script.path, args: [], timeout: 0.5))

        XCTAssertTrue(output.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testLaunchFailureReturnsNil() {
        XCTAssertNil(ProcessRun.capture(binary: "/nonexistent/parley-cli", args: [], timeout: 1))
    }

    private static func makeScript(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-processrun-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
