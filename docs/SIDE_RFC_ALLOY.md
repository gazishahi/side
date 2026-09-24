# RFC: Alloy, the editing engine

*2026-09-24. Status: **decisions pending**: A1–A7 below. A launch gate (`SIDE_DISTRIBUTION.md`): Alloy ships in Side 0.1.*
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
1. **AlloyCore:** rope, edits, undo grouping, selections, indexes; unit tests and benchmarks.
2. **AlloyRender:** Metal view, line shaping cache, glyph atlas, viewport, carets and selections,
   120 Hz scrolling.
3. **AlloyAppKit input:** `NSTextInputClient`, key bindings, mouse, drag, pasteboard, find.
4. **Syntax:** tree-sitter highlighting (A3).
5. **Make parity** on the seam, feature by feature, each with a test.
6. **Accessibility and polish:** VoiceOver, text sizes, tokens, Reduce Motion.
7. **Switch:** Make on Alloy; remove the `NSTextView` path; measure against the budgets.
8. **Publish:** `gazishahi/alloy`, Apache-2.0.

## Risks, plainly

- **It's the largest piece of work left before launch**, larger than anything built so far in
  Side. The layering keeps it tractable: CoreText does the hardest part of text (shaping), and
  AppKit's protocols do input and accessibility.
- **Input and accessibility are where custom editors usually fall short.** They're in the plan
  as their own steps with tests, not as polish at the end.
- **Big files expose everything.** The budgets use a 20 MB file on purpose.
