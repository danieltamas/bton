// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bton",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything testable without a UI: models, GitHub decoding, cost, schedule.
        .target(name: "BtonCore"),
        .executableTarget(name: "Bton", dependencies: ["BtonCore"]),
        // The `bton` command (installed under that name): leases for scripts and manual
        // sessions, and the flow's verdict on a repo's open PRs.
        .executableTarget(name: "BtonCLI", dependencies: ["BtonCore"]),
        .testTarget(name: "BtonCoreTests", dependencies: ["BtonCore"]),
    ]
)
