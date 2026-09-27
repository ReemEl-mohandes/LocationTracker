// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocationTrackerClient",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project contains exactly one library product: the app.
        .library(
            name: "LocationTrackerClient",
            targets: ["LocationTrackerClient"]
        ),
    ],
    dependencies: [
        // The pure, platform-agnostic Model + interfaces. Lives in its own package so it
        // compiles and unit-tests on Linux/WSL (`cd Core && swift test`); the app depends on it.
        .package(path: "Core"),
    ],
    targets: [
        .target(
            name: "LocationTrackerClient",
            dependencies: [
                .product(name: "LocationTrackerCore", package: "Core"),
            ],
            // The delegate/Task hopping in LocationTracker and SessionStore is written for
            // Swift 5 concurrency checking, not Swift 6's strict mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
