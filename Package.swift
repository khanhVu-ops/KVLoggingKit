// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KVLoggingKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v13)
    ],
    products: [
        .library(name: "KVLoggingKit", targets: ["KVLoggingKit"])
    ],
    targets: [
        .target(name: "KVLoggingKit"),
        .testTarget(
            name: "KVLoggingKitTests",
            dependencies: ["KVLoggingKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
