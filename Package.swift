// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bton",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Voice input (Settings > Voice): Whisper on the Neural Engine. The only third-party package;
        // pinned to the commit that was read in the inspection sandbox (the one after v1.1.1).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", revision: "9f99b5cb6a907730543823ad271b82532782a899"),
    ],
    targets: [
        // Everything testable without a UI: models, GitHub decoding, cost, schedule.
        .target(name: "BtonCore"),
        .executableTarget(name: "Bton", dependencies: ["BtonCore", .product(name: "WhisperKit", package: "WhisperKit")]),
        // The `bton` command (installed under that name): leases for scripts and manual
        // sessions, and the flow's verdict on a repo's open PRs.
        .executableTarget(name: "BtonCLI", dependencies: ["BtonCore"]),
        .testTarget(name: "BtonCoreTests", dependencies: ["BtonCore"]),
    ]
)
