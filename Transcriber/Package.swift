// swift-tools-version: 5.10
import PackageDescription

// familiar-speech: speech to text with Parakeet Unified 0.6B (English) on the Neural Engine, through FluidAudio; also
// echo cancellation (LocalVQE) and speaker separation for meetings.
// A package of its own because FluidAudio needs macOS 14 and Familiar runs on 13: SwiftPM can't give one target a
// newer minimum than the package, so the app stays on 13 and this helper is a separate binary (like llama-server)
// that `fam transcribe` hands over to. Build: swift build -c release --package-path Transcriber
//   FluidAudio  Apache 2.0, pinned to an exact release.
//   The models are downloaded by the app, not built in; their licenses and credits are in CREDITS.md (Parakeet:
//   NVIDIA Open Model License).
let package = Package(
    name: "Transcriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(name: "familiar-speech", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)
