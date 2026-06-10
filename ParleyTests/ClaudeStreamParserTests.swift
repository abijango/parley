import XCTest
@testable import Parley

/// Unit coverage for ClaudeStreamParser: one test per event shape, plus the
/// `currentSection` heading scanner. All fixture strings are minimal valid NDJSON
/// so the tests stay readable and don't depend on claude's exact format changing.
final class ClaudeStreamParserTests: XCTestCase {

    // MARK: Helpers

    private func line(_ json: String) -> ClaudeStreamParser.Event {
        ClaudeStreamParser.parse(Data(json.utf8))
    }

    // MARK: assistant — text block

    func testAssistantTextBlockProducesActivityLine() {
        let json = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"Summarising the meeting…"}]}}
        """
        let event = line(json)
        XCTAssertEqual(event.activityLines, ["Summarising the meeting…"])
        XCTAssertEqual(event.textDelta, "")
        XCTAssertNil(event.resultText)
    }

    func testAssistantTextBlockTruncatesLongText() {
        // Text longer than 120 chars should be truncated with "…"
        let longText = String(repeating: "x", count: 150)
        let json = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"\(longText)"}]}}
        """
        let event = line(json)
        XCTAssertEqual(event.activityLines.count, 1)
        XCTAssertTrue(event.activityLines[0].hasSuffix("…"))
        XCTAssertEqual(event.activityLines[0].count, 121)   // 120 chars + "…"
    }

    // MARK: assistant — tool_use with file_path

    func testAssistantToolUseWithFilePath() {
        let json = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/vault/notes/2026-01-01-meeting.md"}}]}}
        """
        let event = line(json)
        XCTAssertEqual(event.activityLines.count, 1)
        XCTAssertEqual(event.activityLines[0], "▸ Read: 2026-01-01-meeting.md")
    }

    func testAssistantToolUseBashCommandSummarised() {
        let json = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls /tmp/parley"}}]}}
        """
        let event = line(json)
        XCTAssertEqual(event.activityLines.count, 1)
        XCTAssertTrue(event.activityLines[0].hasPrefix("▸ Bash: "))
        XCTAssertTrue(event.activityLines[0].contains("ls /tmp/parley"))
    }

    func testAssistantUnknownToolNameNoDetail() {
        let json = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"MyCustomTool","input":{}}]}}
        """
        let event = line(json)
        XCTAssertEqual(event.activityLines, ["▸ MyCustomTool"])
    }

    // MARK: stream_event / content_block_delta / text_delta

    func testStreamEventTextDeltaSurfacesTextDelta() {
        let json = """
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"## Key Topics"}}}
        """
        let event = line(json)
        XCTAssertEqual(event.textDelta, "## Key Topics")
        XCTAssertTrue(event.activityLines.isEmpty)
        XCTAssertNil(event.resultText)
    }

    func testStreamEventNonTextDeltaIsIgnored() {
        // input_json_delta (tool streaming) should not produce a textDelta
        let json = """
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{}"}}}
        """
        let event = line(json)
        XCTAssertEqual(event.textDelta, "")
        XCTAssertTrue(event.activityLines.isEmpty)
    }

    // MARK: result — success and error

    func testResultEventSuccessPayload() {
        let json = """
        {"type":"result","result":"## Summary\\nThe meeting covered Q3 goals.","is_error":false}
        """
        let event = line(json)
        XCTAssertEqual(event.resultText, "## Summary\nThe meeting covered Q3 goals.")
        XCTAssertEqual(event.isError, false)
        XCTAssertTrue(event.activityLines.isEmpty)
        XCTAssertEqual(event.textDelta, "")
    }

    func testResultEventErrorFlagViaIsError() {
        let json = """
        {"type":"result","result":"Something went wrong","is_error":true}
        """
        let event = line(json)
        XCTAssertEqual(event.isError, true)
        XCTAssertNotNil(event.resultText)
    }

    func testResultEventErrorFlagViaSubtype() {
        // `subtype: "error"` is an alternative encoding claude uses in some versions.
        let json = """
        {"type":"result","result":"API error","subtype":"error"}
        """
        let event = line(json)
        XCTAssertEqual(event.isError, true)
    }

    // MARK: result — usage / cost

    func testResultEventCapturesUsageAndCost() {
        let json = """
        {"type":"result","subtype":"success","is_error":false,"result":"## Summary","total_cost_usd":0.0123,"usage":{"input_tokens":1200,"output_tokens":850,"cache_creation_input_tokens":300,"cache_read_input_tokens":4096}}
        """
        let event = line(json)
        XCTAssertEqual(event.usage, ClaudeStreamParser.Usage(
            inputTokens: 1200, outputTokens: 850,
            cacheCreationTokens: 300, cacheReadTokens: 4096, costUSD: 0.0123))
    }

    func testResultEventUsageDefaultsMissingTokenFieldsToZero() throws {
        // Subscription paths may omit cost and some cache fields.
        let json = """
        {"type":"result","result":"ok","is_error":false,"usage":{"input_tokens":10,"output_tokens":20}}
        """
        let event = line(json)
        let usage = try XCTUnwrap(event.usage)
        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 20)
        XCTAssertEqual(usage.cacheCreationTokens, 0)
        XCTAssertEqual(usage.cacheReadTokens, 0)
        XCTAssertNil(usage.costUSD)
    }

    func testResultEventWithoutUsageOrCostHasNilUsage() {
        let json = """
        {"type":"result","result":"## Summary","is_error":false}
        """
        XCTAssertNil(line(json).usage)
    }

    func testResultEventCostOnlyStillProducesUsage() throws {
        // total_cost_usd present but no usage object → a Usage with zero tokens + cost.
        let json = """
        {"type":"result","result":"ok","is_error":false,"total_cost_usd":0.5}
        """
        let usage = try XCTUnwrap(line(json).usage)
        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.costUSD, 0.5)
    }

    // MARK: malformed / unknown input → empty Event

    func testMalformedJsonReturnsEmptyEvent() {
        XCTAssertEqual(line("not json at all"), ClaudeStreamParser.Event())
    }

    func testEmptyDataReturnsEmptyEvent() {
        XCTAssertEqual(ClaudeStreamParser.parse(Data()), ClaudeStreamParser.Event())
    }

    func testUnknownEventTypeReturnsEmptyEvent() {
        let json = """
        {"type":"system","subtype":"init","session_id":"abc123"}
        """
        XCTAssertEqual(line(json), ClaudeStreamParser.Event())
    }

    func testAssistantWithNoContentReturnsEmptyActivityLines() {
        let json = """
        {"type":"assistant","message":{"content":[]}}
        """
        let event = line(json)
        XCTAssertTrue(event.activityLines.isEmpty)
    }

    // MARK: currentSection

    func testCurrentSectionFindsLastH2() {
        let text = "## Key Topics Discussed\n\nSome content.\n\n## Decisions\n\nMore content."
        XCTAssertEqual(ClaudeStreamParser.currentSection(in: text), "Decisions")
    }

    func testCurrentSectionFindsH1() {
        let text = "# Meeting Summary\n\nIntroduction."
        XCTAssertEqual(ClaudeStreamParser.currentSection(in: text), "Meeting Summary")
    }

    func testCurrentSectionFindsH3() {
        let text = "## Decisions\n\n### Sub-section Alpha\n\nDetail."
        XCTAssertEqual(ClaudeStreamParser.currentSection(in: text), "Sub-section Alpha")
    }

    func testCurrentSectionH4OrDeeperIsIgnored() {
        // Level 4+ headings must not match (contract: 1–3 only).
        let text = "#### Deep Heading\n\nOnly a level-4."
        XCTAssertNil(ClaudeStreamParser.currentSection(in: text))
    }

    func testCurrentSectionReturnsNilForHeadinglessText() {
        let text = "This is just plain prose with no headings at all."
        XCTAssertNil(ClaudeStreamParser.currentSection(in: text))
    }

    func testCurrentSectionReturnsNilForEmptyString() {
        XCTAssertNil(ClaudeStreamParser.currentSection(in: ""))
    }

    func testCurrentSectionPicksLatestWhenMultipleExist() {
        // The function must return the LAST heading in the document, not the first.
        let text = """
        ## First Section
        Some text.
        ## Second Section
        More text.
        ## Third Section
        Final content.
        """
        XCTAssertEqual(ClaudeStreamParser.currentSection(in: text), "Third Section")
    }

    func testCurrentSectionIgnoresHashesInsideBodyText() {
        // A "#" that is not at the start of a line (or after spaces) is not a heading.
        let text = "Color code #FF0000 is red.\nNo real headings here."
        XCTAssertNil(ClaudeStreamParser.currentSection(in: text))
    }
}
