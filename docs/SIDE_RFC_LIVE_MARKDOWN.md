# RFC: Live Markdown in Alloy

*2026-10-23. Status: **in progress**: the direction and the five questions below are decided
(the owner, 2026-10-23). Steps 1 (font runs, View → Live Markdown) and 2 (rows of their own height) are built; step 3
is next.
Writer Mode's first step (Make alone, the aids) is built: `027f170`.*

## What the owner decided (2026-10-23)

- **Live preview**, as Obsidian and Typora do it: the file stays plain Markdown; text is styled as
  it's typed; the marks (`#`, `**`, `_`, a link's URL) hide except where the caret is; Word-style
  shortcuts add them.
- **In Alloy**, not a second editor: one editing engine for code and prose.
- **On any Markdown file**: a Source / Live switch in Make; Writer Mode opens in Live.
- **Writer Mode's aids are toggles** (word count, typewriter scrolling, dimming; full screen off by
  default). Built.

## What Alloy assumes today

From a map of the engine (AlloyRender, AlloyAppKit), 2026-10-23:

- **Horizontal: already proportional.** Each line is shaped by CoreText (`LaidOutLine`), caret x
  and hit-testing come from `CTLine`, and nothing divides by a character width. One font per
  document (`DocumentLayout.font`), but nothing requires it to be monospaced.
- **Vertical: one grid.** One `lineHeight`; `RowIndex` counts rows per line (wrapped lines are
  several, folded ones none), and `y(ofLine:)` is rows times `lineHeight`. That product appears
  in the renderer, the gutter, vertical caret moves, paging and column selection.
- **Styles are color only.** A `StyleSpan` tints glyphs after layout; it can't change a font or a
  size. Decorations are bands and underlines.
- **The glyph atlas is already multi-font and multi-size**, keyed by PostScript name and size.
- **Nothing hides inside a line** (folding hides whole lines), and nothing but glyphs and solid
  quads is drawn: no images.
- **The line layout cache is keyed by the line's text**, so two equal lines share a layout. That
  stops being true once layout depends on styles or on where the caret is.

## The design: five layers, each shippable

Each step lands behind the Live switch, keeps every existing Alloy test passing, and adds a
budget to `SIDETests/Budgets.swift` (frame time on a long Markdown file).

1. **Font runs.** *Built:* `Emphasis` on `StyleSpan` (from `SyntaxTheme.proseEmphasis`, with
   Markdown's inline grammar embedded in each paragraph), `FontSpan` runs laid out before
   measuring (`DocumentLayout.fontSpans`), and View → Live Markdown in Side. A layout style per span (font role: body, heading 1 to 6, code; bold, italic;
   size) applied to the attributed string *before* typesetting. A `TextStyler` per document
   supplies them; the Markdown one reads the tree-sitter tree Alloy already keeps. The layout
   cache key gains a style hash. Body text in Live uses the reading font (see question 2).
2. **Lines of their own height.** *Built:* `RowIndex` counts points, `LaidOutLine` gives each row
   its top, height and baseline (only a document with font runs varies: code is unchanged),
   headings carry their level (`Emphasis.heading`), the view keeps the top line in place as lines
   above it are measured, and the `editor.live.keystroke` budget holds Live to code's 8 ms.
   The plan was: `RowIndex` becomes a tree of heights in points, rows keep their
   own height and baseline, and every `* lineHeight` site goes through the layout. Unmeasured
   lines are estimated at the body line height; when a measured line above the viewport changes
   height, the first visible line stays where it is on screen (scroll anchoring).
3. **Concealment.** Ranges hidden inside a line: laid out from a display string with an offset map
   back to the source, so the caret, hit-testing and selection work in source offsets. The caret
   steps over hidden marks; copying copies the source. Which marks show depends on where the caret
   is (question 1), so the reveal state joins the cache key and only the lines that change reveal
   are laid out again.
4. **Inline replacements.** A range drawn as an image of the client's (a formula, an inline image):
   a `CTRunDelegate` placeholder sized to it, and a second texture beside the glyph atlas for the
   images. Alloy stays free of math and networking: Side supplies the images (SwiftMath for math).
5. **Block replacements.** Lines replaced by one drawn block: an image on its own line, a rule,
   the front matter card, a table (question 3). The lines are hidden as folding hides them, and an
   anchor line takes the block's height; the source comes back when the caret enters it.

Then in Side: the Source / Live switch (View menu, remembered per file), Writer Mode in Live, and
the formatting commands (question 4).

## What it costs

- Layout per line gets dearer (font runs, concealment), offset by caching on (text, styles,
  reveal). The budget decides whether a long file stays under a frame.
- Big heading sizes fill the atlas faster: it may need a second page.
- Accessibility and input methods report one font today (`attributedSubstring`,
  `accessibilityAttributedString`); they learn runs in step 1.
- Code files are untouched: no styler, no concealment, one height. The grid is the special case
  of the new layout, and the existing tests hold it to that.

## Decided questions

Each took the recommendation (the owner, 2026-10-23).

1. **What reveals the marks:** the caret's line (Obsidian). Not the span the caret is in
   (Typora: least noise, more surprise while moving), nor the whole paragraph.
2. **Live's font:** the reading font the preview uses, so Live looks like the preview; not the
   editor's monospaced font with only sizes and weights changing.
3. **Tables in v1:** source with columns aligned (editing a rendered grid is its own project,
   later); not a rendered grid that turns back to source when the caret enters.
4. **⌘B in Markdown:** Bold (and ⌘I italic, ⌘K link), with Build LaTeX keeping ⌘B in LaTeX files
   only. Shortcuts start depending on the file type, which Side doesn't do yet.
5. **Images:** local images inline, and remote ones as a placeholder until clicked (no
   network request just for opening a file).
