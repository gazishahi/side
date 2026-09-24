# RFC: Multi-agent work across providers

*2026-09-23. Status: **accepted**: the owner accepted M1–M4 as recommended the same day. Steps 1–2 built; see Plan.*
*Companion to `SIDE_PRODUCT_CONSTITUTION.md` (non-negotiables 1–5 and 8 are at stake),
`SIDE_RFC_BYO_HARNESS.md` (outside agents, which this builds on) and
`SIDE_RFC_NAVIGATION_LEDGER.md` (R3 runner ceiling, R4 track tools).*

## The ask

One agent the user talks to that can hand parts of a task to other agents, including agents
from other providers: Claude Code coordinating, a Gemini agent writing the migration, Codex
writing the tests. Cursor ships a version of this ("Projects": a coordinator agent in one
persistent thread that manages subagents and improves over time).

The line to hold: **every agent's work is a track.** Multi-agent is not a new kind of object;
it is tracks creating and reading tracks, with the same worktrees, checkpoints, attention and
promotion every track already has.

## Why it can't happen today

- A track has exactly one agent, and no agent can create or talk to other tracks.
- Outside agents can't see Side's track tools at all: `list_tracks` and `read_track_overlap`
  exist only for Heron, because Side opens outside sessions with no tools (`mcpServers: []`).

## Design

**The coordinator is a track; its subagents are child tracks.**

- *Umbrella track.* The user creates a track ("Ship billing v2") and talks to its agent. That
  agent is the coordinator. Any agent can be one: Heron, Claude Code, Codex, Gemini.
- *Subagents are stacked children* of the umbrella track: each has its own worktree, its own
  agent (a parameter when it's created, so cross-provider is free), its own checkpoints and
  its own autonomy. They appear in the Tracks tree under the umbrella.
- *Track tools* for the coordinator: `create_subtrack(intent, agent, instructions)`,
  `message_track(track, text)`, `read_track(track)` (status, last reply, checkpoints and their
  verification), `wait_for_tracks(tracks)`, plus the existing `list_tracks` and
  `read_track_overlap`.
- *Results come back the way they already do:* a child's checkpoints promote into its parent
  (stacked promotion is built). The coordinator can propose a promotion; a person approves it.
  Promotion to `main` is always a person's.
- *Communication is hub and spoke, and visible.* A coordinator's message appears in the child's
  transcript as a turn marked "From the coordinator". The child's answer is read back with
  `read_track`. There is no hidden agent-to-agent channel.
- *Any agent can use these tools* because Side serves them over MCP (step 1) and hands the
  server to every outside session. Heron gets them directly.

**Why it keeps the constitution:** tracks stay primary (subagents are tracks); attention stays
explicit (a child that needs the user lights its parent's row and the pill); people promote;
no two agents share a checkout (each child has its worktree, so the v1 non-goal "parallel
background agents mutating one live checkout" still holds); one stage owns the canvas (the
coordinator's Think shows one status line per child; clicking opens that track).

**Not a forever thread.** Cursor's single always-on thread is the chat-as-navigation pattern
Side exists to avoid. An umbrella track lives while its work does, then promotes and archives.
"Improves over time" becomes project memory: the coordinator proposes edits to `AGENTS.md`
(acknowledged by the user, as today), later the Library. "Proactive" is already possible:
agents run in the background with no window showing them.

## Guardrails

- **Caps:** at most 4 children per coordinator, one level deep (a child can't create
  subtracks), and the 4-runner concurrency ceiling (navigation RFC R3, accepted, not built;
  it lands with step 2).
- **Spend:** usage rolls up per umbrella track and counts against the existing monthly budget.
- **Overlap:** sibling overlap is checked before a child is promoted into its parent.
- **Evidence over claims:** `read_track` returns each checkpoint's verification, so the
  coordinator reports test results, not a child's own account.

## Decisions

- **M1: Who approves a spawn?** *Recommend:* `create_subtrack` is a card under Manual and
  Guarded; Full creates without asking. A spawn creates a branch and a worktree, and starts
  spending.
- **M2: Auto-promotion.** *Recommend:* under Full autonomy a child may be promoted into its
  parent without a card when its latest checkpoint is verified and has no overlap with a
  sibling; never into `main`.
- **M3: Caps.** *Recommend:* 4 children, depth 1, as above; raise later only with evidence.
- **M4: Can a child talk to a sibling?** *Recommend:* no. Only through the coordinator.

## Plan

1. **Side's tools over MCP.** A local MCP server (Streamable HTTP on 127.0.0.1, one
   unguessable URL per conversation) serving the existing read-only track tools, handed to every
   outside session whose agent supports HTTP MCP servers. Useful on its own: outside agents can
   see other tracks for the first time.
   **Built 2026-09-23:** `SideToolServer`; `ACPHarness` passes it in `mcpServers`.
2. **Subtracks:** `create_subtrack`, `message_track`, `read_track`, `wait_for_tracks` (Heron and
   MCP), the M1 card, the caps, the R3 ceiling.
   **Built 2026-09-23:** `TrackCoordinator` (app), `CoordinationBridge` / `TrackCoordinating` /
   `SubtrackRequest` (Heron). Heron gets the four tools directly (create and message in Build;
   read and wait in Plan too); outside agents get them over MCP. A spawn is the command card's
   third kind ("Hand work to a subtrack" · Create), created without asking only under Full (M1);
   for an outside coordinator, allowing the call on the agent's own permission card covers
   Side's (D9). Subtracks are created without switching anyone's view (`spawnedByCoordinator`,
   status Waiting, the coordinator stays active), capped at 4 live per coordinator and one level
   deep (M3), messaged only by their own coordinator (M4), their messages marked "From the
   coordinator". At most 4 agents stream at once per project; the rest's messages queue (R3).
   `wait_for_tracks` holds up to 120 s, then reports what's still working. Verified live: Claude
   Code created a subtrack on another agent, waited for it and reported its reply.
3. **Coordinator UI:** child status lines in Think, attention and spend rolled up to the
   umbrella row, promote-into-parent proposals as cards (M2).

## Acceptance (step 1)

- [x] An outside agent sees `list_tracks` and `read_track_overlap` and gets the same answers
      Heron does.
- [x] The server listens on 127.0.0.1 only; a request without the conversation's own path is
      refused.
- [x] A conversation's tools stop answering when it ends.
