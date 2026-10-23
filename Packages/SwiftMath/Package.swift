// swift-tools-version: 5.7
// SwiftMath 1.7.3 (github.com/mgriebling/SwiftMath, MIT), vendored for Side's Markdown preview
// with only the Latin Modern math font: see README.md.

import PackageDescription

let package = Package(
    name: "SwiftMath",
    platforms: [.macOS("12.0")],
    products: [
        .library(name: "SwiftMath", targets: ["SwiftMath"]),
    ],
    targets: [
        .target(name: "SwiftMath", resources: [.copy("mathFonts.bundle")]),
        .testTarget(name: "SwiftMathTests", dependencies: ["SwiftMath"]),
    ]
)
