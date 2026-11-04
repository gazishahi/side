# Agent's side panel: the branch beside the conversation

Status: agreed (2026-11-04: the owner took all three recommendations: hidden below the docking
width and shown floating on request; all four sections; the empty stage's offer). Nothing built yet.

## Why

The owner, 2026-11-04: the Agent stage "feels very empty on a wide screen." The conversation is a
column of at most 860 pt (`ThinkWorkspaceViewController.columnWidth`), centred; on a 1,700 pt
window, half the stage is empty margin. Stretching the column would make lines too long to read.
The owner agreed to a side panel the same day, and asked how it should behave in a small window:
hidden, or floating as the file explorer does.

## What it shows

What the agent is doing to the branch, so you can follow without leaving the conversation. Each
section hides when it has nothing to say.

1. **Plan.** The agent's todo list, live: ACP's `plan` updates (Claude Code's TodoWrite, Codex's
   plan) as a checklist, with the current item marked. Side drops these today: `ACPHarness`
   handles no `plan` update, so the panel is the first place they'd show.
2. **Changed files.** This track's files against its base, with +/− counts, as in Changes' list.
   A click opens the file in Editor; a second action opens it in Changes.
3. **Terminals.** This track's Terminal tabs: name, program mark, the working shimmer or the
   finished dot. A click goes to the tab.
4. **Checkpoints.** The latest few, newest first, each with its verification word. A click opens
   the checkpoint sheet.

The panel is about the branch, not the conversation: switching conversations on the same track
keeps it as it is.

## Layout

- **Docked** when the stage is wide enough for both: the 860 pt column, the panel (280 pt) and
  margins. That's a stage of about 1,240 pt or wider. The panel sits at the trailing edge, the
  column stays centred in what's left, and nothing moves when the panel's content changes.
- **Narrower than that:** see decision 1.
- A toggle in the Agent stage's top row, and a View menu item with a shortcut of its own
  (⌥⌘0 is already Go to Branches), hides or shows it. The choice is remembered per window,
  and a hidden panel stays hidden.

## Decisions (2026-11-04: all three as recommended)

1. **Below the docking width: hidden or floating?**
   - **Hidden (recommended).** The toggle stays in the top row. Clicking it shows the panel
     floating over the conversation's trailing edge, as Editor's file explorer floats. It closes on
     Escape, on a click in the conversation, or when the window grows wide enough to dock it. Below
     the docking width nothing covers the conversation unless you ask, and the explorer's behavior
     carries over.
   - Floating by default: always over the conversation's edge. On a laptop screen it would cover
     the text you're reading while the agent writes it.
2. **Sections:** all four, or start with Plan and Changed files? Recommended: all four. Terminals
   and Checkpoints are small and already have their data in Side.
3. **The empty stage's first offer.** The shared-chats RFC put "Pick up where you left off in
   Terminal" on an empty Agent stage. With the panel docked, that offer goes in the conversation
   column and the panel shows the branch as usual. Recommended: yes.

## How

1. `AgentBranchPanel` (a view controller in Side) with one section view per kind, each fed by
   what already exists: `TrackOverlap.changedPaths` and `GitDiffComputer` for files;
   `RunWorkspaceViewController`'s items (filtered by track) for terminals;
   `AgentSessionStore.checkpoints(forTrackKey:)` for checkpoints. For the plan, `ACPHarness`
   learns the `plan` update and keeps the latest list per conversation.
2. `ThinkWorkspaceViewController` lays the column and the panel out with one rule: docked when
   `stage width ≥ columnWidth + panelWidth + margins`, otherwise per decision 1. The column's
   centring moves from the stage's width to the width that's left.
3. Floating (decision 1) reuses the explorer's child-panel approach (`FileExplorerPanel`), so
   it follows the window and leaves with the stage.
4. UI checks (`scripts/uitest/`): docked at 1,400 pt, hidden at 1,000 pt and shown floating by
   the toggle, the plan updating from the stand-in `claude`.
