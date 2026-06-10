import XCTest
@testable import Parley

/// Unit coverage for ClaudeUsageStore: accumulation, nil no-op, reset, and JSON
/// round-trip via an injected scratch file. @MainActor because the store is.
@MainActor
final class ClaudeUsageStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-usage-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func usage(input: Int = 0, output: Int = 0, cacheCreate: Int = 0,
                       cacheRead: Int = 0, cost: Double? = nil) -> ClaudeStreamParser.Usage {
        ClaudeStreamParser.Usage(inputTokens: input, outputTokens: output,
                                 cacheCreationTokens: cacheCreate, cacheReadTokens: cacheRead,
                                 costUSD: cost)
    }

    func testStartsEmpty() {
        let store = ClaudeUsageStore(fileURL: fileURL)
        XCTAssertEqual(store.total.runCount, 0)
        XCTAssertEqual(store.total.totalTokens, 0)
        XCTAssertEqual(store.total.costUSD, 0)
    }

    func testAccumulatesAcrossRuns() {
        let store = ClaudeUsageStore(fileURL: fileURL)
        store.record(usage(input: 100, output: 200, cacheCreate: 10, cacheRead: 1000, cost: 0.01))
        store.record(usage(input: 50, output: 25, cost: 0.02))
        XCTAssertEqual(store.total.inputTokens, 150)
        XCTAssertEqual(store.total.outputTokens, 225)
        XCTAssertEqual(store.total.cacheCreationTokens, 10)
        XCTAssertEqual(store.total.cacheReadTokens, 1000)
        XCTAssertEqual(store.total.runCount, 2)
        XCTAssertEqual(store.total.costUSD, 0.03, accuracy: 1e-9)
        XCTAssertEqual(store.total.totalTokens, 150 + 225 + 10 + 1000)
    }

    func testNilUsageIsNoOp() {
        let store = ClaudeUsageStore(fileURL: fileURL)
        store.record(nil)
        XCTAssertEqual(store.total.runCount, 0)
    }

    func testCostOnlyRunIncrementsCountAndCost() {
        let store = ClaudeUsageStore(fileURL: fileURL)
        store.record(usage(cost: 0.5))
        XCTAssertEqual(store.total.runCount, 1)
        XCTAssertEqual(store.total.costUSD, 0.5, accuracy: 1e-9)
        XCTAssertEqual(store.total.totalTokens, 0)
    }

    func testResetZeroesTotals() {
        let store = ClaudeUsageStore(fileURL: fileURL)
        store.record(usage(input: 100, output: 200, cost: 0.01))
        let before = store.total.since
        store.reset()
        XCTAssertEqual(store.total.runCount, 0)
        XCTAssertEqual(store.total.totalTokens, 0)
        XCTAssertEqual(store.total.costUSD, 0)
        XCTAssertGreaterThanOrEqual(store.total.since, before)
    }

    func testPersistsAndReloads() {
        let store = ClaudeUsageStore(fileURL: fileURL)
        store.record(usage(input: 100, output: 200, cacheRead: 4096, cost: 0.0123))

        // A fresh instance pointed at the same file rehydrates the tally.
        let reloaded = ClaudeUsageStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.total.inputTokens, 100)
        XCTAssertEqual(reloaded.total.outputTokens, 200)
        XCTAssertEqual(reloaded.total.cacheReadTokens, 4096)
        XCTAssertEqual(reloaded.total.runCount, 1)
        XCTAssertEqual(reloaded.total.costUSD, 0.0123, accuracy: 1e-9)
    }

    func testMissingFileLoadsEmpty() {
        // tearDown removes it; an absent file must not crash and starts at zero.
        let store = ClaudeUsageStore(fileURL: fileURL)
        XCTAssertEqual(store.total, ClaudeUsageStore.Total(since: store.total.since))
    }
}
