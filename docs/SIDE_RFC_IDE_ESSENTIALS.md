# RFC: IDE essentials — language features, languages, keymaps and themes

*2026-09-26. Status: **accepted**: the owner agreed to the direction on 2026-09-26 ("Let's do it").
Defaults chosen where the owner didn't pick are marked (default); say so and they change.
Build order below.*
*Companion to `SIDE_RFC_ALLOY.md` (the editor), `SIDE_PLAN_EDITOR_SHORTCUTS.md` (the shortcuts table
this extends) and `SIDE_LAUNCH_PERFORMANCE.md` (how Side measures). Later RFCs, not this one: a
debugger (DAP), a tests panel, git depth, profiling, remote development with the mobile rollout,
a vim mode.*

## Why

Make edits text well, but it knows little about code. What's there today:

- **The LSP client** does `initialize`, `completion`, `definition`, `didOpen`/`didChange`/`didClose`,
  and reads `publishDiagnostics`. It advertises no capabilities (`InitializeParams.capabilities`
  is `[:]`), answers no server requests (`workspace/configuration` goes unanswered), and sends the
  **whole document** on every change.
- **Autocomplete is slow** because each keystroke:
  - sends the full text twice (the debounced `didChange`, then again before the request);
  - walks the document line by line on the main thread to find the position;
  - waits 150 ms, then a round trip, with no local filtering between replies;
  - leaves superseded requests running (no `$/cancelRequest`), queued ahead of the next sync;
  - decodes every reply twice.

  Accepting an item inserts `insertText ?? label` over the word, so it ignores `textEdit`,
  auto-imports (`additionalTextEdits`), snippets and documentation.
- **Missing features:** hover, signature help, references, rename, quick fixes, a problems list,
  an outline and formatting. Go to Symbol is regular expressions for three languages.
- **Language breadth:**
  - There are 13 grammars (Swift, TypeScript/TSX, JavaScript, Python, Rust, Go, Lua, Ruby, C, C++,
    JSON, Markdown) and 8 servers, in a private dictionary.
  - No SQL, YAML, TOML, HTML, CSS, shell, Java, Kotlin, C# or PHP. Ruby has a grammar but no server.
  - There's nowhere to add a server.
- **Keys and colors:**
  - The text view knows only Cocoa's standard bindings and ⌥⌘↑/↓.
  - There's no ⌘/ (comment), move line, duplicate line or select next occurrence, and no keymap
    to choose.
  - There's one hard-coded syntax palette.

## Budgets

These are rows of `Budgets.table`, measured in an optimized build (step 9).

| Measure | Budget |
|---|---|
| A keystroke's sync cost on the main thread, 100,000-line file | ≤ 1 ms (the edit only, never the text) |
| Completion list after a keystroke once the word's reply is in (filtered locally) | ≤ 8 ms, no round trip |
| Completion list, first reply for a word | server time + ≤ 5 ms of Side's own work |
| Hover, signature help, after the reply | ≤ 5 ms to show |
| Problems list, 5,000 diagnostics | opens ≤ 50 ms |
| Grammars added in step 6 | ≤ 12 MB on the app's size; memory only for languages with a file open |
| Idle, files open, servers running | unchanged from today's budget |

## Decisions

### L1: the LSP client grows up

- **Capabilities are advertised** for what Side implements, so servers send what Side reads.
  This includes snippets, completion `resolve`, markdown documentation, `positionEncoding: utf-16`
  (Alloy's own unit, so offsets need no conversion) and `workDoneProgress`.
- **Incremental sync.** Alloy's change events already carry their range, so each `didChange` is
  just that edit. Side converts offsets to line and column through the rope (O(log n)), never by
  walking the text. It still sends full text to a server that asks for full sync.
- **Server requests are answered.** These include `workspace/configuration` (from each language's
  settings, below), `client/registerCapability`, `window/workDoneProgress/create`,
  `window/showMessage` and `workspace/applyEdit`. A server's "indexing…" progress shows on the
  language chip.
- **Cancellation:** a superseded request sends `$/cancelRequest`. Replies are decoded once,
  straight into their types, off the main thread.
- **`didSave` is sent,** and file watching (`workspace/didChangeWatchedFiles`) is sent when the
  server asks for it.

### L2: completion, rebuilt

- **Ask once, filter locally.** A request goes out:
  - when a word starts (or at a server's trigger characters, like `.` or `::`);
  - on ⌃Space;
  - again only if the reply said `isIncomplete`.

  Each further keystroke filters and ranks the list Side already has (fuzzy match on
  `filterText`, a bonus for a prefix match and for the case matching, then `sortText`). Typing
  never waits on the server once the list is up.
- **Items are applied as the server means them:**
  - `textEdit`: insert-or-replace; ⇥ replaces the rest of the word (default);
  - `additionalTextEdits`: auto-imports;
  - snippets, whose tab stops become Alloy placeholders you ⇥ through, built on the multiple
    selections Alloy already has.

  All of it is one undo step.
- **The panel** shows kind icons and a documentation pane beside the list, filled by `resolve`
  for the selected item only.
- **Signature help:** a small card above the caret after `(` and `,`, with the current
  parameter in bold. It closes on `)`.
- **Without a server,** the list is the words in open buffers, so plain text and a missing
  server still complete.

### L3: understanding and changing code

- **Hover (Quick Help).** Resting the pointer on a symbol for 0.5 s shows its type and docs on a
  glass card (default). ⌥-click shows it at once (Xcode's key), and it's in the shortcuts table.
  Diagnostics under the pointer show on the same card.
- **Definition:** ⌘-click, as well as ⌃⌘J. More than one location opens a picker.
- **Surfaces reuse Side's palette** (the one search surface of F1):
  - **References** (⇧⌘R, default) are a list in the palette, like Find in Project.
  - **Problems** (⇧⌘M, default) are a palette mode: every diagnostic, grouped by file,
    filterable by severity. The status chip shows the counts.
  - **Go to Symbol** (⇧⌘O) and a new **Outline** come from `documentSymbol`, with tree-sitter
    (Alloy already parses) where there's no server. The regex `SymbolIndexer` goes.
- **Rename** (⌃⌘E, Xcode's key): edit the name in place. Every change across files is shown
  before it's applied, applied as one undo step per file, and listed in Review like an agent's
  change.
- **Quick fixes** (⌘., default): code actions at the caret, in a small menu under it. A
  lightbulb shows in the gutter where there are any.
- **Formatting:** Format Document and Format Selection (⌃⇧I, default). **Format on save** is off
  by default and can be turned on per language.
- **Agents get the same tools.** Heron's `read_diagnostics` already exists. References, hover
  and document symbols become tools too, so an agent can ask the server rather than grep. How
  that fits the Heron efficiency RFC is decided there.

### L4: languages

- **Settings → Languages** lists each language with four things:
  - its grammar (built in, or none);
  - its server, as a preset or a command you edit;
  - whether that server was found, with Install when it wasn't (Homebrew or npm);
  - its settings for `workspace/configuration` (JSON) and format on save.

  **Add Language** maps file extensions to a command, arguments and a language id, for anything
  Side doesn't know. It's stored in Side's settings (default). A per-project file is left for
  later.
- **Server presets added:**

  | Language | Server | Install |
  |---|---|---|
  | SQL | `sqls` | brew |
  | YAML | `yaml-language-server` | brew |
  | TOML | `taplo` | brew |
  | HTML, CSS, SCSS, JSON | `vscode-html/css/json-language-server` | npm `vscode-langservers-extracted` |
  | Bash | `bash-language-server` | brew |
  | Ruby | `ruby-lsp` | gem |
  | Java | `jdtls` | brew |
  | Kotlin | `kotlin-language-server` | brew |
  | C# | `csharp-ls` | dotnet tool |
  | PHP | `intelephense` | npm |
  | Dockerfile | `docker-langserver` | npm |
  | Markdown | `marksman` | brew |

  A language with more than one good server (Python: pyright or basedpyright; TypeScript: the
  TypeScript server or vtsls) gets a choice.
- **Grammars added to Alloy:** SQL, YAML, TOML, HTML, CSS, SCSS, Bash, Java, Kotlin, C#, PHP,
  Dockerfile and Makefile. Each comes with highlight queries mapped to Side's captures, and
  folding and outline come from the tree. Every grammar is compiled in and parsed only when a
  file needs it. The 12 MB size budget is checked per grammar; one that's too large waits for
  grammar packs.
- **Grammar packs loaded at run time** (downloaded, signed, sandboxed) are a later RFC. They stay
  out of this one because of what they need for signing and notarization.

### L5: keymaps

- **Editing commands become named actions in Alloy.** They include: toggle comment, move line
  up and down, duplicate line, delete line, select next occurrence, select all occurrences, join
  lines, indent and outdent, expand and shrink selection (by the syntax tree), and go to matching
  bracket. They can be called from code or from a key.
- **A keymap maps chords to those actions and to Side's menu commands.** The presets are:
  - **Xcode** (default, as today);
  - **VS Code** (⌘D next occurrence, ⌥↑/↓ move line, ⌘/ comment, ⌘P Quick Open, and so on);
  - **JetBrains** (the macOS keymap).

  Settings → Shortcuts gets the preset picker. Your own changes stay on top of whichever preset
  you pick, and editor actions join the table so they can be rebound too.
- **Vim mode** is not in this RFC. It's noted (the owner uses Neovim) and gets its own RFC after
  this one. Named actions and a keymap layer are what it will build on.

### L6: themes

- **A theme is the whole editor:**
  - background, text, selection, caret, current line, gutter, fold pill, minimap and diagnostics;
  - the syntax captures (today's `SyntaxTheme`).

  Built in: Side light and dark (today's), plus a few well-known open-licensed themes (default:
  GitHub light and dark, One Dark).
- **Import a VS Code theme** (its `.json`): its `colors` map to the editor's colors, and its
  TextMate `tokenColors` scopes map to tree-sitter captures through one table. Scopes the table
  doesn't know fall back to their parents. Settings → Appearance picks a theme for light and one
  for dark.
- Side's own chrome stays Side's (glass, DS tokens). Themes color the editor, the diff and the
  terminal.

## Plan

1. **LSP foundation and completion** (L1, L2 without snippets), the slowest thing first:
   - capabilities;
   - incremental sync through the rope;
   - server requests answered;
   - cancellation;
   - decode once;
   - completion requested per word and filtered locally, with `textEdit`, `additionalTextEdits`
     and `resolve` applied;
   - buffer words when there's no server.

   Measured before and after on Khidma (TypeScript) and SIDE (Swift).
2. **Snippets, signature help, hover and ⌘-click** (L2 rest, L3). Alloy: placeholders.
3. **Problems, references, rename and quick fixes** (L3).
4. **Outline, Go to Symbol from the server and tree, formatting and format on save** (L3).
5. **Settings → Languages:** the registry becomes data, with presets, custom entries, install
   hints and per-language settings (L4).
6. **More grammars** (L4). Alloy: new grammars and queries. Published as Alloy's next minor
   release.
7. **Keymaps:** named editing actions in Alloy, and the Xcode, VS Code and JetBrains presets in
   Side (L5).
8. **Themes:** the full theme type, built-ins and VS Code import (L6).
9. **Budgets and tests:** the table above in `Budgets.table`, and tests per step. Each step ends
   with its tests and is checked in Side on a real project.

Alloy's public API changes in steps 2, 6, 7 and 8. Each gets a release, published only after the
owner says yes.

## Progress

- [ ] 1 LSP foundation and completion
- [ ] 2 Snippets, signature help, hover, ⌘-click
- [ ] 3 Problems, references, rename, quick fixes
- [ ] 4 Outline, symbols, formatting
- [ ] 5 Settings → Languages
- [ ] 6 More grammars
- [ ] 7 Keymaps
- [ ] 8 Themes
- [ ] 9 Budgets
