import XCTest
@testable import Parley

final class LogRotationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-rotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testActiveLogRotatesOnlyPastTheLimit() {
        let small = LogRotation.Limits(maxActiveBytes: 100, maxArchives: 4, plainFreezeCaptures: 1)
        XCTAssertEqual(
            LogRotation.plan(entries: [.init(path: "parley.log", bytes: 100)], limits: small),
            [.rotate("parley.log")])
        XCTAssertTrue(
            LogRotation.plan(entries: [.init(path: "parley.log", bytes: 99)], limits: small).isEmpty)
        XCTAssertEqual(
            LogRotation.plan(entries: [.init(path: "freeze.log", bytes: 100)], limits: small),
            [.rotate("freeze.log")])
    }

    func testHandMadeArchiveIsLeftAloneAndOnlyOurZipsAreCapped() {
        let limits = LogRotation.Limits(maxActiveBytes: 5_000_000, maxArchives: 2, plainFreezeCaptures: 1)
        let entries = [
            LogRotation.Entry(path: "archive/parley-logs-until-2026-09-01.zip", bytes: 10),
            LogRotation.Entry(path: "archive/parley-2026-10-01-120000.log.zip", bytes: 10),
            LogRotation.Entry(path: "archive/parley-2026-10-02-120000.log.zip", bytes: 10),
            LogRotation.Entry(path: "archive/parley-2026-10-03-120000.log.zip", bytes: 10),
            LogRotation.Entry(path: "notes.txt", bytes: 10),
        ]
        XCTAssertEqual(
            LogRotation.plan(entries: entries, limits: limits),
            [.delete("archive/parley-2026-10-01-120000.log.zip")])
    }

    func testOlderFreezeCapturesAreZippedAndTheNewestStaysPlain() {
        let limits = LogRotation.Limits(maxActiveBytes: 5_000_000, maxArchives: 8, plainFreezeCaptures: 1)
        let entries = [
            LogRotation.Entry(path: "freeze-2026-09-07-175227.txt", bytes: 10),
            LogRotation.Entry(path: "freeze-2026-09-11-113149.txt", bytes: 10),
            LogRotation.Entry(path: "freeze-2026-09-28-155035.txt.zip", bytes: 10),
            LogRotation.Entry(path: "freeze.log", bytes: 10),
        ]
        XCTAssertEqual(
            LogRotation.plan(entries: entries, limits: limits),
            [
                .zip("freeze-2026-09-07-175227.txt"),
                .zip("freeze-2026-09-11-113149.txt"),
            ])
    }

    func testMaintainZipsTheRotatedLogAndReadsBack() throws {
        let limits = LogRotation.Limits(maxActiveBytes: 32, maxArchives: 4, plainFreezeCaptures: 1)
        let active = directory.appendingPathComponent("parley.log")
        let text = String(repeating: "line\n", count: 20)
        try Data(text.utf8).write(to: active)
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        LogRotation.maintain(directory: directory, limits: limits, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
        let zips = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("archive").path)
        let zipName = try XCTUnwrap(zips.first { $0.hasSuffix(".log.zip") })
        let unzipped = try unzip(directory.appendingPathComponent("archive").appendingPathComponent(zipName))
        XCTAssertEqual(String(data: unzipped, encoding: .utf8), text)
    }

    func testMaintainZipsOlderFreezeDumpsAndKeepsTheNewestPlain() throws {
        let limits = LogRotation.Limits(maxActiveBytes: 5_000_000, maxArchives: 4, plainFreezeCaptures: 1)
        try "old".write(to: directory.appendingPathComponent("freeze-2026-09-07-175227.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: directory.appendingPathComponent("freeze-2026-09-28-155035.txt"), atomically: true, encoding: .utf8)
        try "keep".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        LogRotation.maintain(directory: directory, limits: limits, now: Date())

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("freeze-2026-09-28-155035.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("freeze-2026-09-07-175227.txt").path))
        let zipped = directory.appendingPathComponent("freeze-2026-09-07-175227.txt.zip")
        XCTAssertEqual(try String(data: unzip(zipped), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("notes.txt"), encoding: .utf8), "keep")
    }

    func testZippedFreezeCapturesCountTowardRetention() throws {
        var config = MainActorWatchdog.Config()
        config.retainedCaptures = 2
        config.directory = directory
        config.mirrorToAppLog = false
        let watchdog = MainActorWatchdog(config: config)

        let names = [
            "freeze-2026-08-10-120001.txt.zip",
            "freeze-2026-08-10-120002.txt",
            "freeze-2026-08-10-120003.txt.zip",
            "freeze-2026-08-10-120004.txt",
        ]
        for name in names {
            try "stack".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "log".write(to: directory.appendingPathComponent("freeze.log"), atomically: true, encoding: .utf8)

        watchdog.pruneCaptures()

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left, ["freeze-2026-08-10-120003.txt.zip", "freeze-2026-08-10-120004.txt", "freeze.log"])
    }

    private func unzip(_ zip: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zip.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }
}
