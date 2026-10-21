import XCTest
@testable import Parley

@MainActor
final class ModelLoadRecoveryTests: XCTestCase {
    func testTestHostIsDetected() {
        XCTAssertTrue(AppInfo.isXCTestHost)
    }

    func testMarkInProgressIsIgnoredInTestHost() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: FluidModelManager.loadInProgressKey)
        FluidModelManager.markCompiledLoadInProgress()
        XCTAssertFalse(defaults.bool(forKey: FluidModelManager.loadInProgressKey))
    }

    func testCrashedLoadRecoveryInTestsDropsSentinelWithoutWipingCache() throws {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: FluidModelManager.loadInProgressKey)
        let cache = try XCTUnwrap(FluidModelManager.compiledCacheURL())
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let marker = cache.appendingPathComponent("parley-xctest-keep")
        try Data("keep".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: marker) }

        FluidModelManager.recoverFromCrashedLoadIfNeeded()

        XCTAssertFalse(defaults.bool(forKey: FluidModelManager.loadInProgressKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}
