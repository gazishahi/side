# RFC: Find, Review and Tracks, and staying light

*2026-09-25. Status: **accepted**: the owner chose the directions on 2026-09-25 (Find as one
search surface; Review "changes first" with a summary on top; Tracks as a switcher on the track
pill plus a list to manage them). Build order below. Step 1 built.*
*Companion to `SIDE_DESIGN.md` (tokens, glass), `SIDE_RFC_ALLOY.md` (the renderer Review's diffs
move to) and `SIDE_LAUNCH_PERFORMANCE.md` (how Side measures).*

## Why

- **Find** is still AppKit's find bar: a different look, a different place, and a different set
  of keys from everything else in Side.
- **Review** can't hold a real change set. On a 200-file diff it took 36 s and 325 MB to show,
  because every file gets its own fully laid-out text view up front (`ReviewBudgetTests`).
  It also reads as dated next to the rest of Side.
- **Tracks** is a separate screen for what is mostly a quick switch.
- **Think** keeps every entry of a conversation as a live view: about 2 MB a turn on screen, a
  core of CPU while streaming, and freed memory the allocator can't give back
  (`ThinkBudgetTests`). Long sessions reach hundreds of MB.

## What measuring showed (2026-09-25, a copy of Khidma, optimized and debug builds alike)

| Situation | Before | After this week |
|---|---|---|
| Project open, nothing else | 35 MB | 35 MB |
| A large file open, Side in front | ~165 MB | ~155 MB (the GPU driver's render memory, see below) |
| Three large files open, Side in the background | ~160 MB | 64 MB |
| All tabs closed | 76 MB | 58 MB |
| Idle CPU / wakeups | 0% / ~3 per 2 s | 0% / ~1 per 2 s |
| Heron, 20 streamed turns, no view | — | +9 MB |
| Think view, 20 turns on screen | — | +39 MB, one core while streaming |
| Review, 200-file diff | 36 s, +325 MB | (step 3) |

The graphics driver holds ~90 MB for rendering from the first Metal render pass and frees it
after a few seconds with none (measured on an M3 Pro with a bare Metal program: 99 MB after one
frame, 7 MB after 3 s idle, and 37 ms for the first frame after that). Alloy now renders nothing
while Side isn't the active app or the editor isn't in the key window, so the driver frees it;
while you're typing it stays warm, so keys never pay the 37 ms.

## Budgets (acceptance, measured by the opt-in budget tests)

| Measure | Budget |
|---|---|
| Idle, Side in the background, any project | ≤ 80 MB, 0% CPU, ≤ 2 wakeups a second |
| Review, 500 changed files | open ≤ 300 ms, ≤ 60 MB, scrolls at 120 Hz |
| Think, 200-turn conversation on screen | ≤ 60 MB for the view, ≤ 25% of a core while streaming |
| Find in a 100,000-line file | matches ≤ 50 ms, next match ≤ 8 ms |

## Decisions

- **F1: Find is a mode of the palette** (same bottom surface, same Liquid Glass as Quick Open).
  ⌘F finds in the file, with every match marked in the editor as you type and a list of matching
  lines; ⌥⌘F adds the replace row; ⌘G / ⇧⌘G step through matches with the palette open or
  closed; ⌘E uses the selection. Case, whole word and regular expression are toggles in the
  header. Tab moves the same query between This File and Project (⇧⌘F). Replace All is one undo
  step. AppKit's find bar goes.
- **R1: Review is "changes first" with a summary on top.** A summary card (the agent's account of
  the change, verification, risks) over a file rail (paths with +/− counts, a viewed check) and
  the diffs; checkpoints as a timeline you can pick a range from; Publish and Promote in a slim
  header.
- **R2: Review's diffs are drawn by Alloy** (read-only, with added and removed line colors and old
  and new line numbers), and only the files near the viewport are built.
- **T1: Tracks is a switcher on the track pill** (search, recent first, new track) **plus a list to
  manage them** (title, branch, last activity, a status chip; a detail pane with checkpoints and
  agents).
- **E1: Think's transcript builds only the entries near the viewport**, with measured heights kept
  for the rest; streaming updates are coalesced to the display rate.

## Plan

1. **Find** (F1).
   **Built 2026-09-25:** `PaletteMode.find` with `InFileFind` (matches, options, replacements,
   stepping). The header holds the count ("3 of 11", or why an expression is invalid) and the
   Aa / W / .* toggles and the replace toggle; the replace row has Replace and All (⌥Return).
   Every match is marked in the editor (`EditorDecoration.findMatch`, the current one
   `findCurrent`), the list has one row per matching line (five rows, so the editor stays in
   view), Return / ⇧Return step, ↑↓ move between lines, Escape leaves the match selected. The
   editor's bottom inset rises above the palette while it's open, and Alloy's scroll-to-visible
   now keeps a line clear of insets (AppKit's counted what's under an inset as visible). Replace
   All is one undo step (`EditorEngine.applyEdits`). ⌘G / ⇧⌘G work with the palette closed; ⌘E
   uses the selection; Tab moves the query to Find in Project and back. The Edit menu's find items
   target the shell; AppKit's find bar is no longer used. `FindTests` covers the model and the
   mode in Make; checked in Side on a real file.
2. **Efficiency: Think's transcript** (E1), measured by `ThinkBudgetTests`.
3. **Review's diff view on Alloy** (R2), measured by `ReviewBudgetTests`.
4. **Review's layout** (R1).
5. **Tracks** (T1).
6. **Budgets in one place**: the budget tests run together against the table above.
