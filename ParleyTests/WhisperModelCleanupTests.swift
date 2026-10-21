import XCTest
@testable import Parley

final class WhisperModelCleanupTests: XCTestCase {
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "parley.whisper-cleanup-tests")
        defaults.removePersistentDomain(forName: "parley.whisper-cleanup-tests")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-whisper-cleanup-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "parley.whisper-cleanup-tests")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testRemovesModelsDirectoryAndLeavesSiblings() throws {
        let models = root.appendingPathComponent("models", isDirectory: true)
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: models.appendingPathComponent("turbo.bin"))
        try Data("audio".utf8).write(to: recordings.appendingPathComponent("keep.caf"))

        WhisperModelCleanup.runIfNeeded(defaults: defaults, modelsDirectory: models)

        XCTAssertFalse(FileManager.default.fileExists(atPath: models.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordings.appendingPathComponent("keep.caf").path))
        XCTAssertTrue(defaults.bool(forKey: WhisperModelCleanup.flagKey))
    }

    func testFlaggedRunLeavesAnExistingDirectory() throws {
        let models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: models.appendingPathComponent("turbo.bin"))
        defaults.set(true, forKey: WhisperModelCleanup.flagKey)

        WhisperModelCleanup.runIfNeeded(defaults: defaults, modelsDirectory: models)

        XCTAssertTrue(FileManager.default.fileExists(atPath: models.appendingPathComponent("turbo.bin").path))
    }
}
