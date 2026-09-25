# RFC: Alloy, the editing engine

*2026-09-24. Status: **accepted**: the owner accepted A1–A7 as recommended the same day; steps 0–7 built (Make runs on Alloy only). A launch gate (`SIDE_DISTRIBUTION.md`): Alloy ships in Side 0.1.*
*Companion to `SIDE_PRODUCT_CONSTITUTION.md` ("Alloy: powers Make"), `SIDE_DESIGN.md` (tokens,
motion, accessibility) and `SIDE_LAUNCH_PERFORMANCE.md` (how Side measures).*

## Why

Make is built directly on `NSTextView` with TextKit 1. It works, and it has taken real effort to
keep it fast (`SyntaxHighlighter` batches attribute changes because one-by-one updates cost 113 ms
on a 3,400-line file). But the ceiling shows:

- **Big files.** Highlighting stops at 2 MB (`maxHighlightableLength`); layout of a huge file is
  still AppKit's to decide, on the main thread.
- **Highlighting is regex over the whole file**, on a debounce. It's wrong wherever regex is
  wrong (nesting, multi-line constructs), and it redoes the whole file after every pause.
- **Agents write in Make.** Streaming edits, inline proposals, ghost text and live diffs are
  overlays on a view that was designed for one person typing. Every one is a fight with
  `NSTextStorage` attributes and layout invalidation.
- **What people expect from a modern editor** (multiple cursors, fast minimap, smooth 120 Hz
  scrolling, instant open of any file) is either absent or expensive on TextKit.
- **Peak native performance is a stated goal of Side**, and Heron showed the pattern: an engine
  separable from its stage, open source, with the stage as a thin client.

## What Alloy is

A Swift package of three layers, open source under Apache-2.0 like Heron (`gazishahi/alloy`):

| Layer | What it owns | Depends on |
|---|---|---|
| **AlloyCore** | The document: a rope of text, edits, undo/redo, selections (many), line and UTF-16 indexes, syntax trees, the layout *model* (what goes on which visual line) | Foundation, tree-sitter |
| **AlloyRender** | Drawing: CoreText shapes each line, glyphs go to a texture atlas, Metal draws the viewport (text, selections, carets, gutter, overlays) | AlloyCore, CoreText, Metal |
| **AlloyAppKit** | The view Make embeds: input (`NSTextInputClient`, so IME, dictation and marked text work), key bindings, mouse and drag, pasteboard, find (`NSTextFinder` client), accessibility, scrolling | AlloyCore, AlloyRender, AppKit |

The split is the Heron rule again: Core has no AppKit, so it's testable with `swift test` and
reusable (Review's diffs and Think's code blocks can use it later). Make keeps owning tabs, files,
LSP, Library and agents; Alloy owns text.

**CoreText shapes, Metal composites.** Alloy doesn't write a text shaper. CoreText already does
shaping, fallback fonts, emoji, ligatures and bidirectional text correctly; Alloy caches its
output per line and draws glyphs from an atlas. That is how the GPU editors that feel fastest on
macOS are built, and it keeps complex scripts correct from day one.

## Guardrails

- **No regressions in what Make already does.** Parity (below) is the bar for switching Make to
  Alloy, not a follow-up.
- **Accessibility is not optional.** A custom text view is invisible to VoiceOver unless it
  implements the text-navigation accessibility protocol itself. Alloy must read, navigate and edit
  under VoiceOver at least as well as today's `NSTextView`, checked the way `AccessibilityTests`
  checks the rest of Side.
- **Input is the system's.** IME (Chinese, Japanese, Korean), dictation, the character palette,
  Services and spell checking go through AppKit's protocols, never around them.
- **Measured, not claimed.** Every performance statement comes from signposts and a benchmark,
  as `SIDE_LAUNCH_PERFORMANCE.md` does.
- **Design tokens.** Colors, fonts and motion come from `DS`, including the text-size setting and
  Reduce Motion.

## Performance budgets (acceptance)

Measured on a 100,000-line Swift file and a 20 MB log, on this machine:

| Measure | Budget |
|---|---|
| Keystroke to pixels, p99 | ≤ 8 ms |
| Open to first paint | ≤ 50 ms (100k lines), ≤ 150 ms (20 MB) |
| Scrolling | no dropped frames at 120 Hz |
| Re-highlight after an edit | ≤ 2 ms (incremental) |
| Memory | ≤ 3× file size, plus the glyph atlas |
| Agent streaming edits | 60 edits/s applied and drawn without lag |

## Parity with today's Make (the switch-over bar)

Current-line band; line numbers; syntax colors for Side's languages; diagnostics underlines and
hover; completion popup anchoring; jump to definition; find and replace, including the find bar;
per-tab undo; unsaved-changes tracking; reveal a line; Markdown preview toggle; inline Instruct
(⌘K); streaming edit preview and proposed edits from agents; external-change reload;
tab tear-out; the text-size and editor-size settings; light and dark.

New in Alloy, after parity: multiple cursors, column selection, code folding, minimap, sticky
headers, inline agent ghost text.

## Decisions

- **A1: Rendering.** *Recommend:* Metal directly, with CoreText shaping and a glyph atlas.
  *Alternatives:* TextKit 2 on layers (faster than TextKit 1, but still AppKit's layout on the
  main thread; the ceiling moves, it doesn't go away), or an existing framework (none in Swift is
  mature enough to build on).
- **A2: Text storage.** *Recommend:* a rope (balanced tree of text chunks) that keeps line and
  UTF-16 counts in every node, so jumping to a line and converting to AppKit's UTF-16 ranges are
  both O(log n). *Alternative:* a piece table (simpler, but line lookups need a separate index).
- **A3: Syntax.** *Recommend:* tree-sitter, incremental, through the SwiftTreeSitter package, with
  grammars for Side's languages; LSP semantic tokens layered on top later. Retires
  `SyntaxHighlighter`'s regexes.
- **A4: Transition.** *Recommend:* first put an `EditorEngine` seam in Make that today's
  `NSTextView` editor implements, so every call Make makes into its editor is named. Alloy
  implements the same seam; Make switches when parity passes; the `NSTextView` path is deleted
  before 0.1 ships (no hidden fallback in a release).
- **A5: Scope for 0.1.** *Recommend:* parity plus multiple cursors. Folding, minimap and the rest
  follow in 0.2.
- **A6: Where it lives.** *Recommend:* developed in this repository as `Packages/Alloy`, split
  into `gazishahi/alloy` the same way as Heron once its API settles.
- **A7: Other surfaces.** *Recommend:* Make only for 0.1. Review's diffs and Think's code blocks
  move to Alloy's renderer afterwards; they're read-only, so they're the easy half.

## Plan

0. **The seam** (A4): `EditorEngine`, implemented by today's editor. No behavior change.
   **Built 2026-09-24:** `EditorEngine` (the view: selection, scrolling, geometry for popovers
   and the completion panel, typed insertion, focus, gutter marks), `EditorDocument` (a tab's
   text: replace-all, highlighting, diagnostic and bracket decorations) and
   `EditorEngineDelegate` (text and selection changes, auto-pairing, key commands, jump to
   definition, gutter clicks). `TextKitEditorEngine` and `TextStorageDocument` wrap today's
   `NSTextView`; `MakeWorkspaceViewController` touches nothing else (the Markdown preview, a
   separate read-only view, moved its link handling to `MarkdownPreviewLinks`).
   `EditorEngineTests` drive Make's real typing path through the seam (reveal a line, auto-pair,
   step over a closer, indent after `{`, unsaved state, decorations); Alloy must pass the same
   tests. Checked in the app: highlighting, gutter, change marks, current-line band, bracket tint,
   language server.
1. **AlloyCore:** rope, edits, undo grouping, selections, indexes; unit tests and benchmarks.
   **Built 2026-09-24:** `Packages/Alloy` (Apache-2.0, laid out for `gazishahi/alloy`).
   `Rope`: a persistent B-tree of text chunks (leaves ≤ 1 KB UTF-8, 16 children), each node
   caching UTF-8, UTF-16 and newline counts; edits never split a surrogate pair or "\r\n".
   `TextBuffer`: multiple selections (sorted, merged), batch edits, typing and deleting grouped
   into one undo step until a pause (1 s), a newline or a caret move; undo and redo restore
   selections; every change reports its applied edits in order, and replaying them (undo and
   redo included) reproduces the text exactly. 15 tests, including 4,000 random edits checked
   against a plain UTF-16 model. `swift run -c release AlloyBenchmarks`, this machine:
   build 33 ms (100k lines, 7 MB) and 35 ms (20 MB); a character edit anywhere ~15 µs; line
   lookups 1–3 µs; a 60-line screenful 3 µs; an undo snapshot plus edit 11 µs at 20 MB; typing
   with 1,000 cursors 14 ms (to batch before it matters).
2. **AlloyRender:** Metal view, line shaping cache, glyph atlas, viewport, carets and selections,
   120 Hz scrolling.
   **Built 2026-09-24:** `AlloyRender`: `DocumentLayout` (CoreText lays out a line when it's
   drawn, wrapping at the view width with `CTTypesetter`; layouts are cached by line text; a
   Fenwick `RowIndex` maps y to line in O(log n), unmeasured lines counting one row), `GlyphAtlas`
   (one BGRA texture; coverage for text, full color for emoji; quarter-pixel positions; starts
   over when full) and `TextRenderer` (current-line band, selections, glyphs and carets as
   instanced quads in one draw; shaders compiled at startup; a ring of instance buffers).
   `AlloyAppKit.AlloyEditorView`: AppKit's `NSScrollView` for scrolling, with the Metal layer
   floating over the visible area and drawn on the display link. `AlloyPlayground` opens a file
   in a window (`--dark`, `--screenshot`, `--scroll-test`). 21 package tests, including an
   off-screen render whose pixels are checked against the layout (selection, caret, ink, background).
   **Measured** (`--scroll-test`: a 99,275-line file flicked at 3,000 pt/s for 5 s, 120 Hz):
   frame CPU median 0.85 ms, p99 2.1 ms (budget 8.3 ms). 3–9 of ~600 frames missed a vsync; every
   miss was the main thread waiting in `nextDrawable` (up to 17 ms), and a control run drawing
   nothing (`ALLOY_CLEAR_ONLY=1`) missed as many, on a machine at load average 7.5: the
   compositor, not Alloy's drawing. "No dropped frames" is to be re-measured on an idle machine;
   drawing off the main thread, so a late drawable can't hold up input, is a candidate for step 3.
3. **AlloyAppKit input:** `NSTextInputClient`, key bindings, mouse, drag, pasteboard, find.
   **Built 2026-09-24:** `AlloyTextView` is the document view and first responder.
   `NSTextInputClient`: marked text is composed in place, underlined, and commits as one undo
   step (`EditKind.composing`); the candidate window is placed from `firstRect`. Key bindings
   through `interpretKeyEvents`: character, word, visual-row, paragraph and document movement
   with their selecting variants, a goal column for up and down, page up and down, word and line
   deletes. Multiple cursors: ⌥-click, ⌥⌘↑/↓, Escape back to one. Mouse: click, drag with
   autoscroll, ⇧-click, double-click word, triple-click line. Copy, cut, paste (one line per
   cursor when the counts match), undo and redo with menu validation. `NSTextFinderClient` for
   the Find bar. Blinking caret; I-beam. `AlloyEditorDelegate` carries Make's hooks
   (shouldChangeText, doCommand, text and selection changed). The renderer gained decorations
   (underline, dotted underline, background). Found and fixed: content insets (the Find bar)
   shifted the drawing below the document, so the find indicator missed its match; the viewport
   is now the clip bounds less its insets. 31 package tests (10 for input, through the calls
   AppKit makes, with synthesized mouse events and a private pasteboard); checked in the
   playground with real keystrokes. Not yet exercised with a real input method or dictation
   (the protocol path is tested; a live IME pass belongs to step 6).
4. **Syntax:** tree-sitter highlighting (A3).
   **Built 2026-09-24:** `AlloySyntax`: SwiftTreeSitter and tree-sitter 0.25 with grammars for
   the thirteen languages Side's regex highlighter covered (JavaScript, Python and Lua pinned to
   releases whose manifests include their scanners; Swift's pinned to its generated-files tag).
   Highlight queries are vendored (`Queries/`, TypeScript on JavaScript and C++ on C) with the
   grammars' MIT notices (`THIRD_PARTY_NOTICES.md`). Input is the rope as UTF-16, the unit Alloy
   already uses. Captures paint as tree-sitter's own highlighter does (inner over outer, later
   pattern over earlier); colors are cached per line, shifted with edits and invalidated from the
   tree's changed ranges. **Found and fixed on the way:** Swift's grammar reuses little on an edit
   deep in a long body (a keystroke cost 110 ms at 20,000 lines), so the tree now follows each edit
   at once (tree-sitter's `edit`, keeping colors on their text) and reparses on a background queue
   unless the file is under ~1,000 lines and parses in under 4 ms; and a query limited to a line
   still stepped over every sibling before it (84 ms a line in a 40,000-member body), so each line
   is queried from the node that holds it, climbing a few levels for context, with container-rooted
   patterns (3 of all the queries' patterns) rewritten to run from the container's children.
   Measured on a 40,000-line Swift file: a keystroke costs 0.1 ms on the main thread (budget 8 ms),
   re-coloring its line 0.02 ms (budget 2 ms), the background reparse ~280 ms. 38 package tests,
   including incremental-versus-fresh-parse equality across random edits and a line-by-line match
   between the fast query path and a root query on real files. Known gap: in a Lua table with more
   than 512 entries, the braces lose their constructor color.
5. **Make parity** on the seam, feature by feature, each with a test.
   **Built 2026-09-24:** Alloy is a local package of the app. `AlloyEditorEngine` and
   `AlloyEditorDocument` (Side) implement the seam on `AlloyEditorView`: a tab's `TextBuffer` and
   tree-sitter highlighter; Make's diagnostic and bracket marks become decorations; Alloy's own
   undo announces itself as `NSUndoManagerDidUndoChange` on the tab's manager, so "back to saved
   clears the dot" works unchanged; Jump to Definition joins the context menu. New in Alloy for
   parity: `AlloyGutterView` (numbers, change bars, removal notches, diagnostic dots, clicks), a
   context-menu hook, `isEditable`, font changes, and the drawing moved beneath the clip view so
   views Make adds to the text (proposal cards) sit on top. The seam gained `containerView` (Alloy's
   editor is a view that holds its scroll view). `SideEditorEngine` / `SIDE_EDITOR_ENGINE=alloy`
   selects Alloy; TextKit stays the default until step 7. Parity is tested on both engines through
   Make's own entry points (`EditorEngineTests`, `EditorParityTests` and their Alloy subclasses):
   typing through the seam, reveal, syntax colors, diagnostics underline and gutter dot, gutter
   clicks, ⌘K and completion anchors, Jump to Definition, per-tab undo and the unsaved dot, an
   approved agent edit (text replaced, undo cleared), the text-size setting, read-only tabs.
   Checked in Side on Alloy with real keys. Left for step 7: Make still runs its regex highlighter
   after typing (discarded on Alloy).
6. **Accessibility and polish:** VoiceOver, text sizes, tokens, Reduce Motion.
   **Built 2026-09-24:** `AlloyTextView` is an accessibility text area
   (`AlloyTextView+Accessibility.swift`): its value, character count, selection (read and set,
   including several ranges), selected text (setting it types), insertion-point line, visible
   range, line for index and range for line (logical lines, with their newline, as NSTextView
   reports them), string and attributed string for a range, bounds for a range, the character
   under a point, and composed-character ranges. It posts value-changed and selected-text-changed,
   so VoiceOver follows edits and the caret. Assistive edits go through the buffer and undo, and a
   read-only editor refuses them. The attributed string carries its font in the AX form, since an
   NSFont doesn't cross to another process. Checked live from outside Side through the AX API:
   every query above answers and both notifications arrive when a key is typed. The same checks run
   on both engines in `EditorParityTests.testVoiceOverReadsTheText`, and Alloy matches NSTextView
   where they could differ (no insertion-point line while a range is selected). The caret blinks
   by the `NSTextInsertionPointBlinkPeriodOn`/`Off` defaults NSTextView reads, so a caret set not
   to blink doesn't. Alloy has no other motion; colors, fonts and the text-size setting come from
   `DS` through `AlloyEditorEngine`, and the gutter uses the same `DS.Text.code(11)` as TextKit's.
   Input methods: the marked-text protocol is tested (step 3); this Mac has only U.S. and
   press-and-hold enabled, so a live CJK pass and dictation are left as manual checks before release.
7. **Switch:** Make on Alloy; remove the `NSTextView` path; measure against the budgets.
   **Built 2026-09-24:** Alloy is Make's only editor. Removed: `TextKitEditorEngine`,
   `TextStorageDocument`, `EditorTextView`, the TextKit gutter (`LineNumberRulerView.swift`), Side's
   regex highlighter (`SyntaxHighlighter.swift`) and the run of it after every edit, and the
   engine switch (`SideEditorEngine`, `SIDE_EDITOR_ENGINE`). The `EditorEngine` seam stays, with
   `AlloyEditorEngine` its one implementation, so Make's code stays free of Alloy's types.
   Measured in Make itself by `AlloyBudgetTests` (opt-in, optimized; the command is in the file),
   on this machine:

   | Measure | Budget | Measured |
   |---|---|---|
   | Keystroke to frame, main thread, p99 | ≤ 8 ms | 3.2–3.8 ms (key 1.1, frame 2.4) |
   | Open to first paint, 100k-line Swift | ≤ 50 ms | 19–24 ms; 48 ms as the session's first open |
   | Open to first paint, 20 MB log | ≤ 150 ms | 64–86 ms |
   | Scrolling at 120 Hz | none dropped | 2–6 of ~605 missed; the draw-nothing control, same session, 2–24 |
   | Re-color the edited line, p99 | ≤ 2 ms | 0.21 ms |
   | Memory, 20 MB log | ≤ 3× plus the atlas | 1.2–1.6× |
   | Agent edits (approved, whole-file), p99 | 60/s (16.7 ms) | 1.6 ms (2,000 lines), 12.8 ms (100k lines) |

   What getting there took. `EditorDocument.text`: an `NSString` over the rope (`RopeString`) for
   Make's reads around the caret (bracket match, auto-close, indent, completion), which had joined
   the whole rope into a `String` on every key. `TextBuffer.replaceAll(with:)`: an approved edit or
   a reload is applied as one edit over the bytes that differ, so layout, colors and selections
   update incrementally instead of starting over (and the file no longer shows uncolored while it
   reparses). `TextFileCodec` counts line endings in one byte pass (it had split the file into
   lines: 110 ms on 100k lines, 470 ms on 20 MB). The saved-state stamp is a hash of the UTF-8
   bytes (`ContentStamp`), computed off the main thread. A language's grammar and queries are
   built off the main thread the first time; the text paints first and its colors follow. From
   idle, the editor draws at the end of the run-loop turn instead of waiting for a display link
   that an idle ProMotion display has slowed (30–100 ms on a first open). The gutter's numbers are
   shaped once (`CTLine`) instead of measured and drawn as strings every frame (~1.5 ms a frame
   while scrolling). Make opens files up to 50 MB (was 10).
   The scroll misses are the system's: the control that draws only the background misses as many
   or more in the same run, and frame CPU is p99 3.4 ms of the 8.3 ms frame. The first open of a
   session includes one-time setup (Make's panels, the first drawables).
8. **Publish:** `gazishahi/alloy`, Apache-2.0.

## Risks, plainly

- **It's the largest piece of work left before launch**, larger than anything built so far in
  Side. The layering keeps it tractable: CoreText does the hardest part of text (shaping), and
  AppKit's protocols do input and accessibility.
- **Input and accessibility are where custom editors usually fall short.** They're in the plan
  as their own steps with tests, not as polish at the end.
- **Big files expose everything.** The budgets use a 20 MB file on purpose.
