# Design sessions: split view, the Agent stage, customization

Status: agreed (2026-11-07: the owner took every recommendation). Three sessions from the scoping
list of 2026-11-06. Building: Session 1's companion.

Two of the three lean on plans the owner has already agreed and not yet built:
- `SIDE_RFC_AGENT_PANEL.md`: the branch beside the conversation;
- `SIDE_RFC_SHARED_CLAUDE_SESSIONS.md`: Terminal and Agent share Claude Code chats;
- `SIDE_RFC_GIT_TRACKS.md`: every branch is a track, and Branches becomes the live board.

This document doesn't re-decide those. It says where the new ideas fit around them.

**Not yet measured:** the battery test for Settings › Appearance › Surfaces hasn't been run
(`SIDE_SURFACES_MEASUREMENT_2026-11-06.md`). Session 3's "Solid on battery" idea waits on it.

---

## Session 1: split view and the live sessions board

### Where we are

How the owner works (2026-11-03): Editor and Terminal, with Claude Code running in Terminal's
tabs, often six or more at once. Today the two stages take turns owning the window, so following
what a session is doing means switching stages: ⌘1 to look at the file, ⌘4 to see the session,
and so on. The activity pill shows which sessions are working or need you; nothing shows them
side by side with their work.

The direction list said "one task owns the canvas", not tiling. Constitution article 1 says "one
stage owns the canvas". Split view needs the article to change, or it breaks the rule.

### Proposal: a stage and its companion

The canvas holds **one stage**, and optionally **one companion** at its trailing edge: a single
Terminal session, docked. Never more than two panes, no free-form tiling, no splits inside
splits.

```
┌──────────────── Editor ────────────────┬──── Terminal: claude ────┐
│ SIDE/TrackPill.swift                   │ ● Working · fix/pill     │
│                                        │ > Editing TrackPill…     │
│   func retitle(...) {                  │                          │
│ ▌   widthSpring.run(...)   ← just edited│                          │
│   }                                    │                          │
│                                        │ ─────────────────────── │
│                                        │ ❯                        │
└────────────────────────────────────────┴──────────────────────────┘
```

- **Opening it:** "Show Beside Editor" on a Terminal tab (menu, and a shortcut), or dragging a
  tab to the window's trailing edge. The tab moves out of Terminal's tab row into the companion
  and goes back when the companion closes.
- **Which stages take a companion:** Editor and Changes. Agent has its own panel (agreed),
  Terminal is already the session, and Branches is the board.
- **Width:** the companion keeps its own width, dragged at its edge, remembered per window. Below
  a window width where both fit (Editor needs about 600 pt, the companion about 420 pt), it hides
  and the toggle shows it floating, as the Agent panel decision has it. One rule for both.
- **Follow:** with Follow on, Editor opens the file the session last changed and puts the edit in
  view. A click or a keystroke in Editor turns Follow off until you turn it on again, so it never
  pulls a file out from under you.

**How Side knows what the session changed:** see decision 3. Claude Code in a terminal doesn't
tell Side which file it edits.

### The board

The live board is Branches rebuilt (`SIDE_RFC_GIT_TRACKS.md`, phase 2). Each branch is a row,
and under it its sessions: Terminal agents, Agent conversations and checks, each with its state
(working, needs you, finished, idle) and what it last did.

```
fix/pill  ↑3 · 2 files · PR #41 open
  ● Claude Code   Working   "Editing TrackPill.swift"         Show Beside ▸
  ◐ Codex         Needs you "Run swift test?"                 Show Beside ▸
main  · 1 uncommitted
  ○ zsh           Idle
```

- A click on a session opens it in the companion beside Editor. On the board it's the main act,
  so Branches stays a stage of its own.
- The activity pill keeps its job (what needs you, from anywhere) and gains "Show on board".

### Decisions

1. **The article.** Change article 1 to: "One task owns the canvas: a stage, and at most one
   companion beside it, showing the same track." Recommended.
2. **What the companion can hold.** (a) A Terminal session only (recommended for the first
   build); (b) also an Agent conversation; (c) also a diff from Changes beside Editor.
3. **How Follow knows the file.**
   - (a) **File changes in the session's worktree while it's working** (recommended first). It
     works with any agent and needs nothing installed. Two sessions in one worktree can't be
     told apart, so Follow names the file as "changed in this branch".
   - (b) **Claude Code's hooks:** a `PostToolUse` hook reporting each edit to Side, added to the
     launch with `--settings` only for sessions Side starts, never written into the user's Claude
     config. Exact per session, Claude Code only. Later, once (a) proves the idea.
4. **Follow on or off when the companion opens.** Recommended: on; one click turns it off.
5. **Order.** The companion doesn't need git tracks. The board does (phase 2). Recommended: the
   companion first, then git tracks phase 1, then the board.

---

## Session 2: the Agent stage beyond chat

### Where we are

- The owner uses Claude Code in Terminal, not in Agent. Their reason, 2026-11-04: Agent can't
  open their Terminal chats, and the reverse. The shared-chats RFC (agreed) fixes that; it isn't
  built.
- Agent is a centred column of at most 860 pt. On a wide screen half the stage is margin. The
  Agent panel RFC (agreed: plan, changed files, terminals, checkpoints) fills it; not built.
- A transcript holds text, tool calls and results, thinking, proposals, commands with live
  output, checkpoints. Markdown is drawn; nothing richer than that is.
- No way to move through a long conversation except scrolling.

### Proposal, in order

1. **Build the two agreed plans first:** shared chats, then the panel. Until Agent can open the
   sessions the owner already has, nothing else in the stage gets used.
2. **The jump bar** (built 2026-11-07: `JumpRail`, `scripts/uitest/check-jump-bar.sh`; shown from
   two messages up, the current message's tick drawn longer). A thin rail at the column's trailing edge with one tick per message you sent,
   placed by where it falls in the conversation. Hover shows the message's first line; a click
   scrolls to it. ⌥⌘↑ and ⌥⌘↓ go to your previous and next message. Ticks for turns that failed
   or wait on you take the status colors, so the rail also shows where things went wrong.
3. **Rich blocks** (first set built 2026-11-07: Mermaid, CSV/TSV and Markdown tables, SVG and
   `![…](path)` images in the track's folder; `RichBlocks.swift`, `scripts/uitest/check-rich-blocks.sh`.
   Mermaid 11.4.1 ships in the app and draws in a web view that loads nothing and navigates
   nowhere, at Mermaid's strict security level. Charts and HTML are next). An agent's fenced code block in a known form draws as the thing itself, with
   a toggle back to its source:
   - `mermaid`: a diagram;
   - `csv` / `tsv`, and Markdown tables: a sortable table;
   - `svg`, and images the agent writes into the project: the picture;
   - `vega-lite` (JSON): a chart;
   - `html`: a preview in a sandboxed web view with no network and no file access, on request,
     never automatically.

   Each is drawn on demand, as a block scrolls into view, and is a picture of the text, so the
   transcript and its saved record stay plain text.
4. **Later, one level up:** the conversation's own outline (what was asked, decided, changed),
   built from the jump bar's data and checkpoints, for a conversation of hundreds of turns.

### An alternative to weigh

**Agent as a reader of Terminal's sessions.** Instead of running its own Claude Code process,
Agent could show the session running in a Terminal tab, by reading its transcript file
(`~/.claude/projects/…/<session>.jsonl`) as it grows, with a composer that types into that tab.
One process, two views of it: Terminal's text and Agent's rich one. It removes the "both live at
once" problem the shared-chats RFC works around. Against it: it's Claude Code only, the file
format isn't a public contract, and permission prompts would still be answered in the terminal.

### Decisions

1. **Order:** shared chats, the panel, the jump bar, then rich blocks. Recommended.
2. **Which rich blocks first.** Recommended: Mermaid, tables and images; charts and HTML after.
3. **HTML previews:** allowed, on request, sandboxed? Or never? Recommended: on request.
4. **The alternative:** keep Agent running its own sessions (recommended, with shared chats), or
   explore Agent as a view of Terminal's sessions in a spike first.

---

## Session 3: how far customization goes

### Where we are

Built: appearance (light, dark, system), Side's text size, editor and terminal text sizes, editor
themes for light and dark with VS Code import, three fonts, and Surfaces (Liquid Glass or Solid,
on restart). The theme rework is on the backlog.

The owner floated whole looks (Windows, Material 3). The recommendation stands against skins:
each look doubles the visual work on every surface and goes against Side being one designed
system (`docs/SIDE_DESIGN.md`).

### Proposal: a few deep settings, all made of tokens

Each is a change to `DesignSystem.swift`'s tokens, never to a component, so every surface follows
without its own work.

| Setting | Choices | What changes | Applies |
|---|---|---|---|
| Surfaces | Liquid Glass, Solid | built | on restart |
| Accent | System, Side's own, or six picks | selections, primary buttons, the focused stage | live |
| Corners | Round (now), Squarer | every `DS.Radius` token scaled (about 0.5×) | on restart |
| Density | Regular (now), Compact | row heights, the bar's height, paddings | on restart |
| Interface theme | follows the editor theme, or not | Side's surfaces tinted from the editor theme's background | live |

- **Accent never stands for status.** Needs-you, failed and working keep their own colors under
  any accent (already the rule in DS).
- **Solid on battery** (after the battery test): a third Surfaces choice, "Liquid Glass, Solid on
  battery". Only worth offering if the battery numbers show glass costs real power.

### Decisions

1. **Which settings:** accent, corners, density, interface theme. Pick any. Recommended: accent
   and interface theme first: they're live, and they're what makes Side feel like yours.
2. **Skins:** confirm no whole looks (Windows, Material 3). Recommended.
3. **Solid on battery:** decide after the battery test.

---

## Not in these sessions

- The project switcher redesign (`backlog-later`): the owner wants to design it together as its
  own session.
- Vim mode: waits on the owner's answers in `SIDE_RFC_VIM.md`.
