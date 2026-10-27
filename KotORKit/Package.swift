// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KotORKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Aurora", targets: ["Aurora"]),
        .library(name: "KotORSave", targets: ["KotORSave"]),
    ],
    targets: [
        .target(name: "Aurora"),
        .target(name: "KotORSave", dependencies: ["Aurora"]),
        .target(name: "TestFixtures", dependencies: ["Aurora"], path: "Tests/TestFixtures"),
        .testTarget(name: "AuroraTests", dependencies: ["Aurora", "TestFixtures"]),
        .testTarget(name: "KotORSaveTests", dependencies: ["KotORSave", "Aurora", "TestFixtures"]),
    ]
)
