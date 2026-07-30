import XCTest
@testable import Parley

final class SummaryMetricsTests: XCTestCase {

    private let cursorJSON = """
    {"type":"result","subtype":"success","is_error":false,"duration_ms":3130,
     "duration_api_ms":3130,"result":"ok","session_id":"…","request_id":"…",
     "usage":{"inputTokens":13596,"outputTokens":29,"cacheReadTokens":5957,"cacheWriteTokens":0}}
    """

    private let grokJSON = """
    {"text":"ok","stopReason":"EndTurn","sessionId":"…","requestId":"…",
     "usage":{"input_tokens":53781,"cache_read_input_tokens":128,"output_tokens":12,
              "reasoning_tokens":11,"total_tokens":53921},
     "num_turns":1,
     "modelUsage":{"grok-4.5":{"inputTokens":53781,"outputTokens":12,
                               "cacheReadInputTokens":128,"modelCalls":1}}}
    """

    func testCursorParseUsage() throws {
        let data = try XCTUnwrap(cursorJSON.data(using: .utf8))
        let m = try XCTUnwrap(CursorAgentRunner.parseUsage(data))
        XCTAssertEqual(m.inputTokens, 13596)
        XCTAssertEqual(m.outputTokens, 29)
        XCTAssertEqual(m.cacheReadTokens, 5957)
        XCTAssertEqual(m.cacheWriteTokens, 0)
        XCTAssertEqual(m.apiDurationMS, 3130)
    }

    func testGrokParseUsage() throws {
        let data = try XCTUnwrap(grokJSON.data(using: .utf8))
        let m = try XCTUnwrap(GrokRunner.parseUsage(data))
        XCTAssertEqual(m.inputTokens, 53781)
        XCTAssertEqual(m.outputTokens, 12)
        XCTAssertEqual(m.cacheReadTokens, 128)
        XCTAssertEqual(m.reasoningTokens, 11)
        XCTAssertEqual(m.model, "grok-4.5")
    }

    func testParseUsageReturnsNilWhenAbsent() throws {
        let cursorNoUsage = #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#
        let grokNoUsage = #"{"text":"ok","stopReason":"EndTurn"}"#
        XCTAssertNil(CursorAgentRunner.parseUsage(try XCTUnwrap(cursorNoUsage.data(using: .utf8))))
        XCTAssertNil(GrokRunner.parseUsage(try XCTUnwrap(grokNoUsage.data(using: .utf8))))
    }

    func testPricingUnknownModelReturnsNil() {
        let m = SummaryRunMetrics(inputTokens: 1000, outputTokens: 500, model: "unknown-model-xyz")
        XCTAssertNil(SummaryPricing.estimate(m))
        let line = SummaryMetricsFormat.compactLine(metrics: m)
        XCTAssertNotNil(line)
        XCTAssertFalse(line!.text.contains("$"))
    }

    func testPricingEstimateIsProportional() throws {
        let one = SummaryRunMetrics(outputTokens: 1000, model: "sonnet")
        let two = SummaryRunMetrics(outputTokens: 2000, model: "sonnet")
        let c1 = try XCTUnwrap(SummaryPricing.estimate(one))
        let c2 = try XCTUnwrap(SummaryPricing.estimate(two))
        XCTAssertEqual(c2 - c1, c1, accuracy: 0.0001)
    }
}
