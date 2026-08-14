import XCTest
@testable import Parley

final class PromptStdinTests: XCTestCase {

    func testClaudeRawSummaryKeepsPromptOffArgv() throws {
        let bin = try Self.makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: bin) }
        let secret = "UNIQUE-MEETING-SECRET-\(UUID().uuidString)"
        let built = try ClaudeRunner.makeRawSummaryProcess(
            binaryPath: bin.path, prompt: secret, model: "opus")
        let args = built.process.arguments ?? []
        XCTAssertFalse(args.contains(where: { $0.contains(secret) }))
        XCTAssertTrue(args.contains(PromptStdin.argvPlaceholder))
    }

    func testGrokRawSummaryKeepsPromptOffArgv() throws {
        let bin = try Self.makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: bin) }
        let secret = "UNIQUE-GROK-SECRET-\(UUID().uuidString)"
        let built = try GrokRunner.makeRawSummaryProcess(
            binaryPath: bin.path, prompt: secret, model: "grok-4.5")
        let args = built.process.arguments ?? []
        XCTAssertFalse(args.contains(where: { $0.contains(secret) }))
        XCTAssertTrue(args.contains(PromptStdin.argvPlaceholder))
    }

    func testCursorRawSummaryPutsPromptOnArgv() throws {
        let bin = try Self.makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: bin) }
        let secret = "UNIQUE-CURSOR-SECRET-\(UUID().uuidString)"
        let built = try CursorAgentRunner.makeRawSummaryProcess(
            binaryPath: bin.path, prompt: secret, model: "composer-2.5")
        let args = built.process.arguments ?? []
        XCTAssertTrue(args.contains(secret))
        XCTAssertFalse(args.contains(PromptStdin.argvPlaceholder))
    }

    func testCursorVisionPutsPromptOnArgv() throws {
        let bin = try Self.makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: bin) }
        let secret = "UNIQUE-CURSOR-VISION-\(UUID().uuidString)"
        let built = try CursorAgentRunner.makeVisionProcess(
            binaryPath: bin.path, prompt: secret, model: "composer-2.5", vaultPath: "/tmp")
        let args = built.process.arguments ?? []
        XCTAssertTrue(args.contains(secret))
        XCTAssertFalse(args.contains(PromptStdin.argvPlaceholder))
    }

    private static func makeFakeBinary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parley-fake-cli-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: "#!/bin/sh\n".data(using: .utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
