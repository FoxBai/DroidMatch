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
                .linkedFramework("Security")
            ]
        ),
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
