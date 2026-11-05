# Polish after 0.5.0: switcher, ⌃⇥, Settings, update pill

Status: built 2026-11-05 — every question decided; Settings (§5), the switcher (§2), ⌃⇥ (§3) and the update pill (§4) built; the owner judges them in use. Governs four
surfaces the owner found rough in 0.5.0; written as rules first, then each component
(`design-coherence`: one system, not four one-offs). Builds on `SIDE_DESIGN.md` and the motion
tokens already in `DS.Motion`.

Symbols: `ProjectSwitcherOverlay` `ProjectCycleStrip` `UpdatePill` `GlassPill` `SectionFlow` `ShortcutAreaCard` `AppearancePreview`

## 0. What's wrong today, from the code

| Owner's note | Cause in the code |
|---|---|
| Switcher "at the very top", elsewhere "dead center" | Two surfaces, two anchors. The ⌃⌘P panel is pinned 110 pt from the window's top (`ProjectSwitcher.swift:506`), so on a tall window it reads as "at the top"; the ⌃⇥ strip is at the window's dead center (`ShellViewController.swift:1316`). Neither relates to the stage bar. |
| "At the top it doesn't work properly" | The scroll height is `bounds.height − 110 − 170` (`ProjectSwitcher.swift:620`), a guess at the header and footer, not their measured height; on a short window the footer (hints, More, Open Project) is pushed off or clipped. Not reproduced on screen yet — confirm when building. |
| Open Project does nothing | It calls `MakeWorkspaceViewController.openProject`, which bails when `makeVC.view.window` is nil (`MakeWorkspaceViewController.swift:1588`). Stages not on screen are removed from the window (`ShellViewController.swift:1394`), so from Terminal, Agent or Changes the button is a silent no-op. Bug, independent of the redesign: the open panel should be the shell's, sheeted on the shell's window. |
| Grid shifts on hover | Hover swaps the shortcut label for ⋯ and × (`refreshTrailing`, `ProjectSwitcher.swift:954`). Hidden views collapse in an `NSStackView`, so the trailing group changes width and the title column reflows. |
| × is a vertical pill | A borderless `NSButton` given a 24×24 constraint and `cornerRadius 12` (`ProjectSwitcher.swift:863`); the layer isn't clipped to a square. Cause to confirm on screen; the fix below doesn't depend on it. |
| No Liquid Glass | Both surfaces use `NSVisualEffectView(.popover, .withinWindow)` (`ProjectSwitcher.swift:416`, `:1001`). The palette already uses `NSGlassEffectView` with this fallback (`MakeWorkspaceViewController.makeFloatingPanelSurface`). |
| Animations | ⌃⌘P: a 0.14 s fade of a full-window overlay, nothing else. ⌃⇥: none — added and removed instantly (`ShellViewController.swift:1315`, `:1325`). |
| ⌃⇥ caption jumps left | The caption row holds either a plain label (hugs, centered) or a `DS.StatusLabel` (stretches, left-aligned) (`ProjectSwitcher.swift`, `ProjectCycleStrip.refresh`). |
| ⌃⇥ shows closed projects | It takes `ProjectSwitcherModel.entries`, which appends every not-open recent (`ShellViewController.swift:1313`). |

**Update pill, as of 0.5.0** (`Updates.swift:287`, `StageControl.swift:153` `GlassPill`):
- Percentage resizing: **fixed after 0.4.0.** Digits are tabular and the pill reserves the width
  of "Downloading 100%" while downloading. Keep.
- "Update to X.X.X": **still low-emphasis.** No tint; the label is `.labelColor`, so it reads as
  plain black text, not a button waiting on you.
- Ready: green fill (`statusVerified`) with **white** text. In light mode `#5FBF7A` under white is
  about 2.2:1 — under WCAG's 3:1 for large text. Says "Relaunch to Update".
- Checking: Side's own indeterminate ring, not the native spinner.
- Up to date: words only, no mark, no ×; leaves after 3 s with the pill's generic exit.
- Also: `SIDE_DESIGN.md` says status is "dot + text, never a filled pill". A tinted pill for an
  actionable update needs a stated exception (§4).

## 1. Shared rules (apply to all four)

**Surface.** Every floating panel is one component, `DS.FloatingSurface` (the palette's
`makeFloatingPanelSurface`, promoted): `NSGlassEffectView(.regular)` on macOS 26,
`NSVisualEffectView(.popover)` + 1 pt hairline below it. Radius `DS.Radius.palette`. No extra
shadow host on 26 — glass brings its own. No full-window dimming scrim; glass over live content
is the point. A click outside dismisses.

**Origin.** What you summon from the bottom grows out of the stage bar and goes back into it, as
the palette does (`ShellViewController.animatePalette`, `ChromeHost.paletteOrigin`). One function,
reused; not a second copy.

**Motion tokens** (add to `DS.Motion`; durations are the whole move):

| Token | Value | Use |
|---|---|---|
| `present` | 0.22 s, `easeOut` | panel grows from its origin (scale + opacity), as the palette |
| `dismiss` | 0.18 s, `easeOut` | back into its origin; reversible mid-flight |
| `select` | `snappy` spring | selection capsule sliding between items (one layer that moves, not cells repainting) |
| `hover` | 0.10 s fade | hover fill only; never changes layout |
| `content` | `glanceDuration` 0.09 s crossfade | a label's words changing in place |
| `pillResize` | `smooth` spring | a pill changing width between states |

Rules: opacity never springs; layout never animates on hover; nothing moves on a timer except a
progress indicator; Reduce Motion turns every move into a 0.15 s fade.

**Controls.** `DS.CircleButton(symbol:diameter:)`: a square view, required-priority equal width and
height, layer `cornerRadius = d/2`, `masksToBounds`. Used for every × and ⋯ in these surfaces.
Hover-only controls are **always laid out** and fade in (alpha), so hover can't reflow anything.

**Hints.** Keys, not sentences. A hint row lists at most three: glyph + one word.
`↩ Open   ⌘↩ New Window   ⌘⌫ Close`. Tertiary label color, caption size.

## 2. Project switcher (⌃⌘P, the project chip)

Placement: centered horizontally, bottom edge `DS.Spacing.l` above the stage bar, grown out of the
bar like Find. Width 640, height fits its contents up to 60% of the window; the list scrolls past
that. Search field on top, as the palette's (one header height, `paletteHeaderHeight`).

```
                ┌──────────────────────────────────────────────┐
                │ 🔍 Switch to a project                         │
                ├──────────────────────────────────────────────┤
                │ ▣ Side            This window · main      ⌃1 │
                │ ▣ Khidma          ● Claude Code finished  ⌃2 │  ← selected: capsule
                │ ▣ Sill            2 terminals             ⌃3 │
                │   Not open                                   │
                │ ▣ Relay           Yesterday               ⌃4 │
                │                                              │
                │ ↩ Open  ⌘↩ New Window  ⌘⌫ Close   Open…  ⌘O │
                └──────────────────────────────────────────────┘
                        ┌───────────────────────────┐
                        │  </> Editor   ✦  ±  ▭     │   ← stage bar (origin)
                        └───────────────────────────┘
```

- **A list by default; the grid kept as a setting** (decided 2026-11-05). The toggle leaves the
  panel for Settings → General → "Project switcher: List / Grid". Rows read faster at nine-plus
  projects and match the palette and Find. The grid gets the same surface, origin, selection
  capsule and always-laid-out hover controls, so it isn't the lesser option.
- Row: 44 pt. Logo 24 pt, name (body semibold), one secondary line of state, shortcut right.
  On hover, ⋯ and × (`CircleButton`, 22 pt) fade in **over** the shortcut's slot, which keeps
  its width. × only for projects held open.
- Selection: one capsule layer that slides with `select`; hover tints with `hover` and never
  moves the selection unless the pointer moved (keep today's guard).
- Status uses `DS.StatusLabel` on the row's second line; no extra dots.
- "More projects (n)…" becomes a plain row at the end of the list ("Show 6 more"), not a footer
  button.
- **Open…** (⌘O shown) in the footer, right. Opens the shell's open panel as a sheet on this
  window whatever the stage (fix in §0). Picking a folder switches this window, as today.
- Empty: "No projects yet" + Open… as the only action.
- Enter: `present` from the stage bar. Leave: `dismiss` back into it; picking a project
  dismisses first, then the window's project crossfades (`projectSwitchFade`).

## 3. ⌃⇥ cycle

Same surface and origin as §2, smaller: a row of tiles above the stage bar, grown out of it.

```
          ┌──────────────────────────────────────────┐
          │   ▣        ▣        ▣        ▣          │
          │  Side   [Khidma]   Sill    Relay         │
          │       ● Claude Code finished              │  ← fixed-width, centered
          └──────────────────────────────────────────┘
                     ┌──────────────────────┐
                     │   stage bar          │
                     └──────────────────────┘
```

- **Open projects only** (this window, other windows, held). Closed recents are the switcher's job.
  One open project: ⌃⇥ beeps as today.
- Tiles 88 pt wide, logo 44 pt, name under it. Selection is one capsule that slides (`select`);
  holding ⌃ and tapping ⇥ fast still moves it each press without queuing.
- Caption: a single centered text field the full width of the panel, alignment center, never a
  stack that changes shape. State is drawn as the dot glyph inside the attributed string. Words
  change with `content` (crossfade), not a re-layout.
- Appears only if ⌃ is still held after 120 ms (a quick ⌃⇥ tap switches with no panel, as the
  system app switcher does). Enter `present`; on release it doesn't shrink back — it fades
  (`dismiss`, opacity only) while the window crossfades to the project, so the two motions don't
  compete.

## 4. Update pill

The pill is the one place a filled tint is allowed: **an action waiting on you** (available,
ready). Status the app is merely reporting stays neutral. Added to `SIDE_DESIGN.md` as the stated
exception to "never a filled pill".

| State | Mark | Words | Tint / text | Click | Leaves |
|---|---|---|---|---|---|
| Checking | native `NSProgressIndicator` (small, spinning) | Checking for updates | neutral glass | — | to Up to date / Available |
| Up to date | `checkmark` (secondary) | Side is up to date | neutral | — | after 2.5 s: words fade, pill shrinks to its mark, then scales out (`dismiss`); × on hover dismisses now |
| Available | `arrow.down.circle.fill` | Update to 0.5.1 | accent fill, white text (accent is the "one primary action") | popover: notes + Install | × on hover = later |
| Downloading | determinate ring | Downloading 42% | neutral; tabular digits; width reserved (keep) | popover | — |
| Preparing | native spinner | Preparing update | neutral | — | — |
| Ready | `arrow.clockwise.circle.fill` | Restart to update | green: fill `statusVerified` at 18% + text and mark in a darker green (`#1F7A45` light / `#7BD896` dark), ≥ 4.5:1 | relaunch | — |
| Failed | `exclamationmark.circle.fill` (red) | Update failed — Retry | neutral fill, red mark, label text | retry; popover with reason | × on hover |

- State changes: the mark crossfades (`content`), the width moves with `pillResize`; the label
  never jumps (reserve the wider of old/new during the move).
- "Restart", not "Relaunch": the owner's word, and the one people use.
- The pill appears from its position with `present` (scale 0.9 → 1 + fade); it never slides in
  from off-screen.

## 5. Settings

Keep the sidebar. Change the content side. Decided: the title card shrinks to a 44 pt row (tile,
name, one line); the 220 pt hero is most of the empty space above the fold.

### What the panes hold

The panes aren't one shape, so "one layout for every pane" is the first thing to question:

| Pane | Content | Size |
|---|---|---|
| General | toggles, pop-ups, long explanations | 7 sections, 13 rows |
| Appearance | theme, fonts, sizes: things you judge by looking | 5 sections, 11 rows |
| Agents, Notifications, Languages | toggles, pickers, a few lists | 3–7 sections, 5–7 rows |
| Usage, History | read-only figures and records | small |
| **Shortcuts** | **132 commands in 17 areas** (Editor 27, Window 16, Tabs 11 …) | one table, ten times the rest |

Shortcuts is a different kind of thing: a dataset you search and edit, not a form you read. The
others are short forms whose real problem is width and wordiness, not length.

### Options weighed

**A. One centered column, collapsible sections** (the first draft). Familiar (System Settings).
Doesn't use width, and collapsing only hides the problem: you still open sections to hunt, and a
search has to un-collapse everything. Rejected for Shortcuts; fine for short forms.

**B. Forms reflowed into two or more columns on wide windows.** Uses width, halves scrolling.
But reading order turns ambiguous, sections jump columns as the window resizes, and a 3-section
pane looks lopsided. No Mac app the owner would compare Side to does this. Rejected.

**C. A third column: areas list → commands.** Each area is short (≤ 27), navigation is obvious,
uses width. But sidebar + areas + list is three levels of navigation for one setting. Search has
to span areas anyway, and most people look for a command or a key, not an area. Possible, heavy.

**D. A full-width table with a search-first toolbar** (Xcode Key Bindings, VS Code and JetBrains
keymaps). Dense rows (28 pt, not 44), columns use the width, sticky area headers keep the
grouping, one search covers everything. Weakness: it looks like a different system from the forms
unless it shares their tokens. Its rows, header and search field must be the forms' own.

**E. A keyboard map** (keys lit by what they do). Good for "what's free?", poor for "what's the
key for X?". At most a later secondary view, not the main one.

**F. Form + live preview** (settings column left, a live sample right). Only fits panes whose
settings you judge by eye. That's Appearance: theme, font, text size, cursor.

### Recommendation: layout follows the content's shape; the system is shared

Every pane uses the same header row, type, row and section style, search field and width rule.
What changes is how a pane uses the width, chosen from three patterns:

1. **Form** (General, Agents, Notifications, Languages, Usage, History). One column, 560–680 pt,
   centered. Explanations cut to one line under the row they explain; longer ones go behind an ⓘ.
   General's footers are half its height today. No collapsing; none of these is long once trimmed.
2. **Form + preview** (Appearance). Settings column left (≤ 480 pt); right, a live sample of the
   editor and a terminal that follows every change. On a narrow window the preview moves above
   the settings. The width turns from margin into the thing you're judging.
3. **Table** (Shortcuts), option D, full width up to 960 pt:

```
┌──────────┬────────────────────────────────────────────────────────────────┐
│ 🔍       │ ⌨ Shortcuts                                                     │
│ General  │ [🔍 Search commands or press keys…  ⌨]  (All ▾) (Changed) (Conflicts) │
│ …        │ ─ Editor · 27 ───────────────────────────────── (sticky header) │
│ Shortcuts│  Go to Definition            ⌘ click / F12     Editor      ↺   │
│          │  Toggle Comment              ⌘ /                Markdown        │
│          │ ─ Window · 16 ─────────────────────────────────────────────────│
│          │  …                                                             │
└──────────┴────────────────────────────────────────────────────────────────┘
```

   - Columns: Command · Keys (click to record) · Where (Markdown, LaTeX, everywhere) · reset ↺ on
     changed rows only. Fixed shortcuts read lighter, as now.
   - **Search by keys:** the ⌨ button records a chord and filters to what it's bound to. That's
     the answer to "what does ⌘K do?" and "is ⌥⌘L free?", which neither collapsing nor an index
     gives.
   - **Conflicts** filter: two commands on the same keys in the same place. Today you only find
     out by pressing them.
   - Area pop-up (All ▾) narrows to one area; the sticky headers keep scrolling oriented.

Why not apply one pattern everywhere: a table makes General feel like a spreadsheet, and a form
makes Shortcuts what it is today. One system with three patterns is the coherent choice
(`design-coherence`): the parts match, and each pane's shape fits what's in it.

## 6. Order of work

1. ~~Fix Open Project's no-op (§0).~~ Done 2026-11-05 with the bug fixes (`MakeWorkspaceViewController.sheetWindow`).
2. `DS.FloatingSurface`, `DS.CircleButton`, motion tokens (§1).
3. Project switcher (§2), then ⌃⇥ (§3) — they share the surface and origin.
4. Update pill (§4); check each state on screen with `update <stage>`.
5. Settings (§5).
Each checked on a running build before it's called done (`verify-ui-on-screen`).

## Decisions (owner, 2026-11-05)

1. Switcher: **list by default, grid as an option in Settings → General** (§2).
2. No dimming behind the switcher; glass over live content.
3. ⌃⇥: no panel on a tap under 120 ms.
4. Ready pill: soft green fill (18%) with dark-green text.
5. Available pill: accent fill.
6. Settings title card: a 44 pt row.
7. **Settings layout: the recommendation, to try** (§5): one system, three patterns. Form for the
   short panes; Form + preview for Appearance; Table for Shortcuts. Built 2026-11-05; the owner
   judges it in use.

## As built (2026-11-05, second pass)

The owner's correction after the first build: the real complaint was the empty width, every
pane one centered column. Collapsing (rejected in §5 for a single column) made sense once the
cards sit in columns.

- **Every form pane: sections in columns.** `FormPage` puts the header and other non-section
  views across the page, and runs of sections (`FormSection`) into 1–3 columns
  (`SettingsForm.minColumnWidth` 360, at most `maxColumnWidth` 600 each), filled top-down in
  reading order (`SectionFlow`). Explanations wrap at the width they get (`WrappingLabel`).
  A wide control beside an explanation moves under it. A titled section's long footer sits
  behind an ⓘ (`SettingsForm.infoButton`).
- **Appearance:** settings and preview share the width (settings ~55%), and neither is fixed.
- **Shortcuts:** one card per area, folded to name + count, in the same columns; open areas are
  remembered; Expand/Collapse All; a search or filter opens the cards with a match. Search by
  keys (`KeyCaptureButton`); Changed / Conflicts (fixed, view-local keys never conflict). No
  table: its rows rebuilt on scroll, which lagged.
- Section grounds color themselves when drawn (`RaisedBox`), so a pane off screen during an
  appearance change no longer comes back in the old colors.
- Settings opens at 980 × 680, minimum 900 wide.
- On screen: `SETTINGS_SIZE="1500 860" scripts/uitest/check-settings.sh [pane…]`.

## As built: switcher and ⌃⇥ (2026-11-05)

- `ShellViewController.morph(_:appearing:key:)`: the palette's grow-from-the-stage-bar motion,
  now shared; `DS.Motion.presentDuration` / `dismissDuration` (0.22 / 0.18 s, `easeOut`).
- `DS.makeFloatingSurface` (Liquid Glass on 26, popover material before), `DS.Fill` (token
  fills colored when drawn), `DS.CircleButton` (required square, clipped circle).
- Switcher: placed by `ChromeHost.paletteFrame` above the stage bar; list by default, grid in
  Settings → General (`side.projectSwitcher.style`); one sliding selection capsule; hover fades
  a fill and swaps the shortcut for ⋯/× in a fixed-width slot; "Show n more" row; footer hints
  and Open… ⌘O. A switcher on its way out passes clicks through.
- ⌃⇥: open projects only; shows after 120 ms with ⌃ still down (a tap just switches); tiles in a
  row exactly their width; sliding capsule; one centred caption whose words crossfade; fades on
  release while the window switches.
- On screen: `scripts/uitest/check-switcher.sh` (placement, order, typing, put away, quick tap,
  open-only strip; frames of the open and close in `$SIDE_UIT/check-switcher`).

Fixed after the owner's pass (2026-11-05):

- The file explorer no longer comes out by itself on a project switch (only in a window's first
  project, when it is key), and a switch puts it away. One floating surface at a time: the
  palette and Find, the switcher and ⌃⇥ put it away, and opening it puts the palette away.
  ⌃⇥ works with the explorer focused.
- ⌃⇥'s panel is as wide as its longest caption (to 520 pt), the tiles centred in it.
- A terminal whose connection to its keeper ends while the keeper runs is rejoined, not reported
  as ended; taken by another Side, a key brings it back. The keeper logs why it let a client go.
- The single tab has its X, after its name on hover.
- On screen: `check-switcher.sh` (explorer checks added), `check-keeper-lost.sh`.

## As built: the update pill (2026-11-05)

- `GlassPill` marks: the system spinner (checking, preparing), SF Symbols (checkmark, arrow down,
  restart arrow, red exclamation), the ring for a counted download. `setTint(_:text:)` fills for
  an action waiting on you: accent with white for Update to x; `updateReadyFill` with
  `updateReadyText` for Restart to update (light green deepened from #1F7A45 to #17643A: measured
  on screen, #1F7A45 drew at 4.0:1 on its fill; #17643A draws at 5.4:1).
- The × on hover takes the mark's slot (no change of width): Later on Update to x, dismiss on
  Side is up to date and on a failure. Update failed — Retry retries on a click; the reason is
  its tooltip.
- Up to date stays 2.5 s, then its words fade, it closes up to its checkmark (a width constraint
  animated, so the glass follows), and leaves. Every pill now leaves a little smaller as it fades
  (0.85, `dismissDuration`) instead of only fading.
- Restart, not Relaunch, in the pill and the popover (Install and Restart).
- On screen: `scripts/uitest/check-update-pill.sh` (every state, light and dark, the × on hover,
  frames of the up-to-date leaving).
