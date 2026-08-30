import Foundation

/// A shell command an agent has asked to run but that has **not** executed — the `run_shell_command`
/// analog of `ProposedEdit`. Requires approval by default (see `Track.autoRunCommands` for the
/// per-track opt-out); either way, execution always happens by typing into the track's own real,
/// visible Run session, never a hidden `Process` — see `WorkspaceBridge.runShellCommand`.
struct ProposedCommand: Identifiable {
    let id: UUID
    let toolUseId: String
    let command: String
    /// Classified once, at proposal time, from the command text — see `CommandRiskClassifier`.
    /// A `.destructive` command never auto-runs even on a track with `autoRunCommands` on; see
    /// `AgentRunner.handleToolOutcomes`.
    let riskLevel: CommandRiskLevel
    /// Set when this command came from `run_task` — the name of the task it is. Carried through
    /// so the result can be recorded as verification on the checkpoint, and so the approval card
    /// can say "Run test" rather than showing a command line the user has to parse.
    let taskName: String?

    init(toolUseId: String, command: String, taskName: String? = nil) {
        self.id = UUID()
        self.toolUseId = toolUseId
        self.command = command
        self.taskName = taskName
        self.riskLevel = CommandRiskClassifier.classify(command)
    }
}
