# RFC — Bring your own harness

*2026-09-23. Status: **built** (plan steps 1–5; see each step). Earlier: **accepted** — the owner accepted D1–D8 as recommended the same day, with
D1 settled explicitly: outside agents may write straight to disk ("it is the user's
responsibility to know what the agents are up to"); those changes are reviewable and reversible
through the turn-end checkpoint rather than pre-approved. **D9** (one approval per edit) added and
accepted 2026-09-23; plan step 3 revised the same day to resolve its conflicts with D1–D4 and the
open audit finding F4.
Companion to `SIDE_PRODUCT_CONSTITUTION.md` (non-negotiables 3, 4, 5 and 8 are the ones at
stake) and `SIDE_DESIGN.md`.*

Symbols: `Harness` `ACPHarness` `ACPConnection` `ACPAgent` `ACPTerminalHost` `ACPTerminalBroker` `HarnessOption` `OutsideSessionLog` `UserSaveLog` `AgentAvailability` `AgentsPreferencesViewController`

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
  | `terminal/create` | a Run tab of its own running the command directly (`ACPTerminalBroker`) |
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

**D7 addendum: subscription or API key, per agent (2026-09-23).** Every agent can run on
the user's subscription or on an API key; Settings › Agents chooses, per agent.
- *Subscription:* the agent's own sign-in (`claude` login, ChatGPT, Google). Every API-key
  variable the agent reads is removed from its environment, because an exported key silently
  wins over the login (Claude Code billed a stale `ANTHROPIC_API_KEY` and hung).
- *API key:* stored in the Keychain and given to the agent as its variable
  (`ANTHROPIC_API_KEY`, `CODEX_API_KEY`, `GEMINI_API_KEY`); without a stored key, one already in
  the environment is used.
- Agents that list ACP `authMethods` (Codex: `chat-gpt` / `api-key`; Gemini: `oauth-personal` /
  `gemini-api-key`) are sent `authenticate` with the matching method before a session opens; an
  agent already signed in that way answers at once, otherwise it opens the browser itself.
  Claude Code lists none and uses whatever `claude` is signed into.
- Any other ACP agent (OpenCode, Qwen Code, Goose…) can be added by command, with an optional
  API-key variable. Subscriptions are only usable through the vendor's own agent, which is why
  hosting agents (not calling their APIs from Heron) is how Side supports them.
- Verified live: Claude Code. Codex and Gemini: method lists and sign-in shapes read from their
  published packages (`@agentclientprotocol/codex-acp` 1.13.1, `@google/gemini-cli` 0.61.0), not
  yet run.

**D8 — What else uses the harness.** *Recommend:* ⌘K inline instruct and Run's task chips
follow the track's harness; a task chip's result still attaches as verification. *Decide:*
accept, or keep those Heron-only in v1.

**D9 — One approval per edit (accepted 2026-09-23).** D1 and D3 together would ask twice for one
edit: the agent's `session/request_permission` card, then a `ProposedEdit` card for the
`fs/write_text_file` that follows. The rule:

- A write that follows a **granted** permission for the same tool call (matched by
  `toolCallId`, or by path within that tool call's `locations`) is applied **without a second
  card** — the diff was on the permission card.
- A write that arrives **without** a permission request is governed by the track's autonomy
  **exactly as Heron's edits are** (D1): **Full** applies it; **Manual and Guarded** show a
  `ProposedEdit` card. (Corrected 2026-09-23 during the build: Guarded never auto-applies
  Heron's edits — `AgentAutonomy.autoAppliesEdits` is Full only — so "Guarded applies" would
  have made autonomy mean two things.)
- A write to disk that bypasses Side entirely remains checkpoint-only (D1).
- Every write through Side, however approved, goes through `ProposedEditApplier` (disk first,
  open-buffer sync, staleness refusal — see step 3a).

This makes autonomy mean one thing across harnesses: it answers *Side's* questions (an
unannounced write), never the agent's (D3 stands: Side never picks a permission option for
another agent).

## Plan

1. **`Harness` protocol** in Heron; `AgentRunner` conforms; Think, the pill, Tracks and Run move
   onto the protocol with no visible change. Tests: the existing suite, unchanged.
2. **`AcpHarness` read-only**: launch, initialize, prompt, stream text and tool lines, cancel,
   permission cards. Proven first with **Gemini CLI**, then **Claude Code** (`claude-agent-acp`).
3. **Writes and terminals** — revised 2026-09-23; split so the conflict-free half ships first.
   **Built 2026-09-23 (3a, 3b and 3c together):** `ACPHarness` (files, writes, terminals, turn
   checkpoint), `ACPTerminalHost` / `ACPTerminalBroker`, `UserSaveLog` (also closes F4 for Heron),
   `TerminalViewController.CommandLaunch`; tests `ACPFileTerminalTests`.

   **3a — conflict-free.**
   - **`fs/read_text_file`** served by Side: contained to the worktree (D4); returns the open
     buffer's unsaved content when that file is dirty in Make; records the content served per
     path as that path's **base** for later writes. `line`/`limit` honoured.
   - **Containment:** any `fs/*` path or `terminal/create` `cwd` outside the track's worktree is
     refused with a JSON-RPC error that says why (D4).
   - **`terminal/*` as their own sessions.** Each `terminal/create` gets a **dedicated Run tab** in
     the track's `TerminalSessionManager` pool, spawning `command` + `args` with the given `env`
     directly — **never typed into the user's interactive shell**, never queued behind Run's
     agent-command queue. Output is kept in a bounded buffer (`outputByteLimit`, default 1 MB,
     truncating from the front) for `terminal/output`; `terminal/wait_for_exit`,
     `terminal/kill` and `terminal/release` are implemented; Stop and `session/cancel` kill every
     terminal the session created. The tab is visible and interruptible (non-negotiable 8) and is
     titled with the command.
   - **Attribution before the turn-end checkpoint** (also closes audit F4 for Heron): snapshot
     dirty paths at **turn start**; record paths the agent touched (tool-call `locations`, diff
     paths, writes through Side); record paths the **user** saved in Make during the turn. The
     checkpoint commits `agentTouched ∪ (newlyDirty − userSaved)`. A path both the user and the
     agent changed is committed as the agent's and named in the checkpoint's meta line as shared.
   - **Write staleness:** `fs/write_text_file` compares the file's current content (buffer if
     open and dirty, else disk) with the base recorded at read time; if it moved, the write is
     refused with an error the agent can act on ("file changed since you read it; read it again").
     A write to a path never read is a create if the file does not exist, and refused if it does.

   **3b — writes through Side, under D9.** Advertise `fs.writeTextFile`; route every write through
   `ProposedEditApplier` with D9's approval rule; the turn-end checkpoint covers direct writes. The
   pill states the mode ("Edits land directly · checkpointed each turn" for agents observed
   writing to disk without Side).

   **3c — advertise terminals.** Flip `terminal: true` once 3a's sessions pass their acceptance.
4. **Picker and detection** in the session pill; **Codex** (`codex-acp`) and **Pi** (`pi-acp`).
   **Built 2026-09-23.** The pill's popover starts with an **Agent** row (Heron or each known
   agent, marked "not installed" with its install line when the login shell can't find it —
   `AgentAvailability`). For an outside agent the popover shows the agent's own settings as it
   reports them (`HarnessOption`, from ACP `configOptions`, or the older `modes`/`models`),
   changed with `session/set_config_option` / `set_mode` / `set_model`, remembered per track
   (`Track.harnessOptions`) and re-applied to each new session; modes that let the agent act
   without asking say "Edits land directly — each turn is checkpointed" (D1). The pill reads
   "Claude Code · Opus 5.5 · 12%". The session opens when Think attaches, so all of this shows
   before the first message. Verified live with Claude Code; **Codex, Gemini CLI and Pi are
   selectable and detected but not yet verified against the real adapters** (not installed on
   the development machine). Keys follow the D7 addendum (`ACPAgent.launchEnvironment`):
   Subscription removes every key variable the agent reads; API key gives it one. An exported
   Gemini or OpenAI key is often the user's only credential, so until the person chooses, an
   agent other than Claude Code whose key is in Side's environment starts in API-key mode
   (2026-10-01, UX-14).
5. **Durability**: the tagged session log and `session/load`.
   **Built 2026-09-23.** `OutsideSessionLog`: Side's record of each outside conversation, one
   JSON line per finished entry in `think/outside/<track>.<agent>.jsonl`, appended at each send
   and turn end (cards are written once decided; tool and failure text redacted), with the
   agent's session id in a header line. On launch the conversation is restored from it, and the
   agent's own session is reopened with `session/load` when the agent advertises
   `loadSession` (its replay is not drawn twice); if that fails, a new session opens and the
   transcript says the agent won't remember. New Conversation files the record under
   `outside/archive/`. Retention and Delete All Conversations cover these records too. A
   checkpoint finished after its conversation was put away is still written to the ledger and
   the record. Verified live: Claude Code remembers a word across a relaunch. Past outside
   conversations appear in Think's History and reopen (their agent session is reopened too).

Each step is its own commit with its acceptance below.

## Acceptance

- [ ] Heron behaves exactly as before on the `Harness` protocol (full suite green, no UI change).
- [ ] A track on an ACP agent streams into Think, shows tool lines, and approval cards answer
      `session/request_permission` with the chosen option.
- [ ] `fs/read_text_file` returns unsaved buffer content for a dirty tab and refuses paths
      outside the worktree.
- [ ] An agent write through `fs/write_text_file` after a granted permission applies with **no**
      second card; an unannounced write is held by Manual and applied by Guarded/Full; all go
      through `ProposedEditApplier`.
- [ ] A write whose base moved since the agent read it is refused with an actionable error.
- [ ] A file the user saves in Make during an outside agent's turn is **not** in that turn's
      checkpoint (and the same holds for Heron batches — F4).
- [ ] A turn that changed files — however they were written — ends in a checkpoint Review shows
      and Undo can reverse.
- [ ] `terminal/create` opens its own Run tab running the command directly (not typed into a
      shell); output, wait-for-exit, kill and release work; Stop kills them; a `cwd` outside the
      worktree is refused.
- [ ] The pill names the harness and, for direct-write agents, says edits land directly.
- [ ] No third-party credential is read, stored or sent by Side.

## Sources

- Agent Client Protocol — overview: https://agentclientprotocol.com/protocol/overview
- Tool calls and permissions: https://agentclientprotocol.com/protocol/tool-calls
- Agents list and adapters: https://agentclientprotocol.com/get-started/agents
