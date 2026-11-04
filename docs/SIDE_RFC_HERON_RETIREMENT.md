# Retiring Heron's agent

Status: decisions pending (2026-11-04: the owner decided to retire Heron; this is the plan, from
a read-only audit the same day). Nothing removed yet.

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

1. **A default agent.** Settings › Agents chooses it (the first installed of Claude Code, Codex,
   …); new tracks and sub-tracks use it; tracks set to Heron move to it, with their history
   kept read-only.
2. **Move the plumbing.** Checkpoint commits out of `AgentRunner`; the shared types and utilities
   into Side (a `SideAgents` package, as `SideSessions` is), with their tests (about 90).
3. **Remove the UI:** modes, provider/model pickers, Settings › Providers, compaction, the rules
   gate, first run's model step, the Library's "Heron" wording.
4. **Remove Heron's agent** and its tests (about 110 in the package, 30–40 in Side's).
5. **Extend `SideToolServer`:** diagnostics, debugger state, ports, later tasks.
6. **Outside the app:** the README, the landing page, `scripts/test.sh`, third-party notices; the
   public Heron repository archived with a note, not deleted.

Each step ships on its own, with the suite passing; steps 1 and 2 change nothing you see but
the default.

## Decisions for the owner

1. **Heron conversations already on disk:** kept read-only in the conversation list, or left
   on disk and no longer shown? Recommended: read-only, labeled "Heron (retired)".
2. **No agent installed:** first run offers to install Claude Code (the command, shown, for you to
   run in a Terminal tab), or only explains? Recommended: offer it, never run it unasked.
3. **The package:** a new `SideAgents` package, or the plumbing straight into the app target?
   Recommended: a package, so its tests run fast with `swift test`, as SideSessions' do.
