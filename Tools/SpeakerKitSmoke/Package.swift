// swift-tools-version: 5.9
import PackageDescription

// Throwaway spike (plan T0.1/T0.2): probe Argmax SpeakerKit's API — confirm the
// diarization result exposes per-speaker centroid embeddings (dimension), measure
// diarization time/RTFx and the model footprint, before integrating into Macsribe.
let package = Package(
    name: "SpeakerKitSmoke",
    platforms: [.macOS(.v13)],
    dependencies: [
        // NOTE: the per-speaker embedding API (speakerCentroidEmbeddings /
        // nearestSpeakerCentroid) is on `main`, not yet in the v1.0.0 release tag.
        // Pin main for the spike to validate the embedding path end-to-end.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "SpeakerKitSmoke",
            dependencies: [
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        )
    ]
)
