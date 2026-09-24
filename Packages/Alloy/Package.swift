// swift-tools-version: 6.0
import PackageDescription

/// Alloy: Side's editing engine (docs/SIDE_RFC_ALLOY.md). AlloyCore is the document, with no
/// AppKit; AlloyRender and AlloyAppKit follow in later steps.
let package = Package(
    name: "Alloy",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AlloyCore", targets: ["AlloyCore"]),
    ],
    targets: [
        .target(name: "AlloyCore", path: "Sources/AlloyCore"),
        .executableTarget(name: "AlloyBenchmarks", dependencies: ["AlloyCore"], path: "Sources/AlloyBenchmarks"),
        .testTarget(name: "AlloyCoreTests", dependencies: ["AlloyCore"], path: "Tests/AlloyCoreTests"),
    ],
    swiftLanguageModes: [.v6]
)
