// swift-tools-version: 6.0
import PackageDescription

// Pure, platform-agnostic Model + interfaces for the Location Tracker client.
// No CoreLocation / UIKit / Security imports, so it compiles and TESTS on Linux/WSL via
// `swift test`. The iOS app (../Package.swift) depends on this and supplies the concrete
// service implementations. This is the testable core of the MVC split.
let package = Package(
    name: "LocationTrackerCore",
    products: [
        .library(name: "LocationTrackerCore", targets: ["LocationTrackerCore"]),
    ],
    targets: [
        .target(name: "LocationTrackerCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "LocationTrackerCoreTests",
            dependencies: ["LocationTrackerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
