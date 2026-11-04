// swift-tools-version: 6.0
import PackageDescription

/// Heron: Side's own agent — its runner, model providers and tools — being retired
/// (docs/SIDE_RFC_HERON_RETIREMENT.md). What outside agents share with it is `SideAgents`, which
/// it re-exports so `import Heron` still sees all of it until Side imports `SideAgents` itself.
let package = Package(
    name: "Heron",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Heron", targets: ["Heron"])],
    dependencies: [.package(path: "../SideAgents")],
    targets: [
        .target(name: "Heron", dependencies: [.product(name: "SideAgents", package: "SideAgents")], path: "Sources/Heron"),
        // Fixtures/: projects the benchmark copies and works in, not code of the tests'.
        .testTarget(name: "HeronTests", dependencies: ["Heron", .product(name: "SideAgents", package: "SideAgents")], path: "Tests/HeronTests", exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
