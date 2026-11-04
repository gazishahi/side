# Vim mode in the Editor

Status: decisions pending (2026-11-04). Nothing built yet.

## Why

Vim bindings are on the polish list from 2026-11-03, and they're on the bar for the audience
Side now aims at: people who'd otherwise use Zed, VS Code or a JetBrains IDE. Each of those
ships a vim mode. Zed's is built in and is the best of the three. VS Code's (VSCodeVim) and
JetBrains' (IdeaVim) are plugins with millions of users. For many developers, no vim mode is
reason enough not to switch.

A half-built vim mode is worse than none. A vim user's fingers expect `ciw`, `dt)`, `.`, counts
and registers to work. When one fails, the whole mode feels broken. So the goal is the core of
vim done exactly as Neovim does it, rather than every corner of it done loosely.

**The goal:** someone who uses vim every day can turn on Vim mode in Side and edit code without
noticing anything missing in the first week.

## What the person sees

- **Settings › General › Editor › Vim mode**, off by default. It's separate from the keymap (Xcode, VS
  Code, JetBrains), and ⌘ shortcuts keep working with it on. Vim mode only takes keys typed
  without ⌘.
- In Normal mode the caret is a block over the character. In Insert mode it's the usual bar.
  In Replace mode it's an underline. Visual mode uses the normal selection colors.
- The Editor's status row shows the mode where the caret position sits today: `NORMAL`,
  `INSERT`, `VISUAL`, `V-LINE`, `V-BLOCK` or `REPLACE`. A pending operator or count shows
  beside it as you type, for example `2d`. VoiceOver announces mode changes.
- `:` opens a one-line command field in the same place, which runs ex commands (below). `/` and
  `?` search with the Editor's Find, so matches are highlighted as they are today.
- A new file opens in Normal mode, and so does a tab you switch back to. A file opened from an
  agent's diff or from Find opens in Normal mode with the caret on the line.
- Writer mode and Live Markdown: see decision 4.
- The Terminal is untouched: vim inside a terminal is real vim. The Agent's composer and every
  other text field stay as they are.

## Scope

### Phase 1: the core, which is what makes it vim

- **Modes:** Normal, Insert, Visual (characterwise and linewise), Replace (`R`), and
  operator-pending.
- **Counts** on motions, operators and commands (`3w`, `2dd`, `d3w`, `5x`).
- **Motions:** `h j k l`, `w b e ge W B E gE`, `0 ^ $ g_`, `gg G` and `{n}G`, `f F t T` with
  `;` and `,`, `%`, `{ }`, `( )`, `H M L`, `gj gk` (display lines when wrapped), and `*` `#`
  `n` `N`.
- **Operators:** `d c y`, `> <`, `=` (the Editor's Format Selection), `gu gU g~`, and `J`
  (join). Each takes motions, text objects and a doubled form (`dd`, `cc`, `yy`, `>>`).
- **Text objects:** `iw aw iW aW`, `i" a" i' a' i\` a\``, `i( a( ib ab`, `i[ a[`, `i{ a{ iB
  aB`, `i< a<`, `it at` (tags), and `ip ap`.
- **Editing:** `x X s S r ~ p P u <C-r> .`, `i a I A o O`, `C D Y`, `<C-a> <C-x>`
  (increment numbers), and Insert-mode `<C-w> <C-u> <C-o>`.
- **Registers:** the unnamed register, `"0`, `"1–"9` (the delete history), `"a–"z` and their
  uppercase appends, `"_` (black hole), and `"+ "*` (the system clipboard). How the unnamed
  register relates to the clipboard is decision 2.
- **Search:** `/` `?` `n N * #`, using Find's own engine and highlighting.
- **Ex commands:** `:w :q :wq :x :q! :e {file} :{n}`, `:noh`, and `:s/a/b/flags` with `%` and
  visual ranges.
- **Undo:** one Insert-mode session is one undo step, and so is one `.` repeat, as in vim.
- **Scrolling:** `<C-d> <C-u> <C-f> <C-b> <C-e> <C-y>`, `zz zt zb`.

### Phase 2: what a heavy user reaches for in the first week

- Visual block (`<C-v>`), with `I` and `A` across the block, using Alloy's multiple carets.
- Marks (`m{a-z}`, `` ` `` and `'`), and the jump list (`<C-o> <C-i>`), joined up with Side's
  navigation history (docs/SIDE_RFC_NAVIGATION_LEDGER.md) instead of living beside it.
- Macros (`q{reg}`, `@{reg}`, `@@`).
- Folding: `za zo zc zR zM`, on Alloy's folds.
- Language-server motions: `gd` (Jump to Definition), `gr` (Find References), `K` (Quick Help),
  `]d [d` (next and previous problem).
- `gcc` and `gc{motion}`, Toggle Comment as a vim operator.
- Surround (`ys cs ds`, as in vim-surround), which Zed and VSCodeVim both build in.

### Not doing

- Vimscript, Lua or plugins. Side isn't Neovim, and pretending to be would set the wrong
  expectation.
- Reading `~/.vimrc` or `init.lua`. Decision 5 covers a few mappings of Side's own.
- Windows and splits (`<C-w>`) before split view exists. Once it does, `<C-w>` moves between
  panes.
- Ex commands beyond the list above (`:g`, `:normal`, `:read`, ranges other than `%` and
  visual).

## How

### Where it lives

A new target, `AlloyVim`, in the Alloy package. It's a state machine over `AlloyCore`'s
`TextBuffer` (text, selections and undo grouping) with no AppKit in it, so the whole of vim can
be tested in plain unit tests. `AlloyAppKit` hands it key events, and Side's `AlloyEditorEngine`
turns it on and connects the parts Side owns: Find, Format, Toggle Comment, saving, the status
row and the language server. Decision 1 covers whether it goes in Alloy or in Side.

### Keys

Today `AlloyTextView.keyDown` passes every event to the input method, then to
`interpretKeyEvents`. Vim needs the event first. In Normal mode `w` is a motion, not the letter
w, and a Japanese input method must not get to compose it.

The change is one hook in `AlloyTextView.keyDown`, before `inputContext`:

```swift
if let vim = editor.vim, vim.mode != .insert, vim.handle(KeyPress(event)) { return }
```

`KeyPress` is the key as vim reads it: the character from `charactersIgnoringModifiers` on the
current keyboard layout, with ⌃ and ⇧, so `<C-r>` and `R` are what they look like on any
layout. Keys with ⌘ are never vim's, and go on to menus and shortcuts as today. In Insert mode
everything goes through the input method as it does now, except `Esc` and `<C-[>` (back to
Normal) and the few Insert-mode keys in phase 1.

`Esc` also does what it does today: it closes completion, then leaves Insert mode, in one
press, as Zed and VSCodeVim do.

### Edits and undo

Every vim command becomes `TextBuffer.apply(_:selectionsAfter:kind:)` calls, the same path
typing takes, so language servers, agents' edit tracking, autosave and the gutter's change
marks all see vim's edits as ordinary ones. `EditKind` gets a `.vim(group:)` case. Edits with
the same group id join one undo step: an Insert session, a `.` repeat, a macro run.

`.` replays the last change, recorded as the command that made it (operator, motion, count and
the text typed in Insert mode), not as the edits. That way `.` on the next word deletes the next
word's length, not the first word's.

### Multiple carets

Alloy already keeps several selections. In vim mode a motion or operator applies to each of
them, as Zed does. Visual block (phase 2) is built on that. With one caret, it's plain vim.

### The caret

`TextRenderer` draws the caret as a 2 pt quad. It gets a shape: bar, block (the width of the
character under it, drawn behind the glyph with the glyph in the background color, as Terminal
draws its cursor) or underline. The shape is drawn on the same pass, so it adds no cost per
frame.

### Wrapped lines and folds

`j` and `k` move by line in the file, as in vim, and `gj` `gk` by row on screen. Both step over
a folded range as one line. Both keep the goal column the way `AlloyTextView.goalX` already does
for ↑ and ↓.

### Correctness: tested against Neovim

Zed's vim mode got good by checking itself against Neovim. Its tests run each case in both and
compare the results. Side will do the same, without needing Neovim on every test run:

- A case is a buffer with a caret (`"hello ˇworld"`), some keys (`"ciwthere<Esc>"`) and the
  expected buffer, caret and mode afterwards.
- `scripts/vim-fixtures.sh` runs every case through `nvim --headless --clean` and writes the
  expected results to `Packages/Alloy/Tests/AlloyVimTests/Fixtures/*.json`, which are
  committed. The tests compare Alloy against those files.
- Changing a case means rerunning the script. A fixture that changes when Neovim updates shows
  up as a diff in review.

Phase 1 is done when there are at least 600 cases and every one passes.

### Performance

A vim key adds a state-machine step and the same buffer edit a typed key makes. The keystroke
budget (`editor.keystroke`, 8 ms p99 from key to frame) applies unchanged, and gets a vim case:
`ciw` and `.` in a 100k-line file.

## Measures

| Measure | Target |
|---|---|
| Fixture cases passing, phase 1 | ≥ 600, all |
| `editor.keystroke` with Vim mode on (`dw`, `ciw…<Esc>`, `.`) | ≤ 8 ms p99 |
| Undo after an Insert session | one step, as in Neovim |
| Keys with ⌘, with Vim mode on | unchanged: no shortcut lost |
| Input methods in Insert mode | unchanged (Japanese, Chinese, dictation) |

## Phases

1. **Core** (above), behind the Settings switch.
2. **First week:** visual block, marks and jumps, macros, folds, language-server motions,
   comments, surround.
3. **Side's own mappings** if decision 5 says so, and `<C-w>` once split view exists.

Each phase ships when its fixtures pass and the owner has used it for real work for a few days.

## Decisions pending

1. **Alloy or Side.** Recommended: Alloy, as the `AlloyVim` target. Vim is editor behavior.
   Alloy is open source, and a Swift editor with a correct vim mode is worth more there.
   Side keeps only the wiring. The cost is that each change goes through an Alloy release.
2. **The clipboard.** Options: (a) as in vim, where `y` and `d` fill vim's unnamed register and
   `"+y` copies to the system clipboard; (b) as Zed does by default, where every yank also goes
   to the system clipboard and `p` pastes from it; (c) only yanks go to the clipboard, deletes
   don't. Recommended: (b), with a setting for (a). Copying in Side and pasting in a browser is
   what most people expect. Deletes going to the clipboard surprises some people, and the
   setting covers them.
3. **Normal or Insert when a file opens.** Recommended: Normal, as everywhere else.
4. **Writer mode and Live Markdown.** Recommended: Vim mode works there too, with the same
   bindings. Prose editing is where `cis` and `dap` pay off. A separate setting could turn it
   off there.
5. **Mappings.** Options: (a) none in phase 1; (b) a small file,
   `~/.config/side/vim.conf`, with `nmap` `imap` `vmap` lines only, so `jk` can leave Insert
   mode and `<Space>` can lead; (c) mappings in Settings. Recommended: (b) in phase 3. It's what
   people copy from their vimrc, and Settings can't express it well. Until then, a built-in
   option for `jk` / `jj` to leave Insert mode covers the most common mapping.
