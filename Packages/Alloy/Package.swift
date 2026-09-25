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
        .library(name: "AlloySyntax", targets: ["AlloySyntax"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.25.0"),
        // Swift's grammar ships its generated parser only on these tags; pinned by commit.
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", revision: "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5"),  // 0.7.3-with-generated-files
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        // JavaScript, Python and Lua: the last releases whose manifests list their scanners
        // outright. Later ones check `FileManager.fileExists("src/scanner.c")`, a path relative to
        // wherever SwiftPM evaluates the manifest, which drops the scanner when built as a
        // dependency (undefined external-scanner symbols at link time).
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-lua", exact: "0.3.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.3"),
    ],
    targets: [
        .target(name: "AlloyCore", path: "Sources/AlloyCore"),
        .target(name: "AlloyRender", dependencies: ["AlloyCore"], path: "Sources/AlloyRender"),
        .target(name: "AlloyAppKit", dependencies: ["AlloyCore", "AlloyRender"], path: "Sources/AlloyAppKit"),
        .target(name: "AlloySyntax", dependencies: [
            "AlloyCore", "AlloyRender",
            .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
            .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
            .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
            .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
            .product(name: "TreeSitterPython", package: "tree-sitter-python"),
            .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
            .product(name: "TreeSitterGo", package: "tree-sitter-go"),
            .product(name: "TreeSitterLua", package: "tree-sitter-lua"),
            .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
            .product(name: "TreeSitterC", package: "tree-sitter-c"),
            .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
            .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
            .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
        ], path: "Sources/AlloySyntax", resources: [.copy("Queries")]),
        .executableTarget(name: "AlloyPlayground", dependencies: ["AlloyCore", "AlloyRender", "AlloyAppKit", "AlloySyntax"], path: "Sources/AlloyPlayground"),
        .executableTarget(name: "AlloyBenchmarks", dependencies: ["AlloyCore"], path: "Sources/AlloyBenchmarks"),
        .testTarget(name: "AlloyCoreTests", dependencies: ["AlloyCore"], path: "Tests/AlloyCoreTests"),
        .testTarget(name: "AlloyRenderTests", dependencies: ["AlloyCore", "AlloyRender"], path: "Tests/AlloyRenderTests"),
        .testTarget(name: "AlloySyntaxTests", dependencies: ["AlloyCore", "AlloyRender", "AlloySyntax"], path: "Tests/AlloySyntaxTests"),
        .testTarget(name: "AlloyAppKitTests", dependencies: ["AlloyCore", "AlloyRender", "AlloyAppKit"], path: "Tests/AlloyAppKitTests"),
    ],
    swiftLanguageModes: [.v6]
)
