# RFC — Bring your own harness

*2026-09-23. Status: **decisions pending** — the owner decides D1–D8 below before any code.
Companion to `SIDE_PRODUCT_CONSTITUTION.md` (non-negotiables 3, 4, 5 and 8 are the ones at
stake) and `SIDE_DESIGN.md`.*

## The ask

Heron is Side's harness, and it stays the default. But someone already living in Claude Code,
Codex, Gemini CLI or Pi — with their subscription, their habits, their prompts — shouldn't have
to switch agents to use Side. They should be able to pick their harness per track and still get
tracks, Review, checkpoints, Promote and Run.

The line this RFC has to hold: **Side's guarantees are about what happens to the work, not about
which agent did it.** Where an outside agent can't give a guarantee Heron gives, the product says
so plainly instead of pretending.

## What Heron guarantees today

| Guarantee | How Heron does it | Constitution |
|---|---|---|
| Nothing changes without approval (Manual/Guarded) | edits are `ProposedEdit` cards; applied only through `ProposedEditApplier` on a click | 5 |
| Every change is reviewable and reversible | a checkpoint commit per approved batch; Review, Undo, Promote | 4, 5 |
| Commands are visible | typed into the track's own Run terminal, never a hidden process | 8 |
| Work stays in the track | tool paths are contained to the worktree (`ProjectFileAccess`) | 7 |
| Attention is explicit | `AgentActivity` drives the pill, Tracks, the dock badge | 3 |
| Verification is evidence | named tasks record a `CheckpointVerification` | 4 |

## Options

**A. ACP client — recommended.** The Agent Client Protocol is JSON-RPC 2.0 over the agent's
stdio. The editor launches the agent as a subprocess, creates a session, sends prompts, and
receives `session/update` notifications: message chunks, thought chunks, tool calls with
`kind` (read / edit / delete / move / search / execute / think / fetch / …), status, and content
that can be a **diff** (`path`, `oldText`, `newText`) or a **terminal**. The agent asks the
editor for approval with `session/request_permission` (options `allow_once`, `allow_always`,
`reject_once`, `reject_always`). The editor may advertise **file** (`fs/read_text_file`,
`fs/write_text_file`) and **terminal** (`terminal/create` …) capabilities, in which case the
agent reads, writes and runs commands *through the editor*. Coverage today: Gemini CLI;
Claude Code via Zed's `claude-agent-acp` adapter; Codex via `codex-acp`; Pi via `pi-acp`; and a
registry of ~50 more. One client, all of them — the same bet Zed and JetBrains made.

**B. Per-CLI adapters** (`claude -p --output-format stream-json`, `codex exec --json`, …). More
control per agent; one integration per agent, each tracking a private output format. Not worth
it while ACP covers the same agents.

**C. Terminal only.** Run the CLI in a Run tab; Side checkpoints the worktree after. Works today
with no code, and it's the honest fallback for any agent without ACP — but it isn't Think.

## Architecture (option A)

- **A `Harness` protocol in Heron** — the surface Think, the pill, Tracks and Run already consume
  from `AgentRunner`: `entries`, `phase`/`activity`, `send`, `stop`, `resolve(proposalId:)`,
  observers. `AgentRunner` becomes one conformer; `AcpHarness` the second. Nothing above the
  protocol learns which it is talking to. (The `Packages/Heron` extraction is this seam.)
- **`AcpHarness`**: launches the agent (cwd = the track's worktree), speaks JSON-RPC over its
  stdio — reusing the LSP layer's `JSONRPCTransport` framing — and maps updates into
  `RunTranscriptEntry`s:

  | ACP | Side |
  |---|---|
  | agent / thought message chunks | streamed `assistantText` / `thinking` |
  | tool call (read, search, think, fetch) | the "Worked for…" group line |
  | tool call with a diff | a `ProposedEdit` card (see D1) |
  | tool call `execute` / terminal content | a command card with the terminal tail |
  | `session/request_permission` | the approval card, the agent's own options as its buttons |
  | `fs/write_text_file` | `ProposedEditApplier` — the same path Heron's edits take |
  | `terminal/create` | the track's visible Run terminal (`TerminalSessionManager`) |
  | turn end | checkpoint, exactly as Heron's batches produce one |

- **Selection**: the session pill gains a harness row — Heron, or each detected agent — per track.

## Decisions

**D1 — File changes.** *Recommend:* advertise `fs.writeTextFile`. When an agent writes through
Side, the write becomes a `ProposedEdit` and obeys the track's autonomy exactly as Heron's
edits do (Manual asks, Full applies). When an agent writes to disk itself — some adapters do —
Side can't intercept it; the turn's changes are committed as a checkpoint at turn end (the
existing `stageAndCommit` against the pre-turn baseline, in the track's own worktree). Those
changes are then **reviewable and reversible, not pre-approved** — the same position Full
autonomy already takes. The pill says which mode a harness is in ("Edits land directly ·
checkpointed each turn"). *Decide:* accept "reviewable and reversible" as the floor for outside
agents, with pre-approval wherever the agent routes writes through Side.

**D2 — Commands.** *Recommend:* advertise the terminal capability, so agent commands run in the
track's Run terminal, visible and interruptible (non-negotiable 8). Commands an agent runs
internally still appear as tool-call lines with their output, but not in Run. *Decide:* accept
that split, labelled.

**D3 — Permissions.** *Recommend:* show the agent's own options as the card's buttons; never
choose one on the user's behalf; `allow_always` is offered only when the agent offers it, and
Side's autonomy setting doesn't answer permission prompts for another agent. *Decide:* whether
Guarded/Full may auto-select `allow_once` for tool kinds Side would auto-run itself (read,
search) — recommended **no** for v1.

**D4 — Containment.** *Recommend:* the agent's cwd is the track's worktree; `fs/*` and
`terminal/create` requests outside it are refused with a reason. An agent reaching outside by
itself is out of Side's hands; Review shows what changed inside the worktree. *Decide:* accept.

**D5 — Durability.** *Recommend:* Side keeps its own log of what it rendered for an outside
session (the same `SessionLog` file shape, tagged with the harness), plus the agent's session id
for `session/load` where the agent supports it. Checkpoints are Side's either way. *Decide:*
accept that a transcript from another harness is Side's record of it, not the agent's own.

**D6 — Model, modes, scope.** *Recommend:* the pill shows the harness and its own modes
(`session/set_mode`); Heron-only controls (Ask/Plan/Build scope, effort, Side's autonomy for
edits) show only for Heron or where they map. *Decide:* accept that the pill differs by harness.

**D7 — Accounts and installation.** *Recommend:* agents authenticate themselves (their own
login; ACP `authenticate` when they ask). Side never stores or proxies their credentials — the
user's subscription is used by the user's CLI. Agents are detected on the login-shell PATH (the
same resolution the language servers use); missing adapters get an install line to copy, never
an automatic install. *Decide:* accept; confirm no bundling of third-party adapters.

**D8 — What else uses the harness.** *Recommend:* ⌘K inline instruct and Run's task chips
follow the track's harness; a task chip's result still attaches as verification. *Decide:*
accept, or keep those Heron-only in v1.

## Plan

1. **`Harness` protocol** in Heron; `AgentRunner` conforms; Think, the pill, Tracks and Run move
   onto the protocol with no visible change. Tests: the existing suite, unchanged.
2. **`AcpHarness` read-only**: launch, initialize, prompt, stream text and tool lines, cancel,
   permission cards. Proven first with **Gemini CLI**, then **Claude Code** (`claude-agent-acp`).
3. **Writes and terminals**: `fs/*` through `ProposedEditApplier` with containment; `terminal/*`
   through Run; the turn-end checkpoint for direct writes.
4. **Picker and detection** in the session pill; **Codex** (`codex-acp`) and **Pi** (`pi-acp`).
5. **Durability**: the tagged session log and `session/load`.

Each step is its own commit with its acceptance below.

## Acceptance

- [ ] Heron behaves exactly as before on the `Harness` protocol (full suite green, no UI change).
- [ ] A track on an ACP agent streams into Think, shows tool lines, and approval cards answer
      `session/request_permission` with the chosen option.
- [ ] An agent write through `fs/write_text_file` produces a `ProposedEdit` that Manual holds for
      approval and applies through `ProposedEditApplier`.
- [ ] A turn that changed files — however they were written — ends in a checkpoint Review shows
      and Undo can reverse.
- [ ] `terminal/create` runs in the track's Run terminal; requests outside the worktree are
      refused.
- [ ] The pill names the harness and, for direct-write agents, says edits land directly.
- [ ] No third-party credential is read, stored or sent by Side.

## Sources

- Agent Client Protocol — overview: https://agentclientprotocol.com/protocol/overview
- Tool calls and permissions: https://agentclientprotocol.com/protocol/tool-calls
- Agents list and adapters: https://agentclientprotocol.com/get-started/agents
