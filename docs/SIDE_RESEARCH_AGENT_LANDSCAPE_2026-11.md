# Research: how developers run coding agents (November 2026)

Status: research, for discussion (2026-11-08). No decision taken. Three web-research passes:
IDEs with agents; tools that run several agents; terminals and the CLI agents. Claims marked
*[2nd]* rest on secondary sources; check before quoting them.

Why: the owner doubts the track model (track = branch = one agent), and asked what the rest of
the field does before we decide anything.

## What the field has converged on

1. **The unit is a session (thread, task, workspace), not a branch.** Listed in a sidebar,
   grouped by project, each with a status: working, waiting on you, done. Finished ones are
   archived. Cursor 3's Agents Window, VS Code's Agents window, Zed's Threads Sidebar, Claude
   Code desktop, the Codex app, T3 Code, Superset, Emdash, Conductor all do this.
2. **One task = one worktree + branch + agent, made by the tool.** Starts at a prompt or issue,
   ends at a PR. Almost every manager (Conductor, Superset, Emdash, Vibe Kanban, Claude Squad,
   T3 Code, Codex app, Claude desktop) works this way. Containers (Sculptor, Container Use) and
   cloud VMs (Codex Cloud, Claude web, Jules, GitHub Agent HQ) are the alternatives.
3. **Review is a diff with line comments sent back to the agent,** then commit, PR, CI, and
   increasingly auto-fix and merge-when-ready (Claude desktop, Superset, Vibe Kanban, Warp, Air).
4. **Bring your own agent and subscription is normal.** ACP has a registry of ~50 agents (Zed,
   JetBrains, Devin Desktop host it); VS Code hosts Claude and Codex harnesses; managers drive
   installed CLIs.

## Who's closest to Side

- **Zed, Terminal Threads (2026-05-20):** Claude Code, Codex or Amp running in a terminal is a
  thread in Zed's sidebar, titled from the terminal, notifying on the bell. A real editor plus
  terminal agents: the nearest thing to Side's thesis. Gaps: state is only the bell and the
  title; terminal threads don't archive; review is the normal git flow.
- **cmux** (~29k stars, native Swift on libghostty): attention rings on panes, sidebar rows with
  branch, PR, ports and last notification, a socket API, agent hook setup. No live process
  persistence (layout and scrollback only). No editor.
- **Rex (Mitchell Hashimoto's Superlogical, beta 2026-10-05):** server-owned sessions, the
  **Program Status Protocol (OSC 7501)**: a program reports idle, working, waiting, finished,
  failed. Herdr (~49k stars) uses it too. No worktrees, no review, no editor.
- **Herdr:** agents in a server that survives the app; agents can drive Herdr (spawn panes,
  prompt and wait on each other).
- **Superset, Emdash, T3 Code:** worktree-per-task managers with review and PRs; no real editor
  (they hand off to Cursor, VS Code or Zed).
- **Claude Code desktop:** parallel sessions, optional worktrees, diff comments, PR and CI,
  merge-when-ready, an editable file pane, and **side chat (⌘;, /btw)**: a quick question that
  reads the session and writes nothing back. Doesn't show CLI-started sessions *[2nd]*.
- **Conductor** joined Meta (2026-11-04); its cloud shuts on Nov 20. Its Mac users are looking
  for somewhere to go.

## What a host can observe about agents now

- **Claude Code** is rich:
  - `claude agents --json` gives each background session's cwd and its state (working,
    blocked, done, failed, stopped); blocked always means needs input.
  - There are 33 hook events, among them Notification (permission, idle, needs input,
    completed), Stop, CwdChanged, FileChanged, WorktreeCreate, SubagentStart and
    TeammateIdle. Each carries session_id, cwd and agent_id.
  - Sessions can message each other through a socket per session.
  - It creates worktrees itself (`--worktree`, the EnterWorktree tool, subagents with
    worktree isolation), and a session's cwd moves mid-session.
  - Transcripts and `~/.claude/jobs` are explicitly internal.
- **Codex:** `codex app-server` (JSON-RPC: threads, turns, file-change items, diffs), hooks
  (experimental), a notify program. **OpenCode:** HTTP server with an event stream; ACP with
  session listing. **Copilot CLI, Qwen Code, Antigravity CLI:** hooks and/or ACP.
- **Universal fallbacks:** OSC 9/99/777 and the bell (lossy: no reason given), OSC 7501 where
  emitted, the process's cwd, `git worktree list`, `git diff` in the agent's folder.
- **ACP** covers plans, structured file diffs and session listing, but not subagents, worktrees
  or supervising many sessions.
- **Churn:** Gemini CLI was replaced by the Antigravity CLI for free users (2026-06-18); Roo Code
  shut down; Aider is in maintenance; Vibe Kanban's company closed; Terragon shut down.

## What nobody has solved

1. **Agents the tool didn't start.** Agents that make their own worktrees, and sessions started
   in a plain terminal, are invisible to managers built on "the tool creates the worktree".
2. **Several agents in one folder.** Allowed everywhere (T3 Code's "Local" threads share the
   checkout; so do several Claude Code tabs), but nobody knows whose edit is whose or warns of
   collisions; T3 users asked for agents to see sibling threads for that reason. The exception is
   **GitButler**: Claude Code hooks tell it which session edits which file, and it sorts each
   session's edits onto its own virtual branch in one folder (one session to one branch; adjacent
   lines can't be split). Corrected 2026-11-08.
3. **Quick questions.** Only Claude's side chat and Codex's Quick chat treat a question as
   something other than a task; elsewhere a question starts a worktree.
4. **Review is the bottleneck.** N agents make N diffs for one person; practitioners say 2–4
   parallel agents is the real limit. No one offers one review queue across sessions and
   worktrees.
5. **A real editor with agent supervision for CLI agents.** Managers are diff viewers; the
   IDEs that manage agents drive their own (Devin Desktop alone hosts outside ones, via ACP).
6. **Live sessions surviving restarts.** Terminals restore layout, not processes; only server
   designs (Rex, Herdr, T3, and Side's keepers) keep agents alive, and none survives the machine
   shutting down. Rex runs a local server in its Mac app and attaches to servers you host
   yourself (a Linux VM, say) over Tailscale; Superlogical hosts nothing. Surviving a laptop
   being off needs a remote host, and with it remote editing, git and LSP: a project of its own.
7. **Status signals depend on agents adopting them** (hooks break silently when an agent rewrites
   its settings; OSC 7501 isn't emitted by the harnesses yet).

## What it suggests for Side (to discuss)

- Tracks as the unit of work are behind the field, not just wrong for one workflow: everyone
  moved to sessions. But the field's own model (the tool makes the worktree) breaks on gaps 1–3,
  which is where Side could lead.
- A sharper thesis than "supervise CLI agents" (Zed and cmux already do a version): **Side sees
  every agent working in your project however it was started and wherever it went, tells you
  which needs you, and lets you review and edit what it changed in a real editor, with sessions
  that survive restarts and updates.**
- That means observing, not owning: sessions as the unit, discovered from hooks, `claude agents
  --json`, ACP, OSC 7501 and the process tree; branches and worktrees as places a session is;
  changes attributed to the session that made them; one review queue; quick asks that cost
  nothing; Side's keepers for persistence.
- Standards worth adopting: emit and read OSC 7501; read Claude's agent list; offer (with
  consent) to install agent hooks; ACP for structured diffs and plans.
- Risks: the APIs above are young and some are internal; Zed or Claude desktop could close the
  gap; attribution in a shared folder is hard.
