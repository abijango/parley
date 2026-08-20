import XCTest
@testable import Parley

/// Source pins for the post-call and live-window lag fixes. Hardware-backed
/// layout cost cannot be measured in a unit test, so these guard the structures
/// that keep typing and live ASR from invalidating the whole window.
final class UIResponsivenessTests: XCTestCase {

    func testLiveTranscriptViewIsMarkedEquatableAtTheCallSite() throws {
        let src = try Self.source("Parley/UI/MainWindowView.swift")
        XCTAssertTrue(src.contains("LiveTranscriptView("),
                      "the live pane must still exist")
        let view = try Self.index(of: "LiveTranscriptView(", in: src)
        let eq = try Self.index(of: ".equatable()", in: src)
        XCTAssertLessThan(view, eq,
                          "LiveTranscriptView.equatable() is what stops volatile ASR ticks from rebuilding the seven-stack tree")
    }

    func testLiveWordCountPublishesOnlyOnChange() throws {
        let src = try Self.source("Parley/Recording/RecordingController.swift")
        let body = try Self.body(ofFunction: "private func updateLiveWordCount(from merged:", in: src)
        XCTAssertTrue(body.contains("if live.liveWordCount != total { live.liveWordCount = total }"),
                      "assigning liveWordCount on every merge fires @Published even when the count is unchanged")
    }

    func testTranscriptWriteRunsDetachedFromFinalize() throws {
        let src = try Self.source("Parley/Recording/RecordingController.swift")
        let body = try Self.body(ofFunction: "private func finalize(captureTeardown:", in: src)
        let detached = try Self.index(of: "let result = try await Task.detached {", in: body)
        let write = try Self.index(of: "let written = try TranscriptWriter.write(", in: body)
        XCTAssertLessThan(detached, write)
        XCTAssertEqual(Self.braceDepth(before: write, in: body),
                       Self.braceDepth(before: detached, in: body) + 1,
                       "TranscriptWriter.write must sit inside the detached task, not on the MainActor Task that presents the sheet")
    }

    func testStopPathAddsPeopleInBackground() throws {
        let src = try Self.source("Parley/Recording/RecordingController.swift")
        let body = try Self.body(ofFunction: "private func finalize(captureTeardown:", in: src)
        XCTAssertTrue(body.contains("vault.addPeopleInBackground(attendeeNames)"),
                      "Rolodex rewrite on stop must not hitch the enrichment sheet")
        XCTAssertFalse(body.contains("vault.addPeople(attendeeNames)"),
                       "the sync addPeople path blocks main while it rewrites markdown")
    }

    func testEnrichmentSheetDraftIsLocalState() throws {
        let src = try Self.source("Parley/UI/AttendeeEnrichmentSheet.swift")
        XCTAssertTrue(src.contains("@State private var rows:"),
                      "draft rows must be view-local so keystrokes do not write pendingEnrichment")
        XCTAssertFalse(src.contains("recording.pendingEnrichment.wrappedValue"),
                       "TextFields must not bind through the controller's @Published enrichment")
        XCTAssertTrue(src.contains("VaultDirectory.suggestMatches"),
                      "suggestions are scored once on appear, not per body")
        XCTAssertFalse(src.contains("if loaded {"),
                       "gating body on loaded left an empty sheet because onAppear sat on the gated content")
        XCTAssertTrue(src.contains(".onAppear(perform: loadDraft)"),
                      "draft copy must run on a view that is always in the tree")
    }

    func testPreviewWaitsUntilEnrichmentDismisses() throws {
        let src = try Self.source("Parley/UI/MainWindowView.swift")
        let body = try Self.body(ofFunction: "private func showPreviewIfSettled() {", in: src)
        XCTAssertTrue(body.contains("pendingEnrichment == nil"),
                      "MarkdownUI preview must not mount underneath the enrichment sheet")
    }

    func testHistoryBadgeIgnoresProgressTicks() throws {
        let src = try Self.source("Parley/UI/MainWindowView.swift")
        XCTAssertTrue(src.contains("offline.$jobs"),
                      "badge must subscribe to jobs, not the whole ObservableObject")
        XCTAssertTrue(src.contains("private let offline = RecordingController.shared.offlineService"),
                      "MainWindowView must not ObservedObject-subscribe to progress ticks")
        XCTAssertFalse(src.contains("offline.objectWillChange"),
                       "objectWillChange includes progress ticks that re-derive every History row")
    }

    func testOfflinePassBarIsItsOwnObserver() throws {
        let src = try Self.source("Parley/UI/MainWindowView.swift")
        XCTAssertTrue(src.contains("private struct OfflinePassBar: View"),
                      "progress UI must not sit in RecordDetailView's observed graph")
        XCTAssertTrue(src.contains("OfflinePassBar()"))
    }

    func testFluidAudioStopYieldsDuringModelTeardown() throws {
        let src = try Self.source("Parley/Transcription/FluidAudioEngine.swift")
        let body = try Self.body(ofFunction: "func stop() async {", in: src)
        XCTAssertTrue(body.contains("await Task.detached {"),
                      "finish()/cleanup() must not occupy the main actor")
        let detached = try Self.index(of: "await Task.detached {", in: body)
        let finish = try Self.index(of: "unified.finish()", in: body)
        XCTAssertLessThan(detached, finish)
    }

    func testAddPeopleInBackgroundExists() throws {
        let src = try Self.source("Parley/Recording/VaultDirectory.swift")
        XCTAssertTrue(src.contains("func addPeopleInBackground(_ rawNames: [String])"),
                      "stop-path contacts must have a background entry point")
        let body = try Self.body(ofFunction: "func addPeopleInBackground(_ rawNames: [String]) {", in: src)
        XCTAssertTrue(body.contains("Task.detached"),
                      "SQLite inserts belong off the main actor")
        XCTAssertTrue(body.contains("exportContactsMarkdown()"),
                      "markdown export must hop back so it cannot race upsertPeople")
    }

    // MARK: - Helpers (same shape as CaptureTeardownTests)

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private struct AnchorNotFound: Error, CustomStringConvertible {
        let needle: String
        var description: String {
            "anchor not found — the guarded code was renamed or removed, so this invariant is no longer checked: \(needle)"
        }
    }

    private static func index(of needle: String, in haystack: String) throws -> Int {
        guard let range = haystack.range(of: needle) else { throw AnchorNotFound(needle: needle) }
        return haystack.distance(from: haystack.startIndex, to: range.lowerBound)
    }

    private static func braceDepth(before offset: Int, in text: String) -> Int {
        let head = text.prefix(offset)
        return head.reduce(0) { depth, ch in
            switch ch {
            case "{": return depth + 1
            case "}": return depth - 1
            default: return depth
            }
        }
    }

    private static func body(ofFunction declaration: String, in src: String) throws -> String {
        guard let start = src.range(of: declaration) else { throw AnchorNotFound(needle: declaration) }
        let rest = src[start.upperBound...]
        guard let next = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    func ") else {
            return String(rest)
        }
        return String(rest[..<next.lowerBound])
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
