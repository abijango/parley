// swift-tools-version: 6.0
import PackageDescription

// Isolated Phase-1 smoke test for FluidAudio (Parakeet ASR + diarization).
// Not part of the app target — run with `swift run FluidSmoke <path-to-wav>`.
let package = Package(
    name: "FluidSmoke",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.8")
    ],
    targets: [
        .executableTarget(
            name: "FluidSmoke",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
