import XCTest
@testable import Parley

@MainActor
final class SummaryFilingTests: XCTestCase {

    private var tmpVault: URL!
    private var origVaultPath: String!
    private var origDeleteAudio: Bool!
    private var sessionDirs: [URL] = []

    override func setUp() {
        tmpVault = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-filing-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpVault, withIntermediateDirectories: true)
        origVaultPath = AppSettings.shared.vaultPath
        origDeleteAudio = AppSettings.shared.deleteAudioAfterFiling
        AppSettings.shared.vaultPath = tmpVault.path
        AppSettings.shared.deleteAudioAfterFiling = true
    }

    override func tearDown() {
        AppSettings.shared.vaultPath = origVaultPath
        AppSettings.shared.deleteAudioAfterFiling = origDeleteAudio
        for dir in sessionDirs { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.removeItem(at: tmpVault)
    }

    private func makeItem(title: String = "Filing Test") throws -> (TranscriptItem, URL) {
        let sessionDir = AppPaths.recordingsDirectory
            .appendingPathComponent("filing-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        sessionDirs.append(sessionDir)
        let audio = sessionDir.appendingPathComponent("mic.caf")
        try Data([0]).write(to: audio)

        AppPaths.ensureVaultFolders(vault: tmpVault)
        let url = AppPaths.unprocessedURL(vault: tmpVault)
            .appendingPathComponent("2026-07-27-1000 - \(title).md")
        let text = """
        ---
        title: \(title)
        date: 2026-07-27
        status: unprocessed
        audio: \(audio.path)
        type: recording
        ---

        ## Transcript

        hello
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        let meta = try XCTUnwrap(TranscriptWriter.parseFrontmatter(url))
        return (TranscriptItem(url: url, meta: meta, isProcessed: false), sessionDir)
    }

    func testV2FilingDeletesAudioWhenEnabled() throws {
        let (item, sessionDir) = try makeItem()
        let store = TranscriptStore()
        let service = SummaryService(store: store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.path))

        let note = service.commitGeneratedMarkdown(item, destination: "Work", body: "## Summary\nDone", overwriteExisting: false)
        XCTAssertNotNil(note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.path))

        let processed = AppPaths.processedURL(vault: tmpVault)
            .appendingPathComponent(item.url.lastPathComponent)
        let meta = try XCTUnwrap(TranscriptWriter.parseFrontmatter(processed))
        XCTAssertNil(meta.audio)
    }

    func testV2FilingRespectsSettingOff() throws {
        AppSettings.shared.deleteAudioAfterFiling = false
        let (item, sessionDir) = try makeItem(title: "Keep Audio")
        let service = SummaryService(store: TranscriptStore())

        _ = service.commitGeneratedMarkdown(item, destination: "", body: "## Summary\nDone", overwriteExisting: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.path))
    }

    func testFilingClearsAQueuedRerun() throws {
        let (item, _) = try makeItem(title: "Queued Rerun")
        let store = TranscriptStore()
        let service = SummaryService(store: store)
        service.isIdle = { false }
        service.enqueueIfPolicyAllows(item, trigger: .userInitiated)
        XCTAssertTrue(service.pendingSummaryIDs.contains(item.id))

        _ = service.commitGeneratedMarkdown(item, destination: "", body: "## Summary\nDone", overwriteExisting: false)
        XCTAssertFalse(service.pendingSummaryIDs.contains(item.id))
    }

    func testRefilingWithDeletedAudioIsNoOp() throws {
        let (item, sessionDir) = try makeItem(title: "Refile")
        let service = SummaryService(store: TranscriptStore())

        let note1 = try XCTUnwrap(service.commitGeneratedMarkdown(
            item, destination: "Work", body: "## Summary\nFirst", overwriteExisting: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.path))

        var processed = AppPaths.processedURL(vault: tmpVault)
            .appendingPathComponent(item.url.lastPathComponent)
        var meta = try XCTUnwrap(TranscriptWriter.parseFrontmatter(processed))
        let refiled = TranscriptItem(url: processed, meta: meta, isProcessed: true)

        let note2 = service.commitGeneratedMarkdown(
            refiled, destination: "Work", body: "## Summary\nSecond", overwriteExisting: true)
        XCTAssertNotNil(note2)
        meta = try XCTUnwrap(TranscriptWriter.parseFrontmatter(processed))
        XCTAssertNil(meta.audio)
    }
}
