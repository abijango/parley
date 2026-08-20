import XCTest
@testable import Parley

@MainActor
final class ModelLoadRecoveryTests: XCTestCase {
    func testTestHostIsDetected() {
        XCTAssertTrue(AppInfo.isXCTestHost)
    }

    func testMarkInProgressIsIgnoredInTestHost() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: ModelManager.loadInProgressKey)
        ModelManager.markCompiledLoadInProgress()
        XCTAssertFalse(defaults.bool(forKey: ModelManager.loadInProgressKey))
    }

    func testCrashedLoadRecoveryInTestsDropsSentinelWithoutWipingCache() throws {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: ModelManager.loadInProgressKey)
        let cache = try XCTUnwrap(ModelManager.compiledCacheURL())
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let marker = cache.appendingPathComponent("parley-xctest-keep")
        try Data("keep".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: marker) }

        ModelManager.recoverFromCrashedLoadIfNeeded()

        XCTAssertFalse(defaults.bool(forKey: ModelManager.loadInProgressKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}
