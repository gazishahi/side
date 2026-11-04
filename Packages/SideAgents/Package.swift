// swift-tools-version: 6.0
import PackageDescription

/// Side Agents: what Side runs outside agents on (docs/SIDE_RFC_HERON_RETIREMENT.md, step 2) —
/// the harness protocol, the Agent Client Protocol client, sessions and their transcripts,
/// checkpoints, usage, the Library's stores, Side's MCP tool server, and the git and process
/// utilities under them. No AppKit; the app supplies the UI and the workspace through
/// `WorkspaceBridge`. Heron's own agent depends on it until it's retired.
let package = Package(
    name: "SideAgents",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SideAgents", targets: ["SideAgents"])],
    targets: [
        .target(name: "SideAgents", path: "Sources/SideAgents"),
        .testTarget(name: "SideAgentsTests", dependencies: ["SideAgents"], path: "Tests/SideAgentsTests"),
    ],
    swiftLanguageModes: [.v6]
)
