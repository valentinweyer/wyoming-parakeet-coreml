// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WyomingParakeet",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned exact, not `from:` — a headless background service must not
        // silently pick up a minor bump that changes model-loading behavior.
        // Verified against this exact revision during Phase A conversion work.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.2")
    ],
    targets: [
        .executableTarget(
            name: "WyomingParakeet",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .testTarget(
            name: "WyomingParakeetTests",
            dependencies: ["WyomingParakeet"]
        )
    ]
)
