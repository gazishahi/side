// swift-tools-version: 6.0
import PackageDescription

// Session keepers against the RFC's targets (docs/SIDE_RFC_SESSION_RESTORE.md, Measures): latency
// and throughput through a keeper against a direct PTY, reattach time, memory and idle CPU.
// SwiftTerm is here to time replaying a reattach snapshot, which Side does on its main thread.
let package = Package(
    name: "SessionsBench",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/SideSessions"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        .executableTarget(name: "SessionsBench", dependencies: [.product(name: "SideSessionsKit", package: "SideSessions"), "SwiftTerm"],
                          path: "Sources/SessionsBench", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
