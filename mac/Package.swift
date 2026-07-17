// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DroidMatchMac",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DroidMatchCore", targets: ["DroidMatchCore"]),
        .library(name: "DroidMatchPresentation", targets: ["DroidMatchPresentation"]),
        .executable(name: "DroidMatch", targets: ["DroidMatchApp"]),
        .executable(name: "droidmatch-harness", targets: ["DroidMatchHarness"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1")
    ],
    targets: [
        .target(
            name: "DroidMatchCore",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            linkerSettings: [
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "DroidMatchHarness",
            dependencies: ["DroidMatchCore"]
        ),
        .target(
            name: "DroidMatchPresentation",
            dependencies: ["DroidMatchCore"]
        ),
        .target(
            name: "DroidMatchAppSupport",
            dependencies: ["DroidMatchCore", "DroidMatchPresentation"]
        ),
        .executableTarget(
            name: "DroidMatchApp",
            dependencies: ["DroidMatchCore", "DroidMatchPresentation", "DroidMatchAppSupport"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "DroidMatchCoreTests",
            dependencies: ["DroidMatchCore"]
        ),
        .testTarget(
            name: "DroidMatchPresentationTests",
            dependencies: ["DroidMatchCore", "DroidMatchPresentation"]
        ),
        .testTarget(
            name: "DroidMatchAppSupportTests",
            dependencies: ["DroidMatchAppSupport", "DroidMatchCore"]
        ),
        .testTarget(
            name: "DroidMatchHarnessTests",
            dependencies: ["DroidMatchHarness"]
        )
    ]
)
