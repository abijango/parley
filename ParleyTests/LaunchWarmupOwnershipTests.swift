import XCTest

final class LaunchWarmupOwnershipTests: XCTestCase {
    func testWarmupIsInvokedFromAppDelegateNotTheRecordTab() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDelegate = try String(
            contentsOf: root.appendingPathComponent("Parley/App/AppDelegate.swift"), encoding: .utf8)
        let recordTab = try String(
            contentsOf: root.appendingPathComponent("Parley/UI/MainWindowView.swift"), encoding: .utf8)
        XCTAssertTrue(appDelegate.contains("launchWarmup()"), "App launch must start warmup")
        XCTAssertFalse(recordTab.contains("launchWarmup"), "Record tab appearing must not own warmup")
        let controller = try String(
            contentsOf: root.appendingPathComponent("Parley/Recording/RecordingController.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            controller.contains("if AppInfo.isXCTestHost"),
            "TEST_HOST must not run launch warmup (ANE compile + crash-recovery wipe)")
    }

    func testFluidPreloadPreparesStreamingModelsInsteadOfPresenceOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controller = try String(
            contentsOf: root.appendingPathComponent("Parley/Recording/RecordingController.swift"),
            encoding: .utf8)
        let engine = try String(
            contentsOf: root.appendingPathComponent("Parley/Transcription/FluidAudioEngine.swift"),
            encoding: .utf8)
        XCTAssertTrue(controller.contains("fluidModels.prepare()"))
        XCTAssertTrue(engine.contains("takePrepared(matching:"))
        XCTAssertFalse(
            controller.contains("engine loads its own model at record time"),
            "preloadModel must not document presence-only Fluid warmup")
    }
}
