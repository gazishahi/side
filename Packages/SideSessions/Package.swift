// swift-tools-version: 6.0
import PackageDescription

/// Side Sessions: terminals that outlive Side (docs/SIDE_RFC_SESSION_RESTORE.md). Each terminal is
/// owned by a keeper process, `SideSessionKeeper`, that holds its PTY and a headless libghostty-vt
/// terminal; `SideSessionsKit` is what Side and the keeper share: the wire format, the records and
/// the run directory, and the client side of a connection.
let package = Package(
    name: "SideSessions",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SideSessionsKit", targets: ["SideSessionsKit"]),
        .executable(name: "SideSessionKeeper", targets: ["SideSessionKeeper"]),
    ],
    targets: [
        .target(name: "SideSessionsKit", path: "Sources/SideSessionsKit"),
        // forkpty and exec in C: the child of a fork may only call async-signal-safe functions,
        // and a controlling terminal on macOS needs TIOCSCTTY, which posix_spawn can't do.
        .target(name: "CKeeperSpawn", path: "Sources/CKeeperSpawn"),
        .executableTarget(name: "SideSessionKeeper", dependencies: ["SideSessionsKit", "CKeeperSpawn", "GhosttyVt"],
                          path: "Sources/SideSessionKeeper",
                          // One thread, one kqueue loop: there is no concurrency to check.
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // Built by scripts/build-ghostty-vt.sh from the pinned Ghostty commit; git-ignored.
        .binaryTarget(name: "GhosttyVt", path: "GhosttyVt.xcframework"),
        .testTarget(name: "SideSessionsTests", dependencies: ["SideSessionsKit", "SideSessionKeeper", "GhosttyVt"], path: "Tests/SideSessionsTests"),
    ],
    swiftLanguageModes: [.v6]
)
