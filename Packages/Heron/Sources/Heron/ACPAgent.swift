import Foundation

/// An outside agent Side can drive over the Agent Client Protocol (`SIDE_RFC_BYO_HARNESS.md`).
/// The agent runs on the user's own account — Side launches their CLI, never their credentials.
public struct ACPAgent: Equatable, Sendable {
    /// Stable id, stored on the track.
    public let id: String
    public let displayName: String
    /// The executable to find on the login-shell PATH.
    public let binary: String
    public let arguments: [String]
    /// What to run if it isn't installed — shown to copy, never run for the user.
    public let installHint: String

    public init(id: String, displayName: String, binary: String, arguments: [String] = [], installHint: String) {
        self.id = id
        self.displayName = displayName
        self.binary = binary
        self.arguments = arguments
        self.installHint = installHint
    }

    /// The agents Side knows how to launch. Claude Code, Codex and Pi speak ACP through small
    /// adapters; Gemini CLI speaks it natively.
    public static let known: [ACPAgent] = [
        ACPAgent(id: "claude-code", displayName: "Claude Code", binary: "claude-agent-acp",
                 installHint: "npm install -g @agentclientprotocol/claude-agent-acp"),
        ACPAgent(id: "codex", displayName: "Codex", binary: "codex-acp",
                 installHint: "npm install -g @agentclientprotocol/codex-acp"),
        ACPAgent(id: "gemini", displayName: "Gemini CLI", binary: "gemini", arguments: ["--acp"],
                 installHint: "npm install -g @google/gemini-cli"),
        ACPAgent(id: "pi", displayName: "Pi", binary: "pi-acp",
                 installHint: "npm install -g pi-acp (and pi itself: npm install -g @earendil-works/pi-coding-agent)"),
    ]

    public static func agent(id: String?) -> ACPAgent? { known.first { $0.id == id } }
}

/// How to start an agent process: resolved by the app, which owns login-shell PATH lookup.
public struct ACPLaunch: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(executable: URL, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}
