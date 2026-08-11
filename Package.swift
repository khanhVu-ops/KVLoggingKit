// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KVLoggingKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v13)
    ],
    products: [
        .library(name: "KVLoggingKit", targets: ["KVLoggingKit"]),
        .library(name: "KVLoggingSecurity", targets: ["KVLoggingSecurity"]),
        .library(name: "KVLoggingLocal", targets: ["KVLoggingLocal"]),
        .library(name: "KVLoggingRemote", targets: ["KVLoggingRemote"]),
        .library(name: "KVLoggingTesting", targets: ["KVLoggingTesting"]),
        .library(name: "KVLoggingUIKit", targets: ["KVLoggingUIKit"]),
        .library(name: "KVLoggingSwiftUI", targets: ["KVLoggingSwiftUI"])
    ],
    targets: [
        .target(name: "KVLoggingKit"),
        .target(name: "KVLoggingSecurity"),
        .target(
            name: "KVLoggingLocal",
            dependencies: ["KVLoggingKit", "KVLoggingSecurity"]
        ),
        .target(
            name: "KVLoggingRemote",
            dependencies: ["KVLoggingKit", "KVLoggingSecurity"]
        ),
        .target(
            name: "KVLoggingTesting",
            dependencies: ["KVLoggingKit"]
        ),
        .target(
            name: "KVLoggingUIKit",
            dependencies: ["KVLoggingKit"]
        ),
        .target(
            name: "KVLoggingSwiftUI",
            dependencies: ["KVLoggingKit"]
        ),
        .testTarget(
            name: "KVLoggingKitTests",
            dependencies: ["KVLoggingKit", "KVLoggingTesting"]
        ),
        .testTarget(
            name: "KVLoggingSecurityTests",
            dependencies: ["KVLoggingSecurity"]
        ),
        .testTarget(
            name: "KVLoggingLocalTests",
            dependencies: ["KVLoggingKit", "KVLoggingSecurity", "KVLoggingLocal"]
        ),
        .testTarget(
            name: "KVLoggingRemoteTests",
            dependencies: ["KVLoggingKit", "KVLoggingSecurity", "KVLoggingRemote"]
        ),
        .testTarget(
            name: "KVLoggingTestingTests",
            dependencies: ["KVLoggingKit", "KVLoggingTesting"]
        )
    ],
    swiftLanguageModes: [.v6]
)
