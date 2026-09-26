# RFC: Find, Review and Tracks, and staying light

*2026-09-25. Status: **accepted**: the owner chose the directions on 2026-09-25 (Find as one
search surface; Review "changes first" with a summary on top; Tracks as a switcher on the track
pill plus a list to manage them). Build order below. Steps 1–4 and 6 built.*
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

## Budgets

Every budget is a row of `Budgets.table` (`SIDETests/Budgets.swift`); `scripts/budgets.sh`
measures them all in an optimized build and prints this table (step 6). The ones here are this
RFC's; the editor's own are SIDE_RFC_ALLOY.md's, in the same table.

| Measure | Budget |
|---|---|
| Idle, Side in the background, files open | ≤ 80 MB, ≤ 0.5% CPU, ≤ 2 wakeups a second |
| Through every stage and a Markdown preview | peak ≤ 300 MB; ≤ 120 MB 40 s later in the background |
| Review, 500 changed files | open ≤ 300 ms, ≤ 60 MB (drawing buffers apart), scrolls at 120 Hz |
| Think, 200-turn conversation on screen | ≤ 60 MB for the view, ≤ 25% of a core while streaming |
| Find in a 100,000-line file | every match ≤ 50 ms, the next ≤ 8 ms |

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
   **Built 2026-09-25:** the transcript is blocks in slots (`ThinkWorkspaceViewController`'s
   `TranscriptBlock`, `TranscriptSlot`): blocks within two screens of the viewport hold views,
   those beyond four keep only their measured height (blocks never built use an estimate), and a
   block rebuilt above the viewport moves the scroll position by its change in height so nothing
   on screen jumps. Released blocks still read to VoiceOver (their text, or "Worked, N lines").
   A reattach builds views for the last three screens only. `WorkGroupView` builds its lines only
   while open (`addLine(building:released:)`) and lets them go when it closes: a collapsed group of
   40 KB file reads was most of what a long conversation held. Thinking and tool updates now flush
   with streamed text (one update per ~35 ms, not per chunk), and a scroll to the bottom runs once
   per run-loop turn. Heron's stall watchdogs (`Watchdog`) keep one timer and move its deadline;
   re-arming a delayed work item per streamed update had left thousands of 180 s timers pending.
   Measured in Side with a fake agent streaming at a real agent's pace (thinking, four 28 KB file
   reads, a long answer and an edit a turn), optimized build:

   | 60 turns | Before | After |
   |---|---|---|
   | Memory at turn 60 | 156 MB (+119) | 68 MB (+25) |
   | Per turn | ~2 MB, rising | ~0.4 MB (mostly the conversation's own data) |
   | CPU for the session | 85 s, rising each turn | 50 s, flat (~18% of a core while streaming) |

   `ThinkTranscriptTests` covers realization, rebuilding on scroll, a group coming back open, and
   what VoiceOver reads for released blocks. In-process budget numbers need a drained autorelease
   pool per run-loop turn (`ThinkBudgetTests.waitUntil`), as the app's event loop gives.
3. **Review's diff view on Alloy** (R2), measured by `ReviewBudgetTests`.
   **Built 2026-09-25:** `DiffDocumentView`: every file in one read-only Alloy document (split is
   two, scrolled together, row for row). A file is two header rows under a `DiffFileHeader` view
   (chevron, path, NEW/DELETED, Instruct…, counts; a disclosure to VoiceOver), then its hunks;
   folding a file removes its lines. Headers exist only for files in view. Lines are tinted edge
   to edge (Alloy's new `lineBackground`), numbered old and new in the gutter (`AlloyGutterView.label`),
   colored by the file's language (each file's highlighter built off the main thread the first time
   it's on screen, the last twelve kept), and read to VoiceOver as "added, …", "removed, …",
   "section, …", "file, …" (Alloy's `accessibilityLinePrefix`, with every accessibility query
   mapped to that text). Review's page is now the summary and checkpoints on top (as tall as they
   are, up to half the stage) and the diff filling the rest, under the bar; the checkpoint sheet
   uses the same view. `DiffViewer` (a text view per file, built up front) is gone.
   Measured, optimized build, a real 200-file change set and a 500-file one made from it:

   | | Before (200 files) | After (200) | After (500) |
   |---|---|---|---|
   | Open | 36 s | 32 ms | 66 ms |
   | Scroll at 45 pt a frame, p99 | — | 7.7 ms | 7.7 ms |
   | A screen at a time, slowest | — | 16 ms | 14 ms |
   | Memory | +325 MB | ~30 MB for the diff | ~30 MB |

   Beyond the diff itself: the graphics driver's render memory (~95 MB, the first time anything in
   the process draws; freed a few seconds after drawing stops) and two window-sized drawables
   (~17 MB each at 2x, per column). The first run also showed the in-process measurements have to
   drain an autorelease pool per step, as the app's event loop does, or released views appear to
   leak.
4. **Review's layout** (R1).
   **Built 2026-09-25:** the track's intent and `branch → base · N ahead` in the window's top
   row, with Publish and Promote beside them. Below, a summary card: what the agent last said
   about the work (Heron's `AgentSessionStore.latestAgentAccount`, read from the end of the
   conversation's record, three lines with Show more), the verification and overlap lines, and
   the checkpoints as a timeline (`CheckpointTimeline`, `CheckpointTimelineView`): base, each
   checkpoint with a commit on the branch (its ring green or red when verified or failed), and
   Now when the branch has moved past the newest. Clicking a checkpoint shows what it alone
   changed; Shift-click or a drag picks a range; the base, Escape or All changes goes back to
   everything; ← and → step. Copy SHA and Undo… act on the chosen checkpoint. Under the card,
   the changed files (`ReviewFileRail`: name, folder, +/−, a viewed check; Space toggles it)
   beside the diff, which follows the list and is followed by it. A viewed file folds, and
   stays viewed until its diff changes (`ReviewViewedStore` keeps a fingerprint of what was
   seen). The file at the top of the diff keeps its header pinned while its lines scroll under
   it; headers are made under the bottom bar too. Below 820 pt the list gives its width to the
   diff. `ReviewLayoutTests` covers the timeline, viewed marks, folding, pinning and the list.
5. **Tracks** (T1).
6. **Budgets in one place**: the budget tests run together against the table above.
   **Built 2026-09-25:** `Budgets.table` holds every limit and `Budgets.check` prints a row and
   fails past it; `scripts/budgets.sh` builds once, optimized, drops Xcode's Main Thread Checker
   from the run (it checks every AppKit call and read as the UI's cost), runs the suites and
   prints the table. New: `FindBudgetTests`; `AppBudgetTests`, which launches a second Side on a
   generated project and measures it from outside (idle, every stage, and Think streaming from a
   fake agent at a real agent's pace); Review's generates its own 500-file change set. What the
   first runs found, and fixed:

   | | Before | After |
   |---|---|---|
   | Find, every match (plain text) | 52 ms | 10–14 ms: a direct search over the text, not the expression engine (a test holds the two to the same answers) |
   | Find, every match (expression) | 46 ms | 27 ms: over a flat copy, not the rope view |
   | Find, a step without its frame, p99 | 8 ms | 2.3 ms: only the current match's mark moves; mark colors converted once, not per mark |
   | Drawing with many marks | every mark tested per visible line | the marks on screen found once a frame |
   | Review, split, memory | 72 MB | 37 MB: every Alloy editor shared nothing (shaders compiled and a glyph atlas of 4–64 MB each); now one set per GPU |
   | Think, a turn at turn 200 | 327 ms | 70 ms: the transcript was one stack of every block, and each change re-sorted all their constraints; now pages of 40 |
   | Think, reattach to 1,600 entries | 974 ms | 211 ms |
   | Think, measuring a streaming reply | the whole message re-typeset each flush | only what was appended |

   Measured 2026-09-25, M-series laptop: every row within budget except the frame-timing ones
   when the machine is busy (the control, drawing nothing, then misses frames too); run it on a
   quiet machine. Streaming in Side costs 3–8% of a core; the in-process number read 33% because
   the test's waiting loop counted as the view's, so streaming is measured in the app.
