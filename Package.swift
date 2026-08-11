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
        .library(name: "KVLoggingLocal", targets: ["KVLoggingLocal"])
    ],
    targets: [
        .target(name: "KVLoggingKit"),
        .target(name: "KVLoggingSecurity"),
        .target(
            name: "KVLoggingLocal",
            dependencies: ["KVLoggingKit", "KVLoggingSecurity"]
        ),
        .testTarget(
            name: "KVLoggingKitTests",
            dependencies: ["KVLoggingKit"]
        ),
        .testTarget(
            name: "KVLoggingSecurityTests",
            dependencies: ["KVLoggingSecurity"]
        ),
        .testTarget(
            name: "KVLoggingLocalTests",
            dependencies: ["KVLoggingKit", "KVLoggingSecurity", "KVLoggingLocal"]
        )
    ],
    swiftLanguageModes: [.v6]
)
