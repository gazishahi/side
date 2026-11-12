# Sessions: every agent in the project, what each changed, and review

Status: agreed (2026-11-12: the owner took every decision below; nothing built yet). Grounded in
`SIDE_RESEARCH_AGENT_LANDSCAPE_2026-11.md`.

## Why

Side's unit of work is the track: a branch, its folder, one agent conversation, its terminals.
Agents don't work that way, for anyone:

- several agents share one branch and folder;
- an agent moves: Claude Code puts itself in a worktree it made, mid-session;
- subagents and teammates run under one session, and sessions message each other;
- a quick question belongs to no branch, and shouldn't make one.

The field moved to the session as the unit (Cursor, VS Code, Zed, Claude Code desktop, Codex,
T3 Code, Superset…). Their model, in turn, assumes the tool made the worktree, one agent per
worktree, and a task for every question. It breaks on exactly the cases above, and none of
them makes review, the real limit on running agents in parallel, fast.

The surfaces we built on tracks show the strain. The Agent panel mixes one conversation's plan
with the whole branch's files. The split view guesses which terminal to show. The Agent stage
is a second chat beside Claude Code's own, which developers prefer.

## Thesis

**Side sees every agent working in your project, however it was started and wherever it went;
tells you which one needs you; and lets you review what each changed, and edit it, in a real
editor, with sessions that survive restarts and updates.**

Three consequences:

1. **Observe, don't own.** Side never requires an agent to be started by Side. It discovers
   sessions from what agents already expose.
2. **Know where each change came from.** Changes are attributed to the session that made them,
   from records, not guesses.
3. **Review is the product's centre.** The constraint on parallel agents is the person reading
   their work; Side's job is to make that fast and safe.

## The model

- **Project:** a folder, usually a repository.
- **Checkout:** a place code lives: the project's main folder, or any worktree of it, with its
  branch (or detached). Found from git itself (`git worktree list`), so worktrees agents made
  (`.claude/worktrees/`, `~/.cursor/worktrees/`, Codex's) appear without setup.
- **Session:** one agent run (or a plain shell, or a quick question). It has:
  - who: the agent (Claude Code, Codex, OpenCode…) or the shell, and its title;
  - state: working, needs you (and why: permission, a question, idle), done, failed, idle;
  - where: its current checkout, and the ones it has been in;
  - lineage: its subagents and teammates, and the session it was started from;
  - requests: what it was asked, turn by turn (the prompts);
  - changes: the hunks it made, by request;
  - how to reach it: its Side terminal, its conversation id (to resume), its message socket.
- **Change:** a hunk in a checkout, with its provenance: a session and the request it came from;
  you (Side's own editor); or unknown.

A branch is no longer a container; it's where a session happens to be. The old "track" splits
in two: the checkout (git's truth, with a base and a pull request) and the sessions in it.

## Discovering sessions (observe)

In order of richness; each layer is optional, and Side works with whatever it gets.

1. **Side's own terminals** (already in keepers): the program running (`ProgramMarks`), its cwd,
   and state from **OSC 7501** (Rex's Program Status Protocol), OSC 9/99/777 and the bell. Side
   also emits 7501 for its own long-running commands.
2. **Agent hooks** (Claude Code; Codex, Copilot CLI, Qwen and Antigravity have their own): a
   small `side-hook` program reports SessionStart/End, UserPromptSubmit (the request),
   Notification (needs you, and why), Stop/StopFailure, CwdChanged, WorktreeCreate/Remove,
   SubagentStart/Stop and every file edit (PostToolUse on Edit/Write/MultiEdit, with the path
   and the text). Hooks see sessions in *any* terminal, iTerm or Ghostty included. If Side
   isn't running, events spool to a file and are read on launch.
3. **`claude agents --json`:** Claude Code's background sessions and their state, read-only.
4. **Server modes:** Codex `app-server`, OpenCode `serve`, ACP `session/list`, where present.

Without hooks, a session still has state (from 1) and its changes are known by checkout, not by
session. The UI says which: "attributed" or "by folder".

## Attributing changes

- **Agent edits** arrive as hook events: session, request, file, old and new text. Side keeps a
  per-file record of which lines each session last wrote (a small blame of its own, in
  `.git/side/`), updated per event.
- **Your edits** in Side's editor are Side's own; they're "You".
- **Shell commands an agent runs** (formatters, codegen, `sed`) change files without an edit
  event. Side snapshots the checkout's changed set before and after each command the agent ran
  (PreToolUse/PostToolUse on Bash): new changes go to that session when it's the only one
  working in that checkout then, else they're marked "shared".
- **Anything else** (another editor, a session without hooks) is "Unknown".

Confidence shows: attributed, shared, unknown. Nothing is presented as more certain than it is.

## Changes, rebuilt as review

Changes stops being "the branch's diff" and becomes **the review queue**: where an agent's
"done" lands.

- **Queue (left):** sessions with changes not yet reviewed, newest finished first, each with its
  state and size; then "Your edits", then "Unknown". A branch lens (the checkout against its
  base, as today) stays one click away.
- **A session's review:**
  - its request(s) and, where it had one, its plan;
  - its changes **grouped by request** (and plan step when the agent reported one), ordered
    dependencies first (definitions before callers);
  - each group and hunk with a review state (seen, approved), kept across launches;
  - **drift** flagged: files changed outside what was asked ("asked to fix the pill; also changed
    `Package.swift`"), and changes touching risky ground (dependencies, migrations, auth, CI);
  - comments on lines **go back to that session**: typed into its terminal, or sent to its
    message socket;
  - actions: approve; ask for changes; discard a hunk or group (only where no later change
    builds on it); commit the approved hunks to the session's checkout with a message drafted
    from the request; open a pull request.
- **The AI layer is on top, never underneath:** a one-line summary per group and the drift
  check, run on demand with the developer's own agent (headless, read-only), cached by content.
  Grouping never depends on it. Only changes with no provenance fall back to grouping it infers
  (by dependency and folder), labelled as such.

## Supervision, without a sidebar

A permanent list of sessions grows without end and becomes an archive, not attention; it also
goes against Side's one-task-owns-the-canvas design. Three questions, three places, nothing
permanently on screen:

- **"What needs me?"** Attention. The activity pill shows only sessions waiting on you, with
  the reason (a permission, a question, an error); one shortcut goes to the next one; a
  notification fires once per need and clears when answered.
- **Answering in place.** A reply overlay, from any stage: approve or deny a permission, answer
  a question, or send a line, without leaving what you're doing. It takes over the split
  view's real job (decision 5).
- **"What finished?"** Changes' review queue: a finished session lands there.
- **"What's everything?"** On demand: a session switcher overlay (search by title, agent,
  branch; like the project switcher), and the Branches stage as the full board, grouped by
  checkout, live sessions on top, finished ones folded away.
- **Focus.** Side knows the session you're with (the terminal you're in, the Agent view you're
  on, the one you picked); the track pill shows its checkout.

## Agent: the graphical view of a session

The aim is that developers don't have to live in a terminal. Terminal and Agent become two views
of the same sessions, not two systems: any session can be opened in Agent (one Side started
there, or one carried over from Terminal, as shared chats already does), and continued in
Terminal in one click when the GUI can't do something yet.

Agent earns its place by doing what a TUI can't: rich blocks (built), permission prompts and
questions as real controls, the plan as a live checklist, each turn's changes reviewable inline
and linked to Changes, attachments and images. The track's own separate conversations go.

The cost to accept: Side reaches Claude Code through its ACP adapter, so Claude Code features
(commands, plan mode, subagents, new permission kinds) arrive only as fast as the adapter
supports them.

## Quick questions

Asked anywhere with one shortcut (⌘; to match Claude Code's side chat): a popover runs the
developer's own agent headless and read-only in the project, shows the answer, and keeps
nothing. "Keep" turns it into a session (opened in a Terminal tab, resumable). No branch, no
worktree, no track.

## What happens to what we have

| Today | Becomes |
|---|---|
| Tracks (UI) | Gone as a concept. Checkouts (branch, base, PR) and sessions in them. |
| `TrackStore` | Kept underneath for checkouts: base, PR, git state. Renamed later. |
| Terminals keyed by track | Keyed by project; each session knows its checkout. |
| Branches stage | The full board: sessions grouped by checkout, on demand. |
| Track pill | The focused session's checkout and branch. |
| Agent stage | The graphical view of any session (decision 2). |
| Agent panel | Removed; plan and turns live in Agent's view, files in Changes' review. |
| Split view | Removed; the reply overlay answers in place (decision 5). |
| Checkpoints | Folded into review: approved hunks committed, with their request. |
| Session keepers, Changes' diff engine, the editor | Unchanged foundations. |

## Phases

1. **Sessions from what Side already sees.** A session registry fed by Side's terminals (program,
   cwd, OSC 7501/9/bell) and `claude agents --json`; all checkouts from git; the session list;
   terminals keyed by project. Tracks stay working underneath.
2. **Hooks.** `side-hook` and an opt-in installer for Claude Code (then Codex and others):
   state with reasons, cwd and worktree moves, subagents, requests, sessions in outside
   terminals.
3. **Attribution.** Edit events into Side's blame; shell-command snapshots; "who changed this"
   also in the Editor's gutter.
4. **Changes as review.** The queue, grouping by request, review state, comments back, commit and
   PR from approved hunks.
5. **The AI layer.** Summaries and drift, on demand.
6. **Agent as a session view; retire the rest.** Agent opens any session; the reply overlay and
   session switcher; the panel and split view removed; tracks out of the UI.

Each phase ships on its own and is useful alone.

**Order, with the terminal engine (2026-11-12).** SwiftTerm is being replaced by Alloy and
libghostty-vt in parallel (`SIDE_RFC_TERMINAL_ENGINE.md`, another session). That work owns the
terminal view and drawing, `Packages/SideSessions` and the terminal benchmarks. Agreed with
that session the same day:

- **Terminal signals come from the keeper, not the view.** The keeper sees every byte whether
  or not Side is attached, outlives Side, and is unchanged by the swap (the view is replaced).
  This RFC adds a typed event frame to the keeper's socket protocol (started, exited, cwd,
  title, notification, bell, program status) and one observable per session on
  `TerminalSessionManager`. Nothing outside reaches into the terminal.
- **OSC 7501 is parsed in the keeper** (a byte scan, as Side's OSC 6973 is), by this RFC, now.
- **Re-keying terminals by project** doesn't depend on the swap and can go ahead.
- The engine session owns `Packages/Alloy`, a new `Packages/SideTerminal`, the terminal view
  and `Benchmarks/Terminal`; this RFC tells it which keeper files it changes before landing.

## Risks

- **Unstable sources.** Claude's agent view and teams are previews; transcripts and
  `~/.claude/jobs` are internal; Codex hooks are experimental. Side reads only documented
  surfaces (hooks, `--json`, app-server, ACP) and degrades when they change.
- **Hooks can be dropped** when an agent rewrites its settings (reported for iTerm2's). Side
  checks they're still installed and says so when they aren't.
- **Attribution in a shared folder** is best effort; formatters and shells blur it.
- **Competition moves.** Zed (terminal threads) and Claude Code desktop are closest; the moat is
  attribution, review and persistence together, not any one feature.
- **Size.** Track keys run through terminals, Agent, Changes and Branches; phase 1 decouples
  terminals first so the rest can follow.

## Decisions (2026-11-12, all taken)

1. **Hooks:** user-wide (`~/.claude/settings.json`), opt-in, asked once, removable, listed in
   Settings; per project (`.claude/settings.local.json`) for anyone who prefers it. Credentials
   are never read or touched.
2. **Agent stays, as the graphical view of a session** (changed from the draft's "retire the
   chat": the owner's aim is that developers needn't live in a terminal).
3. **No session sidebar.** Attention in the pill and a reply overlay; finished work in Changes;
   everything else on demand in a session switcher and the Branches board.
4. **Discarding** a hunk that later changes build on is refused, with what depends on it shown
   and an offer to discard them together.
5. **The split view is dropped.** Its real job, answering an agent without leaving your work,
   goes to the reply overlay; a keystroke flips between your work and the focused session.
6. **The AI layer runs on demand** ("Summarize" in a review), with automatic-on-finish as an
   opt-in once its cost is known.
7. **Agents in order:** Claude Code fully first, then Codex (app-server, hooks), then ACP agents;
   everything else gets terminal signals and OSC 7501.
