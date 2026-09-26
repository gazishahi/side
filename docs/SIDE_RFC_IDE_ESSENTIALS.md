# RFC: IDE essentials — language features, languages, keymaps and themes

*2026-09-26. Status: **accepted**: the owner agreed to the direction on 2026-09-26 ("Let's do it").
Defaults chosen where the owner didn't pick are marked (default); say so and they change.
Build order below. Step 1 built.*
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
  an outline, and formatting through the server. Go to Symbol is regular expressions for three
  languages. Save already runs prettier or swift-format when the project has one; there's no
  Format Document command.
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
  glass card (default). Show Quick Help (⌃⌘I) shows it for the symbol at the caret. ⌥-click
  stays "add a caret", as Alloy already had it, instead of Xcode's Quick Help. Diagnostics under
  the pointer show on the same card.
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
- **Formatting:** Format Document (⌃⇧I, built 2026-09-26, ahead of step 4) and Format Selection, by the project's
  formatter (prettier, swift-format, as save uses today) or else the server. **Format on save**
  keeps today's behavior (on when the project has a formatter) and becomes a per-language
  setting in step 5.
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

## Built

**Step 1, 2026-09-26.**

- **The client:**
  - It advertises capabilities (`InitializeParams.clientCapabilities`) and reads the server's
    (`LSPServerCapabilities`: sync kind, trigger characters, resolve).
  - It answers server requests (`workspace/configuration` with one value per item,
    registrations, progress creation; unknown methods get "method not found").
  - Replies are parsed once, on the client's actor (`LSPResult`).
- **Sync:**
  - Documents follow their edits: `EditorDocument.onEdits` reports every applied edit (typed,
    undone, or an agent's replacement).
  - `LSPManager` keeps each open document as a rope that shares the editor's storage, and
    sends the edits since the last `didChange` as ranges (`LSPManager.contentChanges`, O(log n)
    per edit).
  - Edits go out 0.2 s after typing stops, or at once before a request. A server that asked for
    full sync gets the text, and `didSave` is sent.
- **Completion:**
  - Requests carry a token (`LSPRequestToken`). One that's superseded is dropped from the queue
    if unsent, or cancelled with `$/cancelRequest` if sent.
  - A request goes out when a word starts, at a trigger character, on ⌃Space (Edit → Show
    Completions, rebindable), or again only for an incomplete list.
  - `CompletionSession` filters and ranks the reply locally on each keystroke. The ranking:
    - fuzzy matching, preferring prefixes, word starts and the typed case;
    - then `sortText`.
  - Items are applied through `CompletionEdits` as one undo step. That covers `textEdit`,
    insert-or-replace (Return inserts, Tab replaces), `itemDefaults`, and `additionalTextEdits`
    (auto-imports, waiting up to 0.3 s for the selected item's `resolve`). Snippets go in as
    their text until step 2.
- **The popup** (`CompletionPopup`) shows a kind badge, the module or type, and the selected
  item's documentation from `resolve`.
- **Without a server,** the open files' words complete (not in Markdown or plain text).

Checked in Side on Khidma with typescript-language-server:

- One request per word, then local filtering.
- `document.getEl` completes to `getElementById`, with its docs.
- `useCallb` completes to `useCallback` and adds it to the existing `react` import; one undo
  takes both back.

| Measure | Before | After |
|---|---|---|
| Sent per keystroke | the whole file, twice (100k lines: ~4 MB of JSON) | the edit (~100 bytes), batched |
| Keystroke to an updated list, once the word's reply is in | 150 ms wait plus a server round trip, every key | 0.32 ms p99 re-ranking 6,000 items (optimized), no round trip |
| The edit's sync cost, 100k-line file, p99 | a line-by-line walk plus a copy of the text | 0.03 ms |
| First reply for a word (tsserver, Khidma) | 150 ms + server | the server's alone: 35–460 ms here (up to ~1 s the first time) |

Tests:

- `LSPIncrementalSyncTests`: a randomized edit history replays exactly.
- `LSPClientProcessTests`: a Python server over stdio keeps its copy from Side's edits, is
  answered `workspace/configuration`, and resolves an item it sent.
- `CompletionRankingTests`, `CompletionReplyTests`, `CompletionApplyTests`.
- `LSPOutboundQueueTests`: a cancelled request is never sent.
- Budgets `completion.filter` and `completion.sync`.

**Step 2, 2026-09-26.**

- **Alloy (0.3.0, not yet published):**
  - `Snippet` parses LSP/VS Code snippet syntax: stops, defaults, choices, mirrors, variables
    and escapes.
  - `AlloyEditorView.insert(_:replacing:alsoApplying:)` inserts one as a single undo step and
    selects its first stop. Tab and ⇧Tab move between stops, and mirrors are typed once.
  - `SnippetStops` follows the edits typed after insertion. Escape, undo, or moving the caret
    away ends the snippet; so does reaching `$0`. The stops still ahead are faintly boxed.
  - Pointer hooks: `onPointerMove` gives the character under the pointer and the keys held,
    `onPointerExit` fires on leaving or scrolling, and `onCommandClick` handles ⌘-click.
  - `characterOffset(at:)` gives the character under a point.
- **Side, completion:** snippets are advertised and inserted with their stops (a Swift `min`
  becomes `min(x, y)`, and Tab moves between the two).
  - An item's range on the request line is anchored to the caret (Return) or the end of the
    word (Tab). sourcekit-lsp answers against text newer than the request, and its ranges
    could run past the end of the document.
- **Signature help** (`LSPSignatureHelp`, `InfoCard`) appears above the caret on a server's
  trigger characters. It re-asks on each edit while it's up, with the current parameter in bold
  and its documentation below. It goes away when the call closes, on Escape, or when the caret
  moves off. Auto-pairing's caret move no longer dismisses it.
- **Hover** (`LSPHover`, `MarkdownLite`):
  - Resting 0.5 s on a symbol shows its type and docs, with any problems there listed first.
    Code is shown in the editor's font.
  - The card stays inside the window where it fits.
  - Show Quick Help (⌃⌘I) does the same at the caret.
- **⌘-click:** holding ⌘ underlines the symbol under the pointer, and a click goes to its
  definition.
  - Several definitions open a picker (file:line, with its folder).
  - The target line is centered (`EditorEngine.centerRange`, used by Go to Line too).
  - Paths through symlinks (pnpm's and deno's `node_modules`) now find their tab. Before, the
    file opened but the caret stayed at line 1.
- Checked in Side on Khidma (typescript-language-server) and a Swift file (sourcekit-lsp):
  - `setTimeout(` gives its signatures with `timeout` in bold after the `,`.
  - Hovering `useState` shows its type and docs.
  - ⌘-click on `useState` picks between its two overloads and lands on line 1883 of React's
    `index.d.ts`.
  - `min` completes as a snippet, and Tab moves through it.
- Tests:
  - Alloy: `SnippetTests`, `SnippetViewTests`.
  - Side: `SignatureAndHoverTests`, and `CompletionApplyTests` for a server that counted newer
    text.

**Step 3, 2026-09-26.**

- **Keys:** Find References ⌃⌘R, Rename ⌃⌘E and Show Problems ⇧⌘M, as chosen.
  - Quick Fix moved to ⌥⌘. because ⌘. is Stop and ⇧⌘R is Restart Terminal.
  - The shortcuts table has no duplicates.
- **Show Problems** (a palette mode) lists every problem the servers report across the project.
  - Errors come first, then by file and line, with the message, its source and `file:line`.
    Typing filters by message or path.
  - The top row counts errors and warnings (✕ 6); a click opens the list.
- **Find References** (palette mode) lists each use with its line's text, read from the open
  buffer or once per file from disk. Return goes there.
- **Rename:**
  - The server confirms first (`prepareRename`), then a field opens over the name, in the
    editor's font, with the name selected.
  - A change to one file is applied at once. One to several files lists them first, with a
    count each.
  - Open files change in their tabs as one undo step, left unsaved. Files that aren't open are
    rewritten, keeping their encoding.
  - Overlapping edits are refused, and file creates, renames and deletes are counted but not
    applied.
- **Quick Fix:** a menu under the caret with the server's fixes (its preferred one first, in
  bold) and then its refactorings.
  - Actions the server marks disabled are left out.
  - An action is resolved when it has no edit yet. A command runs on the server, and the edits
    it sends back (`workspace/applyEdit`) are applied and answered.
  - Clicking a problem's dot in the gutter lists its fixes under the messages. That dot does
    the lightbulb's job.
- Paths through symlinks (`/tmp` for `/private/tmp`) now show relative to the project.
- Checked in Side on Khidma (typescript-language-server):
  - Show Problems lists 6 errors and 1 note.
  - `useState` has 21 references.
  - Renaming `isSubmitting` to `isSending` works.
  - ⌥⌘. on an unused import offers "Remove import from '…'", and applying it drops the
    count to 5.
- Tests: `WorkspaceEditTests`, and in `EditorEngineTests` a rename across a shown tab, a tab
  behind it and a closed file (one undo per file), plus refusing overlapping edits.

**Step 4, 2026-09-26.**

- **Alloy (0.4.0, not yet published):** `SyntaxSymbolSource.symbols()` builds an outline from
  the syntax tree.
  - It covers all thirteen languages: declarations nested in what contains them, the locals
    inside functions left out.
  - Swift's struct, enum, extension and actor are read from the keyword.
  - It walks a copy of the tree, so it runs off the main thread. 20,000 functions take well
    under the test's two-second bound in a debug build.
- **Go to Symbol (⇧⌘O) is the file's outline:**
  - The symbols come from the server's `documentSymbol` (nested or flat), or from the syntax
    tree where there's no server or it returns none.
  - With nothing typed, it lists them in order and indented. Typing ranks the matches, each
    with what it's in.
  - Each row has a kind icon; Return selects the name and centers it.
  - The regex `SymbolIndexer` is gone.
- **Format Selection:** ⌃⇧I with a selection formats just those lines, through the server's
  `rangeFormatting` or prettier's `--range-start/--range-end`; otherwise the whole document.
  Format on save is unchanged until step 5's per-language setting.
- Checked in Side:
  - `EventRegistration.tsx` from typescript-language-server, where `hand` finds
    `handleSubmit`, `handleCancel` and the rest in `EventRegistration`.
  - `PRODUCT_ROADMAP.md`'s headings from the tree.
- Tests:
  - Alloy: `SyntaxSymbolsTests`, covering Swift, TypeScript, Python, Rust, Go, C, Ruby,
    Markdown, JSON and a 20,000-function file.
  - Side: `OutlineTests`.

**Step 5, 2026-09-26.**

- **The registry is data** (`LanguageSettings`): twenty languages, each with its extensions and
  the language id servers expect.
  - The eight languages from before plus SQL (sqls), YAML, TOML, HTML, CSS/SCSS/Less, JSON,
    shell, Ruby (Ruby LSP or Solargraph), Java, Kotlin, C#, PHP and Markdown.
  - Where there's a choice there are alternatives: vtsls for TypeScript, basedpyright for
    Python.
  - Each server says how it installs: Homebrew, npm, RubyGems or `dotnet tool`.
- **Your choices are kept in Side's settings.** For each language you can pick:
  - which preset server, a command of your own (a name on your PATH or a path), or None;
  - settings the server reads, as JSON: `workspace/configuration` is answered section by
    section, nested or dotted keys alike, and the answer is ready before `initialize`;
  - format on save: as the project has it (as before), on (the project's formatter, else the
    server's), or off.

  Languages you add yourself (name, extensions, language id, command) work the same way.
- **Changing any of it restarts the servers** as now chosen and re-announces every open file.
- **Settings → Languages:** each language with its extensions and command, Installed or an
  Install button (the popover runs the installer in your shell, then the server starts), a
  server menu, and ⋯ for command, settings and format on save. Plus your own languages, with
  Add Language….
- **Install prompts:** the "not installed" chip on a file shows only for the languages that had
  one before, or for one you chose. Opening a YAML file doesn't nag; its server is used once
  it's installed.
- Deferred to step 6, where grammars bring file-name matching: Dockerfile and Makefile (no
  extension to match on).
- Checked in Side: the pane with TypeScript, Swift and clangd found and the rest offering
  Install.
- Tests: `LanguageSettingsTests` covers presets, alternatives, your own command, None, a
  language of your own, configuration sections, and format on save.

**Step 6, 2026-09-26.**

- **Language servers, checked properly:**
  - Homebrew has no `sqls` formula; my preset named one that doesn't exist.
  - The npm `sql-language-server` installs but exits at once on current Node, so SQL uses sqls,
    installed with `go install` and found in `~/go/bin`.
  - Install first checks that its installer (Homebrew, npm, Go, RubyGems, .NET) is there, and
    says what to get if it isn't.
  - A server that exits as it starts shows "didn't start" on the chip and isn't respawned on
    every edit.
  - Two opt-in tests: `SIDE_NETWORK_TESTS=1` asks each registry that every install names a real
    package and installs the command Side runs; `SIDE_SERVER_TESTS=1` starts every installed
    preset and waits for its `initialize` reply. Both pass. SQL was checked in Side: installed
    from the pane, then running on a Khidma migration.
- **Alloy (0.5.0, not yet published):** eleven grammars, vendored as the Swift one is (the
  generated parser and scanner, the grammar's own MIT license, symbols renamed): YAML, TOML,
  HTML, CSS, SCSS, Bash, Java, PHP, Dockerfile, Make and SQL.
  - Their highlight queries are their own. SCSS's old `match?` spelling became `#match?`, and
    the theme gained `constant` and CSS's at-rule captures.
  - Files are matched by name as well as extension (`SyntaxLanguage.languageExtension`):
    Dockerfile, Dockerfile.*, Containerfile, Makefile, GNUmakefile, and shell dotfiles.
  - The outline covers them: YAML keys, TOML tables, CSS rules, shell functions, Java and PHP
    declarations, Dockerfile stages, Make targets, SQL tables, views and functions.
- **Size:** the eleven compile to about 6 MB of objects, inside the 12 MB budget. Kotlin
  (4.1 MB) and C# (5.4 MB) alone would take the total to about 15.5 MB, so they wait. The owner
  wants both eventually (2026-09-26), with grammar packs or a larger budget. Their servers work
  already; only their colors wait.
- **Side:** every language lookup goes by `URL.languageExtension`, so a `Dockerfile` is colored
  and gets its server (docker-langserver, npm).
- Checked in Side: `netlify.toml`, `pnpm-workspace.yaml`, a SQL migration and a Dockerfile are
  colored.
- Tests:
  - Alloy: every language loads, its query compiles, and a sample is colored (24 languages).
  - Alloy: files known by name, and the new languages' outlines.

**Step 7, 2026-09-26.**

- **Alloy (0.6.0, not yet published):** the editing commands as named actions on
  `AlloyTextView`, each on every selection and one undo step:
  - toggle line comment (at the lines' shared indent, blank lines left alone; the owner sets
    `lineComment`);
  - move lines up and down, duplicate lines (the caret goes onto the copy), delete lines,
    join lines;
  - indent and outdent (`indentUnit`);
  - select next occurrence (a caret takes its word first) and select all occurrences;
  - expand and shrink selection, through `onExpandSelection`, which Side answers from the
    syntax tree (`SyntaxHighlighter.enclosingRange`);
  - go to matching bracket.
- **Side:**
  - An Editor menu holds all of them, and each is in the shortcuts table.
  - The comment marker and indent come from each file's language (`LineComments`).
- **Keymaps:**
  - Xcode (the table, the default), VS Code and JetBrains; each preset lists only where it
    differs.
  - VS Code gets ⌘D for next occurrence, ⌥↑/⌥↓ to move lines, F12 for definition, F2 to
    rename, ⌃G for go to line and ⌘. for quick fix, with Stop moving to ⌥⌘.
  - JetBrains gets ⌘B for definition, ⌥⇧↑/↓ to move lines, ⌥↑/⌥↓ to expand and shrink,
    ⌘⌫ to delete a line, ⌥⌘L to format, ⌥↩ for quick fix, and F1 for Quick Help.
  - Function keys can now be bound and shown.
  - Settings → Shortcuts has a keymap menu. A shortcut you set yourself stays on top of
    whichever keymap is chosen, and Reset goes back to that keymap's default.
- Checked in Side with the Xcode keys (⌘/, ⌥⌘], ⌘D), then VS Code's ⌥↑ (macOS takes ⌥-arrow
  chords as menu shortcuts).
- Tests:
  - Alloy: `EditingActionsTests`.
  - Side: no two commands share a default in any keymap, presets name real commands, and a
    keymap keeps the person's own changes.
- Vim mode builds on these actions, in its own RFC.

**Step 8, 2026-09-26.** No Alloy change: its render and syntax themes were already open.

- **The theme** (`EditorTheme`): the editor's background, text, selection, caret, current line
  and line numbers; the syntax colors by capture; and, optionally, the terminal's colors and
  sixteen ANSI colors.
- **Built in:** Side (the design tokens, as before), GitHub Light, GitHub Dark and One Dark.
- **Settings → Appearance** picks one theme for light appearance and one for dark, imports a
  VS Code theme, and removes an imported one. Imports are kept in Application Support.
- **VS Code import** (`VSCodeTheme`):
  - The file is JSON with comments and trailing commas.
  - Its `colors` give the editor's and terminal's colors, and the 16 ANSI colors.
  - Its `tokenColors` map onto captures through one table (capture → TextMate scopes, most
    fitting first). For each scope the most specific rule that covers it wins, and a later one
    wins a tie, as in VS Code. Descendant selectors are skipped as too contextual.
  - Tokyo Night and Night Owl come through with their own palettes (keywords, strings,
    functions, numbers, types, properties, tags, all 16 ANSI colors).
- **Where it applies:** Make's editor (with its gutter and minimap), Review's diffs, and Run's
  terminal. The rest of Side's chrome stays Side's, except that a dark theme in light
  appearance (or the other way round) gives Make's own chrome over the editor the theme's
  appearance, so its labels stay legible. The theme is picked by the system's appearance, not
  that view's.
- Checked in Side: the same file in GitHub Light, One Dark and an imported Tokyo Night, and the
  terminal in One Dark.
- Tests: `EditorThemeTests` covers the import (colors, translucency, specificity, descendant
  selectors, ANSI), refusing a non-theme, choices remembered and cleared when a theme is
  removed, and built-ins that color the common captures.

## Progress

- [x] 1 LSP foundation and completion (below)
- [x] 2 Snippets, signature help, hover, ⌘-click (below)
- [x] 3 Problems, references, rename, quick fixes (below)
- [x] 4 Outline, symbols, formatting (below)
- [x] 5 Settings → Languages (below)
- [x] 6 More grammars (below; Kotlin and C# held back)
- [x] 7 Keymaps (below)
- [x] 8 Themes (below)
- [ ] 9 Budgets
