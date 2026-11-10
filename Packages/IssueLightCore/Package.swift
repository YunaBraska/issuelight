// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "IssueLightCore",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(name: "IssueLightCore", targets: ["IssueLightCore"]),
    ],
    targets: [
        .target(name: "IssueLightCore"),
        .testTarget(name: "IssueLightCoreTests", dependencies: ["IssueLightCore"]),
    ],
    swiftLanguageModes: [.v5]
)
