# SIDE — Product Constitution

_Working name: Shahi's IDE._

## Purpose

SIDE is a native Mac development environment for focused, agent-assisted software work. It rejects the model of an IDE as a permanently visible collection of sidebars, panes, and buried chat threads.

The primary unit is a **track**: a meaningful unit of work with an intent, a current state, agents/workstreams, evidence, and a path back to `main`.

## Non-negotiables

1. **One stage owns the canvas.** The application never relies on a permanent file tree, chat rail, terminal panel, or inspector to remain functional.
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
is a case in `ShellViewController.Stage` and has a real canvas; **planned** means
it does not exist in code at all.

| Stage | Status | Owns the canvas for |
|---|---|---|
| Make | built | code, navigation, diagnostics, and edits |
| Think | built | intent, plan, decisions, questions, agent workstreams, and scoped files |
| Review | built | checkpoints, diffs, rationale, test evidence, and promotion decisions |
| Run | built | terminals, tasks, tests, logs, debugging, and remote sessions |
| Tracks | built | orienting, prioritizing, resuming, parking, and archiving work |
| Integration | **planned** | reconciling track change streams with `main`, verifying evidence, and publishing safely |
| Library | **planned** | prompts, skills/plugins, agent instruction files, templates, and archive/storage management |

The app opens a track at the stage that best matches its state; keyboard shortcuts and a quiet stage control move between stages while preserving return position.

### Stages vs. engines

A stage (above) is a place in the UI — what the user navigates to and sees. Some stages are backed by a named, independently-architected engine that the stage is a thin client of, rather than code inseparable from the stage's own view controller. Keeping the engine and the stage distinct — and distinctly named — is deliberate: it's what let Think's agent loop survive being torn down and rebuilt across stage switches, track switches, and even window closures, instead of dying with whatever view happened to be showing it. Two such engines exist so far:

#### Heron — powers Think

Heron is the agent harness: the provider-agnostic conversation loop, tool execution, and human-approval machinery that Think's UI merely renders and forwards user actions into. It does not assume a view is watching — it is built to run headless of any particular one, to survive that view detaching and reattaching, and to serve more than one observer at once (Think itself today; a live Tracks dashboard and stage badges as of the "B1" phase of its build).

As built:

- **Provider abstraction.** One protocol, `ChatModelProvider`, with a single streaming method (`streamTurn`) — no non-streaming call exists, because "stream and buffer" is trivial for a caller that wants one. Two adapters cover the entire target list: `AnthropicMessagesProvider` (the built-in provider) and `OpenAICompatibleChatProvider` (built) — a single adapter that covers OpenAI bring-your-own-key *and* any local model server (Ollama, LM Studio) speaking the same wire shape, so "use your own key" and "run it locally" are never two separate code paths.
- **Transport.** `SSEHTTPClient`: a dedicated session (not `URLSession.shared`) with incremental Server-Sent-Events parsing and an explicit request timeout, playing the same role for Heron that `JSONRPCTransport` plays for the LSP layer underneath Make.
- **The runner.** `AgentRunner` — one per `(project, trackKey)`, `@MainActor` — owns the actual loop: send, stream, run tools, pause for approval, resume. It exposes a renderable transcript (`RunTranscriptEntry`: meta / user text / assistant text / tool call / tool result / failure / proposal-with-resolution — never an `NSView`, so it isn't AppKit-specific) and a coarse `AgentRunPhase` (idle / streaming / runningTools / awaitingApproval / blocked / finishedTurn), which projects further into `AgentActivity` (none / working / needsYou / doneUnread / doneSeen) for anything that wants to show status without understanding the loop itself — this is the concrete mechanism behind "attention is explicit." A small multicast (`addObserver`/`removeObserver`) lets several observers watch one runner at once.
- **Lifecycle.** Runners are owned by `AgentRunnerManager` — one per project, shaped like `LSPManager` (lazy per-key creation, explicit discard, teardown-all) — which is itself owned by `ProjectContext`, a refcounted object shared by every window that has a given project open. That sharing is what lets a runner outlive the window that started it, as long as another window keeps the project open, and what makes "opening the same project in two windows" behave like one project instead of two silently diverging copies of it.
- **Tools.** `read_file` / `list_files` / `search_files` auto-run — pure reads, nothing to promote. `edit_file` / `write_file` never touch disk directly: they produce a `ProposedEdit`, rendered inline in the transcript as a diff card, that a human must explicitly Apply or Reject. This is the literal mechanism behind "agents propose; people promote," not just a principle stated in prose.
- **File references (built 2026-08-27).** `@path/to/file` in a Think message is a *pointer*, never inlined content. Typing `@` completes against the track's own working directory (its worktree, not the project root) using the same fuzzy scorer Quick Open uses, through AppKit's native completion so arrows/Return/Escape behave correctly. On send, mentions resolve to real paths and travel as a short note — "read these with read_file if you need them" — with typo'd and out-of-project references reported so the agent asks instead of inventing a file. Inlining the contents was rejected deliberately: a conversation mentioning six files would then persist six copies *and* re-send all of them on every later turn, which is exactly the unbounded-growth shape the session store was restructured to remove.
- **Modes (built 2026-08-27).** A track's mode is two independent axes, not a flat list. **Tool scope** — Ask / Plan / Build — decides which tools the model is even shown, so a read-only scope is a boundary rather than an instruction (`ToolExecutor.specs(for:)`). **Autonomy** — Manual / Guarded / Full — decides what happens without a human: Manual waits on everything, Guarded auto-runs allowlisted commands (exactly what the old per-track `autoRunCommands` bool meant, and what it migrates to), Full also auto-applies edits. `CommandAutoRunPolicy`'s allowlist is a floor at *every* level, Full included: a mode is a statement about routine work, never permission to run anything. **Full autonomy is the one setting that steps past "agents propose; people promote,"** and it exists deliberately: clicking through forty mechanical renames is how people start approving without reading. Auto-applied edits still produce checkpoints, so they stay reviewable and revertable rather than invisible. Scope is chosen in Think's header (next to the conversation it shapes); autonomy also appears in the Tracks context menu (it's a property of the track a ledger reader wants to see).
- **Persistence.** One `AgentSession` per track (its turns, provider, model), stored under `.git/side/think/` — same state directory `TrackStore` uses. **Superseded shape:** this was one `think.json` holding every track's full history, which was loaded eagerly at launch and never evicted; it is now a lightweight `index.json`, a `checkpoints.json`, and one file per track's session, so a track's turns load only when that track is actually opened. Existing single-file state migrates on first launch.
- **Safety properties.** A `WorkspaceBridge` (live editor-buffer access, apply-into-open-tab, reveal-after-apply) is resolved fresh from whichever window is both frontmost and actually showing the relevant track — never captured once — so an agent can never land an edit into the wrong window's editor. A stall watchdog (90 seconds with no stream event) plus an explicit transport timeout mean a hung connection surfaces as a visible blocked state, never as an agent that merely looks busy forever.

Named to stay distinct from "Think," the stage that hosts it. Code lives under a `Heron/` directory, mirroring the existing `LSP/` directory's role for Make's language-server support.

#### Alloy — powers Make (name reserved; not yet designed or built)

Alloy is the reserved name for a GPU-accelerated editing engine intended to eventually underlie the Make stage, in the same relationship Heron has to Think: Make is the stage/UI; Alloy would be the independent engine actually doing the work of text storage, rendering, and editing — on the GPU, rather than through AppKit's `NSTextView`/`NSTextStorage`, which is what Make is built directly on today.

Unlike Heron, nothing about Alloy exists yet: no architecture note, no code, no build phases. This entry is on record so the name and its intended role — "an editing engine separable from Make's own UI glue, the way Heron is separable from Think's" — are settled ahead of the design itself, not so the design can be treated as settled. Everything else about it (rendering approach, Metal directly vs. a framework on top, how it would interact with LSP diagnostics and syntax highlighting) is genuinely open and should be treated as a fresh design question when this is picked up, not inferred from Heron's shape.

## Change model

`main → track change stream → checkpoint → review → pull request (optional) → main`

An agent run does not equal a branch. It produces a durable checkpoint: declared intent, changed files, diff, commands/tests, and agent provenance. A conventional Git branch is materialized when collaboration or publishing requires it.

Integration is an **action surface**, not a passive Git graph. Each track makes four operational concerns legible—base, checkpoint, verification, and integration—and exposes only the next safe action for its current state. The visual `main` baseline provides orientation; it never invites unsafe drag-and-drop merging.

### Stacked tracks (built)

A track's base is not always `main`. A track may fork from another track's own branch instead — its own agent, its own worktree, its own checkpoint/review/promote cycle — so a large piece of work can be decomposed into dependent layers (e.g., a schema-migration track, an API track built on it, a UI track built on that) rather than forced into one undifferentiated branch or several siblings that all race against a moving `main`. This is still consistent with "`main` is canonical": a stacked track's path back to `main` simply runs through its parent first, one promotion at a time, never a competing permanent universe of its own.

This is implemented. `Track.parentTrackId` records the relationship, "New Track…" offers a base-track picker, Tracks renders the hierarchy as a branch tree, and Review resolves each track's real base and promote target rather than assuming `main`. Propagation is `TrackStore.pullFromParent` — a `--no-ff` merge of the parent's branch into the child's own worktree, refused while that child's agent run is busy or its worktree is dirty, which is how a parent's landed changes reach children without corrupting an in-flight run. Deleting a track with live (non-archived) children is refused for the same reason.

Two known gaps remain: there is no policy yet for *archiving* (as opposed to deleting) a parent that still has live children, and `TrackStore.applyReconciliation`'s worktree-immunity logic has not been audited for hierarchy.

## First alpha

Open a project; create a track; let an agent scope a task; inspect its plan and instruction sources; review a checkpoint; run the relevant tests in a track-bound terminal; and promote the result toward `main`—without losing the reason for the work.

## Explicit non-goals for v1

- A general extension marketplace
- Multi-user collaboration
- Full remote-development environments over SSH
- A bespoke replacement for Git
- Parallel background agents mutating one live checkout
- Debugger parity across every language
