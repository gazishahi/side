import Foundation

/// The narrow slice of a window's Make stage an `AgentRunner` needs to read live editor state
/// and land an approved edit where a human is actually looking. Resolved fresh on every use via
/// `ProjectContext.bridge(forTrackKey:)`, never captured once — a runner now outlives any one
/// window (it survives a stage switch, a track switch, even the window that started it closing
/// while another window keeps the project open), so "the" Make tab to write into isn't a fixed
/// fact about a runner the way it was when Think lived inside one window's view controller.
/// `@unchecked Sendable`: every instance is built and consumed entirely on the main actor (it's
/// resolved fresh per-use from `ProjectContext.bridge(forTrackKey:)`, itself `@MainActor`), so
/// there's no actual cross-thread mutation risk — same reasoning `LSPManager` and
/// `ProviderRegistryStore` already use for similar single-threaded-in-practice types.
struct WorkspaceBridge: @unchecked Sendable {
    var liveBufferProvider: (URL) -> String?
    var applyEditIntoOpenTab: (URL, String) -> Bool
    var onRevealFileRequested: (URL) -> Void
    /// Types a `run_shell_command` proposal into the track's own real Run session once approved
    /// (or auto-run). Unlike the three fields above, this is **not** gated on "is the key window
    /// showing this exact track" — a track's terminal session persists independent of what's
    /// currently displayed (same as Run already does for ordinary background processes), so any
    /// window with this project open can serve it. See `ProjectContext.bridge(forTrackKey:)`.
    var runShellCommand: (String, @escaping (String) -> Void) -> Void

    /// No window is currently both key and showing this track — reads fall back to disk, writes
    /// go straight to disk via `ProposedEditApplier`, and there's nowhere to jump to. Every one
    /// of these fallbacks was already the pre-extraction behavior for "Make doesn't have this
    /// file open," so a detached runner degrades to exactly that, never to a crash or a silently
    /// dropped edit. `runShellCommand` has nothing to fall back to at all — no window means no
    /// terminal to type into.
    static let none = WorkspaceBridge(
        liveBufferProvider: { _ in nil },
        applyEditIntoOpenTab: { _, _ in false },
        onRevealFileRequested: { _ in },
        runShellCommand: { _, completion in completion("No window is open for this project — nowhere to run this command.") }
    )
}

/// Conformed to by `ShellViewController` — one instance per window. `ProjectContext` keeps a
/// weak registry of these so `bridge(forTrackKey:)` can find whichever window, if any, is both
/// key and currently showing a given track. Without the `isKeyWindow` check, an agent running on
/// a track shown in a background window could apply its edit into a Make tab the user is
/// actively looking at in a *different*, focused window showing a different track — real data
/// loss once concurrent runners exist.
@MainActor
protocol WorkspaceBridgeHost: AnyObject {
    var bridgeTrackKey: String? { get }
    var isKeyWindow: Bool { get }
    func liveBufferContent(for url: URL) -> String?
    func applyApprovedEdit(url: URL, newContent: String) -> Bool
    func revealAfterApply(_ url: URL)
    func runShellCommand(_ command: String, trackKey: String, completion: @escaping (String) -> Void)
}
