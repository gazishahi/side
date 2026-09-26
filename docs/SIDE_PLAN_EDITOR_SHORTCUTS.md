# Editor and shortcuts

*2026-09-25. Status: **built**. A working list, not an RFC: the owner asked to go straight to building it, with a
page to keep track of the work.*
Symbols: `Shortcuts`, `ShortcutsViewController`, `ShortcutRecorder`, `EditorPreferences`.

## Shortcuts (Side)

1. **One table of every shortcut.** Each command has an id, a title, an area (Window, Make,
   Find, Think, Review, Run, Tracks, Palette) and a default key. Menus and the palette take their
   keys from the table, never a literal.
2. **Settings → Shortcuts.** Every shortcut, by area, searchable. Click one and press the new
   keys to rebind it; a key another command uses is named and the change waits for a
   confirmation. Reset one, or all.
3. **Tests**: the table has no duplicate defaults, every menu item with a key is in it, and a
   rebinding reaches the menu.

## In Make (Alloy, then Side)

Alloy 0.1 has multiple cursors; the rest was left for after 0.1 (SIDE_RFC_ALLOY.md, A5).

4. **Column selection** (Alloy): ⌥-drag selects a rectangle, one cursor per line; ⌥⇧ with the
   arrows grows it. Built on the multiple selections Alloy has.
5. **Code folding** (Alloy): foldable ranges from the syntax tree (and indentation where there's
   no grammar), a disclosure in the gutter, folded lines hidden in layout, ⌥⌘← / ⌥⌘→ to fold and
   unfold, ⌥⌘0 / ⌥⌘J for all. Find and Go to Line open what they land in.
6. **Minimap** (Alloy): the document drawn small beside the text, the visible part marked, click
   or drag to scroll; find matches and changed lines shown in it. Off by default, a View menu
   toggle, remembered.
7. **Budgets**: folding a 100k-line file, and the minimap's cost per frame, in `Budgets.table`.

## Progress

- [x] 1 One table (`Shortcuts.swift`: 67 commands, 17 of them fixed in their view; the menu binds every item, the palette and the switcher read their labels from it)
- [x] 2 Settings pane (Settings → Shortcuts: by area, searchable, a recorder that takes ⌘-keys before the menu bar, conflicts confirmed, Reset per command and all)
- [x] 3 Tests (`ShortcutsTests`)
- [x] 4 Column selection (Alloy: ⌥-drag; ⌥-click and ⌥⌘↑/↓ as before)
- [x] 5 Folding (Alloy: `Folding`, hidden lines in `DocumentLayout`, gutter arrows, a band on the folded line; Side: View → Code Folding, ⌥⌘← → and ⌥⇧⌘← →; off in Review's diff)
- [x] 6 Minimap (Alloy: `AlloyMinimapView`; Side: View → Show Minimap, ⌃⌘M, off by default)
- [x] 7 Budgets (regions 29 ms, Fold All 8 ms, minimap 2.5 ms a frame at p99)
