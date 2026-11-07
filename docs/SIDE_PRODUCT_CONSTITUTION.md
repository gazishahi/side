# SIDE — Product Constitution

Status: reference — the stage table below is machine-checked (`DocStatusTests`): a stage marked **built** must be a `ShellViewController.Stage` case, and one marked **planned** must not be.

_Working name: Shahi's IDE._

## Purpose

SIDE is a native Mac development environment for focused, agent-assisted software work. It rejects the model of an IDE as a permanently visible collection of sidebars, panes, and buried chat threads.

The primary unit is a **track**: a meaningful unit of work with an intent, a current state, agents/workstreams, evidence, and a path back to `main`.

## Non-negotiables

1. **One task owns the canvas.** A stage, and at most one companion beside it showing the same track (a Terminal session beside Editor or Changes; changed 2026-11-07, `SIDE_DESIGN_SESSIONS_2026-11-06.md`). The application never relies on a permanent file tree, chat rail, terminal panel, or inspector to remain functional.
2. **Tracks are primary; threads are nested.** An agent thread is a workstream within a track, never the user's top-level navigation model.
3. **Attention is explicit.** A user can always identify what is waiting on them, what changed, what failed, and what was last learned.
4. **Work is durable.** A track preserves its intent, decisions, files, commands, tests, prompts, instructions, and review checkpoints so it can be safely resumed.
5. **Agents propose; people promote.** Agents create scoped, inspectable checkpoints. Applying, publishing, or merging consequential changes remains an explicit human action.
6. **Git is the compatibility substrate, not the mental model.** SIDE presents track change streams anchored to canonical `main`; it interoperates cleanly with ordinary commits, branches, remotes, and pull requests.
7. **`main` is canonical.** Tracks are temporary and reviewable paths back toward `main`, not competing permanent universes.
8. **No accidental surveillance.** Agent commands, tool access, instruction sources, and produced changes are visible and attributable.
9. **Minimality is behavioral, not feature removal.** Deep development capabilities appear when needed, without occupying the screen all the time.
10. **Native Mac quality matters.** Keyboard fluency, focus behavior, accessibility, reliable text input, and ordinary Mac conventions take priority over cross-platform abstraction.

## Core information architecture

### Track lifecycle

`Active → Waiting / Review-ready / Parked → Completed → Archived`

The Tracks ledger is a bounded working set, not an infinite history list. Search retrieves archived work without making it permanent visual clutter.

### Stages

Every row carries an explicit status, because this table previously read as a
description of the app while two of its stages did not exist. **Built** means it
is a case in `ShellViewController.Stage` and has a real canvas. **Not a stage**
means the concern is real but lives elsewhere (decided 2026-09-03, RFC R6):
Integration is Review's publishing half, and Library is a separate window. Neither
adds a `Stage` case, and `DocStatusTests` asserts that.

The stages were called Make, Think, Review, Run and Tracks until 2026-11-04, when they took
names a developer reads at a glance. The code, settings and the rest of these documents still
use the old names as keys (`Stage.make` is the Editor); the table uses the new ones.

| Stage | Status | Owns the canvas for |
|---|---|---|
| Editor | built | code, navigation, diagnostics, and edits |
| Agent | built | intent, plan, decisions, questions, agent workstreams, and scoped files |
| Changes | built | checkpoints, diffs, rationale, test evidence, and promotion decisions |
| Terminal | built | terminals, tasks, tests, logs, debugging, and remote sessions |
| Branches | built | orienting, prioritizing, resuming, parking, and archiving work |
| Integration | **not a stage** — Changes' publishing half (push, PR, remote verification land in Changes' decision header) | reconciling track change streams with `main`, verifying evidence, and publishing safely |
| Library | **not a stage** — a separate window (⇧⌘L), also reachable from Agent's + and Preferences | prompts, skills/plugins, agent instruction files, templates, and archive/storage management |

The app opens a track at the stage that best matches its state; keyboard shortcuts and a quiet stage control move between stages while preserving return position.

### Stages vs. engines

A stage (above) is a place in the UI — what the user navigates to and sees. Some stages are backed by a named, independently-architected engine that the stage is a thin client of, rather than code inseparable from the stage's own view controller. Keeping the engine and the stage distinct — and distinctly named — is deliberate: it's what let Think's agent loop survive being torn down and rebuilt across stage switches, track switches, and even window closures, instead of dying with whatever view happened to be showing it. Two such engines exist so far:

#### SideAgents — powers Agent

*Update 2026-11-04: Heron, Side's own agent harness, is retired (`SIDE_RFC_HERON_RETIREMENT.md`).
A solo project can't out-build Claude Code or Codex; Side's part is the editor, the tracks and the
tools it offers every agent. Agent runs outside agents only, through `Packages/SideAgents`.
Heron's entry as it stood is in git history; its conversations stay readable on their tracks.*

SideAgents is what Agent's UI renders and forwards actions into. Like Heron before it, it does not
assume a view is watching: it runs headless, survives a view detaching and reattaching, and serves
several observers at once (Agent, Branches' ledger, stage badges, the activity pill).

- **The harness.** One protocol, `Harness`, per `(project, trackKey)`: a renderable transcript
  (`RunTranscriptEntry`, never an `NSView`), a coarse `AgentRunPhase` projected into
  `AgentActivity` for anything that shows status, a multicast of changes, and the actions a person
  can take. `ACPHarness` speaks the Agent Client Protocol to the agent the track runs on (Claude
  Code, Codex, Gemini CLI, Pi, OpenCode, or any added by its command), on the user's own account.
  New tracks take the default agent (Settings › Agents).
- **Lifecycle.** Harnesses are owned by `AgentRunnerManager`, one per project, owned in turn by the
  refcounted `ProjectContext` every window on that project shares, so a conversation outlives the
  window that started it.
- **Approval and autonomy.** The agent asks through its own permission requests, drawn as cards;
  writes it routes through Side are proposals under Manual and Guarded, applied under Full. Every
  turn that changed files ends in a checkpoint on the track's branch.
- **Side's tools.** Each conversation gets Side's MCP server at its own URL: the project's other
  tracks and the files it shares with them, subtracks for a coordinator, the editor's diagnostics,
  the debugger's state and the track's ports. The editor's abilities are offered to any agent,
  rather than built into one.
- **Persistence.** What the agent showed is kept under `.git/side/think/outside` per conversation,
  so a relaunch brings it back; the agent keeps its own session as well.
- **Safety properties.** A `WorkspaceBridge` is resolved fresh from whichever window is frontmost
  and showing the track, so nothing lands in the wrong window's editor; a stall watchdog turns a
  hung agent into a visible blocked state.

An outside agent may write straight to disk; non-negotiable 5 holds as it does for Full autonomy:
every change lands in the track's own worktree, is checkpointed at the end of the turn, and stays
reviewable and reversible, and promotion toward `main` is still an explicit human action.

#### Alloy — powers Make (name reserved; not yet designed or built)

*Update 2026-09-24: the owner made Alloy a launch gate for 0.1; its design is `SIDE_RFC_ALLOY.md` (accepted 2026-09-24).*
*Update 2026-09-24, later: built. Make runs on Alloy only (`SIDE_RFC_ALLOY.md`, steps 0–7); the `NSTextView` path is removed. The text below is the entry as first written.*

Alloy is the reserved name for a GPU-accelerated editing engine intended to eventually underlie the Make stage, in the same relationship Heron has to Think: Make is the stage/UI; Alloy would be the independent engine actually doing the work of text storage, rendering, and editing — on the GPU, rather than through AppKit's `NSTextView`/`NSTextStorage`, which is what Make is built directly on today.

Unlike Heron, nothing about Alloy exists yet: no architecture note, no code, no build phases. This entry is on record so the name and its intended role — "an editing engine separable from Make's own UI glue, the way Heron is separable from Think's" — are settled ahead of the design itself, not so the design can be treated as settled. Everything else about it (rendering approach, Metal directly vs. a framework on top, how it would interact with LSP diagnostics and syntax highlighting) is genuinely open and should be treated as a fresh design question when this is picked up, not inferred from Heron's shape.

## Change model

`main → track change stream → checkpoint → review → pull request (optional) → main`

An agent run does not equal a branch. It produces a durable checkpoint: declared intent, changed files, diff, commands/tests, and agent provenance. A conventional Git branch is materialized when collaboration or publishing requires it.

Integration is an **action surface**, not a passive Git graph. Each track makes four operational concerns legible—base, checkpoint, verification, and integration—and exposes only the next safe action for its current state. The visual `main` baseline provides orientation; it never invites unsafe drag-and-drop merging.

### Stacked tracks (built)

A track's base is not always `main`. A track may fork from another track's own branch instead — its own agent, its own worktree, its own checkpoint/review/promote cycle — so a large piece of work can be decomposed into dependent layers (e.g., a schema-migration track, an API track built on it, a UI track built on that) rather than forced into one undifferentiated branch or several siblings that all race against a moving `main`. This is still consistent with "`main` is canonical": a stacked track's path back to `main` simply runs through its parent first, one promotion at a time, never a competing permanent universe of its own.

This is implemented. `Track.parentTrackId` records the relationship, "New Track…" offers a base-track picker, Tracks renders the hierarchy as a branch tree, and Review resolves each track's real base and promote target rather than assuming `main`. Propagation is `TrackStore.pullFromParent` — a `--no-ff` merge of the parent's branch into the child's own worktree, refused while that child's agent run is busy or its worktree is dirty, which is how a parent's landed changes reach children without corrupting an in-flight run. Deleting a track with live (non-archived) children is refused for the same reason.

Promotion runs child-first: a stacked track lands in its parent, and the parent then lands in its own base. Promoting a parent that still has unpromoted children (anything not completed or archived) warns and names them, and the default is Cancel. **Promote and Restack** lands the parent, then stacks those children on the parent's own base (`TrackStore.restackChildren`), so their work still reaches `main` instead of promoting into a branch that has already landed (added 2026-10-02).

A track's base changes in one place, `TrackStore.setBase`: **Change Base…** in a track's menu (the default branch, or any live track outside its own stack), Promote and Restack, and **Archive** or **Mark Completed** on a parent with unpromoted children, which asks first and offers to restack them the same way (their branches still hold the parent's work, which the sheet says). A branch turned into a track is stacked on the live track it was cut from, if any (`TrackStore.inferredBase`), and Tracks says so (added 2026-10-02).

**A track's branch is its record; its folder is where the work happens.** The folder (a git worktree, with its own dependencies and build output) comes back from the branch whenever you switch to the track, so Side removes it when nothing needs it (`TrackStore.cleanUp`, decided with the owner 2026-10-02):
- **Promoted:** the folder goes, and the branch is deleted with `git branch -d`, which refuses anything not merged. Promote merges with `--no-ff`, so every checkpoint stays reachable from the base. Resuming such a track starts its branch again from its base.
- **Archived:** the folder goes; the branch stays, since its work is nowhere else.
- **Parked:** kept; after 14 days unopened, Tracks offers to free it.
- **Free Unused Working Copies…** in Tracks frees every folder not in use; branches stay.
- **Never removed:** a track a window shows, one whose agent is working or waiting, a parent with unpromoted children, or a folder with uncommitted changes or ignored files that aren't build output (`TrackStore.rebuildable`: dependencies, build output and caches go; a local `.env` doesn't). Those are kept and named.
The sweep runs when a project opens, when a window moves to another track, and after Archive or Complete.

A new track's folder starts with the main checkout's `node_modules` (at any depth, for a monorepo's packages) as APFS clones (`TrackStore.cloneDependencies`): instant, and no disk used until a file changes. Only `node_modules`: virtualenvs and build folders record absolute paths. On a disk without clones nothing is copied.

A new track's folder also gets the main checkout's env files, which git leaves out: every ignored `.env` and `.env.*`, and anything `.side/tracks.json` lists under `"copyFiles"` (paths inside the project), as real copies readable only by you (`TrackStore.copyEnvironmentFiles`). A copy the track left unchanged doesn't keep its folder from being cleaned up; one it changed does (decided with the owner 2026-10-02: copies, not links, so a track can change its own).

**Each track has its own ports.** A track still in play gets a block of ten free ports (from 4100, never another open project's), kept for its life (`Track.portBase`, `TrackPorts`). Whatever Side starts inside a track's folder gets `PORT` (the block's first), `SIDE_PORT_BASE` and `SIDE_PORT_RANGE`: its terminals, so the agent's commands and tasks; the debugger's launches; an outside agent's process. Heron's agent is told the range. When a command says a port is already in use, the agent's result names the port, the process holding it, and that process's track. The main checkout keeps the usual ports. Tools that don't read `PORT` (Vite, a `docker-compose` file with fixed ports) still need a flag or their own setting.

One known gap remains: `TrackStore.applyReconciliation`'s worktree-immunity logic has not been audited for hierarchy.

## First alpha

Open a project; create a track; let an agent scope a task; inspect its plan and instruction sources; review a checkpoint; run the relevant tests in a track-bound terminal; and promote the result toward `main`—without losing the reason for the work.

## Explicit non-goals for v1

- A general extension marketplace
- Multi-user collaboration
- Full remote-development environments over SSH
- A bespoke replacement for Git
- Parallel background agents mutating one live checkout
- Debugger parity across every language
