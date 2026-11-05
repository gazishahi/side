# Retiring Heron's agent

Status: built (2026-11-04: the owner decided to retire Heron, and took the three
recommendations below). All six steps done.

Symbols: `DefaultAgent`, `CheckpointCommit`, `AgentRunnerManager`, `RetiredHeronHarness`, `SideToolServer`.

## What goes, what stays

`Packages/Heron` holds two things. **Heron's agent** goes: the `AgentRunner` loop, the model
providers, its tools (`ToolExecutor`, `fetch_url`, search, streaming edit previews), the
efficiency work and the benchmark. **The plumbing outside agents run on** stays, moved into Side:
`Harness`, `ACPHarness`, `AgentRunnerManager`, `AgentSessionStore`, `RunTranscriptEntry`,
checkpoints, usage, the Library's stores, `SideToolServer`, and utilities that only happen to
live there (`GitPaths`, `SpawnEnvironment`, `HeronDefaults`, `JSONStore`, …).

## Heron-only features, and what happens to each

| Feature | Plan |
|---|---|
| Agent modes (Ask/Plan/Build tool scope) | Removed. Outside agents have their own modes (Claude Code's plan mode), already shown as the agent's own option. Today Shift+Tab and `/plan` change a stored scope that outside agents ignore. |
| Provider, model and effort pickers; Settings › Providers | Removed. Outside agents report their own options. |
| "Set up a model…" readiness, first run's "Choose a model" | Replaced by "install or pick an agent" (`AgentAvailability` already detects them). |
| Compaction and Undo, edit-and-resend | Removed; outside agents manage their own context. |
| Run's task chips (`proposeUserTask`) | Removed for now; later a `run_task` tool in Side's MCP server. |
| Heron's shell-command cards, risk classifier, allowlist | Removed; outside agents use ACP terminals and their own permission requests, already drawn. |
| Diagnostics and debugger state for the agent | Not offered to outside agents today. Added to `SideToolServer` as tools: the editor's abilities offered to any agent. |
| Track ports in the prompt | Added to the MCP server's instructions. |
| Project rules file and its acknowledgement gate | Removed. The gate runs before every send, even to outside agents, which never read the file. |
| Autonomy (Manual/Guarded/Full) | Kept: ACP uses it for unannounced writes. Guarded's command allowlist goes. |
| Inline Instruct's Change card | Kept, reworked: it shows a card only when an agent writes through Side under Manual or Guarded. |
| Tracks progress, badges, activity pill, usage | Already work for any agent; only wording changes ("Side's agent · model"). |

## Things to untangle first

- **Checkpoint commits live in `AgentRunner.swift`** (`stageAndCommitReporting`,
  `commitPathsInIsolatedIndex`, `lineDelta`, …), and `ACPHarness` calls them. They move out
  before `AgentRunner` goes.
- `SideToolServer` uses `ToolExecutor.changedPaths`, and coordination's MCP tools are built from
  Heron's `ToolSpec`/`JSONValue` types.
- `AgentSessionStore.swift` mixes Heron sessions with checkpoints, outside logs and accounts.
- `AgentRunnerManager` takes Heron's model selection and effort; `ACPHarness` uses Heron's
  `Watchdog` and `ContextBudget.Status`.
- **The default.** A track with no agent set is Heron (`Track.harnessId == nil`), so every new
  track is Heron, and sub-tracks default to `"heron"`. There is no default-agent setting.

## Steps

1. **A default agent. Built 2026-11-04.** Settings › Agents › Default agent: Automatic (the first
   installed of Claude Code, Codex, …) or one chosen. New tracks and subtracks take it, and the
   coordinator offers it first. The base (no track) has an agent of its own per project: the
   default, or Heron where it already has Heron conversations, until one is chosen from its
   session pill. Tracks already on Heron stay there with their conversations; they move in
   step 3, when Heron's conversations become read-only. Tests never detect an agent, so none
   starts a real one.
2. **Move the plumbing. Built 2026-11-04.** Checkpoint commits out of `AgentRunner`
   (`CheckpointCommit`); 58 shared files into `Packages/SideAgents`, with 29 test files (143
   tests). Heron keeps its runner, providers, tools and streaming code (12 files), depends on
   SideAgents and re-exports it, so Side's `import Heron` still sees everything. One change from
   the plan: `AgentRunnerManager` stays in Heron until step 4, since it's what makes Heron's runner
   when a track has no outside agent. Side switching to `import SideAgents` comes with step 4.
3. **Remove the UI. Built 2026-11-04.** A track on Heron with nothing of Heron's to read moves
   to the default agent when Agent opens it. One with Heron conversations keeps them to read: the
   composer is read-only, "Continue on <agent>" (or "Set Up an Agent…") stands where Send was,
   and the agent menus offer "Heron (retired), to read" only where there's something to read.
   Gone: modes (Shift+Tab, /ask /plan /build, the scope tint), Heron's session popover (model,
   effort, scope), Settings › Providers, Compact and /compact, the project-rules gate and
   /rules, first run's model step (now "Set up an agent", opening Settings › Agents, where each
   agent's install command is shown to copy), and Heron in the Library. Autonomy stays.
4. **Remove Heron's agent. Built 2026-11-04.** `Packages/Heron` is gone: the runner, providers,
   tools, streaming and the benchmark, with their tests (96 in the package; four of Side's test
   files and the Heron parts of three more). A track on Heron is read through
   `RetiredHeronHarness` (SideAgents): its stored conversations rebuilt as Heron rebuilt them,
   with their checkpoints, past ones still openable, nothing sendable. `AgentRunnerManager` moved
   into SideAgents, and the app imports `SideAgents` directly. Run's task chips type their
   command into the terminal on screen (they were Heron's command cards); coordinators offer only
   installed agents, the default first.
5. **Extend `SideToolServer`. Built 2026-11-04.** Each conversation's server knows its track's
   working copy and offers `read_diagnostics` (the Editor's language-server errors and warnings
   for that copy, errors only on request), `read_debug_state` (the paused program's stack,
   locals, watches and console) and `read_ports` (the track's port block); the ports are in the
   server's instructions too. Tasks stay with Run's chips for now.
6. **Outside the app. Done 2026-11-04.** The README (and its stage names), the constitution (its
   Heron entry is now SideAgents'), the distribution plan, `scripts/test.sh`,
   `scripts/publish-package.sh` (Alloy only) and the third-party notices. `gazishahi/heron` is
   archived with a note in its description, nothing deleted. The landing page drafts are the
   owner's, uncommitted, and still name Heron.

Each step ships on its own, with the suite passing; steps 1 and 2 change nothing you see but
the default.

## Decisions (2026-11-04: all three as recommended)

1. **Heron conversations already on disk:** kept read-only in the conversation list, or left
   on disk and no longer shown? Recommended: read-only, labeled "Heron (retired)".
2. **No agent installed:** first run offers to install Claude Code (the command, shown, for you to
   run in a Terminal tab), or only explains? Recommended: offer it, never run it unasked.
3. **The package:** a new `SideAgents` package, or the plumbing straight into the app target?
   Recommended: a package, so its tests run fast with `swift test`, as SideSessions' do.
