// swift-tools-version: 6.0
import PackageDescription

// Setup E: Side's shipping terminal engine, measured by the same harness as A–D. SideTerminal
// (libghostty-vt, parsed on the reader's thread) drawn by AlloyTerminal, both linked from this
// repository's packages, so E measures the code Side runs, with its Tier 1 features, where C is
// the Phase 0 prototype renderer. A package of its own because SideSessions brings its own
// GhosttyVt binary target, which TermBench's can't share a build with. The harness's sources
// are TermBench's, through a symlink.
let package = Package(
    name: "TermBenchE",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../../Packages/Alloy"),
        .package(path: "../../../Packages/SideSessions"),
    ],
    targets: [
        .target(name: "Harness", path: "Sources/Harness"),
        .executableTarget(name: "TermBenchE", dependencies: [
            "Harness",
            .product(name: "AlloyTerminal", package: "Alloy"),
            .product(name: "SideTerminal", package: "SideSessions"),
        ], path: "Sources/TermBenchE"),
    ],
    swiftLanguageModes: [.v5]
)
