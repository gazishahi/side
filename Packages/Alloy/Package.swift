// swift-tools-version: 6.0
import PackageDescription

/// Alloy: Side's editing engine (docs/SIDE_RFC_ALLOY.md). AlloyCore is the document (no AppKit),
/// AlloyRender draws it with Metal, AlloyAppKit is the view.
let package = Package(
    name: "Alloy",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AlloyCore", targets: ["AlloyCore"]),
        .library(name: "AlloyRender", targets: ["AlloyRender"]),
        .library(name: "AlloyAppKit", targets: ["AlloyAppKit"]),
    ],
    targets: [
        .target(name: "AlloyCore", path: "Sources/AlloyCore"),
        .target(name: "AlloyRender", dependencies: ["AlloyCore"], path: "Sources/AlloyRender"),
        .target(name: "AlloyAppKit", dependencies: ["AlloyCore", "AlloyRender"], path: "Sources/AlloyAppKit"),
        .executableTarget(name: "AlloyPlayground", dependencies: ["AlloyCore", "AlloyRender", "AlloyAppKit"], path: "Sources/AlloyPlayground"),
        .executableTarget(name: "AlloyBenchmarks", dependencies: ["AlloyCore"], path: "Sources/AlloyBenchmarks"),
        .testTarget(name: "AlloyCoreTests", dependencies: ["AlloyCore"], path: "Tests/AlloyCoreTests"),
        .testTarget(name: "AlloyRenderTests", dependencies: ["AlloyCore", "AlloyRender"], path: "Tests/AlloyRenderTests"),
        .testTarget(name: "AlloyAppKitTests", dependencies: ["AlloyCore", "AlloyRender", "AlloyAppKit"], path: "Tests/AlloyAppKitTests"),
    ],
    swiftLanguageModes: [.v6]
)
