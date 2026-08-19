import Foundation

/// Where a checkpoint's changes came from — deliberately thin today (just enough to answer "what
/// model, whose key"); a real instruction-source summary (custom system prompts, skills) is a
/// later concern once those exist at all.
struct AgentProvenance: Codable {
    let providerId: String
    let modelId: String
    let instructionSourceSummary: String
}

/// A durable record of one approved batch of changes — the constitution's "an agent run does not
/// equal a branch; it produces a durable checkpoint." Backed by a real git commit on the track's
/// own branch (in its own worktree), created automatically the moment every proposal in a batch
/// is resolved, provided at least one was actually applied or executed — never before approval,
/// never as a substitute for the approval click itself, just bookkeeping that follows it.
struct Checkpoint: Codable, Identifiable {
    let id: UUID
    let trackKey: String
    let agentSessionId: UUID
    let declaredIntent: String
    let changedFilePaths: [String]
    let commandsRun: [String]
    let provenance: AgentProvenance
    /// `nil` only for a checkpoint with zero file changes — e.g. every command in the batch ran
    /// but touched nothing, or ran and then reverted its own edits.
    let gitCommitSHA: String?
    let createdAt: Date

    init(trackKey: String, agentSessionId: UUID, declaredIntent: String, changedFilePaths: [String], commandsRun: [String], provenance: AgentProvenance, gitCommitSHA: String?) {
        self.id = UUID()
        self.trackKey = trackKey
        self.agentSessionId = agentSessionId
        self.declaredIntent = declaredIntent
        self.changedFilePaths = changedFilePaths
        self.commandsRun = commandsRun
        self.provenance = provenance
        self.gitCommitSHA = gitCommitSHA
        self.createdAt = Date()
    }
}
