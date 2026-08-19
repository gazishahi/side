import Foundation

/// A shell command an agent has asked to run but that has **not** executed — the `run_shell_command`
/// analog of `ProposedEdit`. Requires approval by default (see `Track.autoRunCommands` for the
/// per-track opt-out); either way, execution always happens by typing into the track's own real,
/// visible Run session, never a hidden `Process` — see `WorkspaceBridge.runShellCommand`.
struct ProposedCommand: Identifiable {
    let id: UUID
    let toolUseId: String
    let command: String

    init(toolUseId: String, command: String) {
        self.id = UUID()
        self.toolUseId = toolUseId
        self.command = command
    }
}
