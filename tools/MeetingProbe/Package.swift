// swift-tools-version: 5.9
import PackageDescription

// Investigation spike: when CallDetector fires (a conferencing app starts
// capturing the mic), what meeting metadata is observable from outside the
// process? Dumps every candidate source side by side — Core Audio mic
// snapshot, CGWindowList titles, Accessibility window titles, browser tabs
// via AppleScript, and overlapping EventKit calendar events — so we can pick
// the title/attendee sources worth wiring into the app.
let package = Package(
    name: "MeetingProbe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MeetingProbe",
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist so TCC has usage descriptions for the
                // Calendar prompt (CLI binaries have no bundle).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MeetingProbe/Info.plist",
                ])
            ]
        )
    ]
)
