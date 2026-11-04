# One Claude Code history: Terminal and Agent share chats

Status: agreed (2026-11-04: the owner took both recommendations: the menu and an empty Agent
stage both offer it; Claude Code first). Nothing built yet.

## Why

The owner, 2026-11-04:

> I can't access my Claude Code chats in Agents, and I don't know if I can access my Agents
> chat that I used with Claude Code in Claude Code in Terminal. … this is probably why I still
> use Claude Code in Terminal and not in Agents.

Today the two stages keep separate histories. Terminal's Claude Code writes its sessions where
it always does. Agent's conversations open with `session/new` and come back only through
Side's own record of what it showed (`OutsideSessionLog`, in `.git/side/think/outside`).
Neither stage lists the other's chats.

## What's already true

Verified against `@agentclientprotocol/claude-agent-acp` 0.81.1, the adapter Agent runs:

- Its sessions are Agent SDK sessions, stored in Claude Code's own session store
  (`~/.claude/projects/<folder>/<session id>.jsonl`), the store the `claude` CLI reads and
  writes. An Agent conversation's `agentSessionId` is a Claude Code session ID.
- `session/list` is the SDK's `listSessions({ dir: cwd })`. It returns every session for the
  folder, including ones started in a terminal, each with a title (the session's summary) and
  when it was last changed.
- `loadSession: true` is advertised. `session/load` replays the session's messages and then
  continues it.

So the work is mostly Side's: the IDs already line up.

## What the person sees

- **In Agent, "Continue a Claude Code chat…"** in the conversation menu. It lists this
  project's sessions, most recent first, each with its title and age. Ones running in a Terminal
  tab right now are marked as running there. Picking one opens it in Agent: its history drawn
  from the replay, then the composer, ready to continue.
- **In Agent, "Continue in Terminal"** on a conversation. A new Terminal tab runs
  `claude --resume <session id>` in the track's folder. The Agent conversation shows "Continued in
  Terminal" with a link to the tab.
- **On a Terminal tab running Claude Code, "Open in Agent"** in the tab's menu. Side knows the
  tab's session ID already: the keeper records it as `agentSession`, for restarts. It opens that
  session in Agent. The tab is left as it is, and Side warns when both would be live at once.

## How

1. **Listing.** `ACPHarness` gains `listSessions(cwd:)`, used when the agent's
   `sessionCapabilities` include `list`. It's fetched when the menu opens and never at launch.
2. **Opening a listed session.** It works as reopening a stored conversation does today
   (`session/load` with `storedAgentSessionId`), with one change: the replay is drawn when Side
   has no record of the conversation. Today it's skipped (`replaying`) because Side's own record
   already shows it. The drawn replay is then written to `OutsideSessionLog`, so a relaunch
   brings it back as any conversation does.
3. **To Terminal.** `RunWorkspaceViewController` gets `openSession(command:directory:)`, the
   path Run Again already uses with a command typed into a new shell.
4. **From Terminal.** The tab's keeper record already carries `agentSession`
   (`SessionKeepers.recovery`). The tab menu item hands that ID to Agent's open path.
5. **Both live at once.** Two Claude Code processes on one session each append to the same
   transcript; the second one's view goes stale. Side marks a session as live in the Terminal
   when a tab's keeper reports it, and asks before opening it in Agent as well ("It's running in
   Terminal tab 2. Open it here as well?").

## Decisions (2026-11-04: both as recommended)

1. **Where "Continue a Claude Code chat…" lives:** the conversation menu only, or also as an
   empty Agent stage's first offer ("Pick up where you left off in Terminal")? Recommended: both.
   An empty Agent stage on a wide screen has room for it (the owner's other note that day).
2. **Other agents:** Codex's adapter has its own session store. Same treatment once it lists
   sessions, or Claude Code only for now? Recommended: Claude Code first.
