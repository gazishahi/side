// swift-tools-version: 6.0
import PackageDescription

/// Heron: Side's agent harness — runner, sessions, checkpoints, providers, tools. No AppKit;
/// the app supplies the UI and the workspace through `WorkspaceBridge`.
let package = Package(
    name: "Heron",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Heron", targets: ["Heron"])],
    targets: [
        .target(name: "Heron", path: "Sources/Heron"),
        .testTarget(name: "HeronTests", dependencies: ["Heron"], path: "Tests/HeronTests"),
    ],
    swiftLanguageModes: [.v6]
)
