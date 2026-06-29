// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DroidMatchMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DroidMatchCore", targets: ["DroidMatchCore"]),
        .executable(name: "droidmatch-harness", targets: ["DroidMatchHarness"])
    ],
    targets: [
        .target(name: "DroidMatchCore"),
        .executableTarget(
            name: "DroidMatchHarness",
            dependencies: ["DroidMatchCore"]
        ),
        .testTarget(
            name: "DroidMatchCoreTests",
            dependencies: ["DroidMatchCore"]
        )
    ]
)
