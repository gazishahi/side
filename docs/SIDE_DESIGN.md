# Side — Design Charter

Companion to `SIDE_PRODUCT_CONSTITUTION.md`. The constitution says what Side
*is*; this says what Side *looks and feels like*. Every UI change from here
forward — including the harness roadmap phases — is expected to conform to this
document, the same way code changes conform to the constitution. Written
2026-08-24, following a full UX/UI audit (findings at the bottom).

## The standard

Side should feel like premium native macOS software — the tier of Things,
Linear, Arc, or Xcode's best moments. Concretely, premium means four things, in
priority order:

1. **Consistency** — one palette, one type scale, one corner-radius language, one hover behavior,
   everywhere. A user should never be able to tell which stage was built first
   by looking at it.
2. **Restraint** — fewer boxes, fewer borders, fewer labels. Hierarchy comes from spacing and
   type weight before it comes from lines and fills. If a border and a
   background tint say the same thing, drop one.
3. **Motion with purpose** — things that appear, animate in; things that move, glide. Never
   animate layout the user is waiting on. 0.2–0.3s, ease-out, subtle. (Think's
   bubble arrival is the reference implementation.)
4. **Depth** — the active thing reads as physically closer: attached to its content, brighter,
   lifted. The inactive recedes. An active tab should feel *part of the editor*,
   not a chip floating above it.

## Tokens

One source of truth in code: `DesignSystem.swift` (`Palette`, `Type`, `Spacing`,
`Radius`, `Motion`). The per-file palettes that exist today (`TracksPalette`,
`ReviewPalette`, the ad-hoc grays in Heron's proposal cards, ChromeBackground)
migrate into it and die.

**Palette (dark, the only theme for now):**
| Token | Value | Use |
|---|---|---|
| `bg0` | white 0.10 | stage background, the deepest layer |
| `bg1` | white 0.145 | cards, panels |
| `bg2` | white 0.17 | active tab, selected row |
| `bg3` | white 0.21 | chips, code spans |
| `bg4` | white 0.24 | received bubbles, hover fills |
| `hairline` | white 0.24 | the only border color |
| `accent` | `controlAccentColor` | sent bubbles, primary actions, focus |
| status | systemGreen / Orange / Purple / Teal / Red / Gray | the existing `TrackStatus` mapping, unchanged |

Text: `labelColor` / `secondaryLabelColor` / `tertiaryLabelColor` only. Never a
hand-mixed gray for text.

**Type:** 11 (meta/labels), 12 (secondary UI), 13 (body/editor UI), 15
(section), 17 (page title). Semibold for emphasis, never bold below 15. Mono at
−1pt from its context.

**Spacing:** 4 / 8 / 12 / 16 / 20. Nothing off-scale without a comment saying
why.

**Radius:** 4 (chips, code spans), 6 (buttons, small controls), 10 (cards,
panels), 17 (bubbles), plus `tabStrip`/`tabEdge`/`rail`/`rowHover` chrome tokens
added when the tab system and Tracks tree were built.

**Typography (added 2026-08-27):** `DS.Text` is the type layer — `display`, `figure`, `title`,
`subtitle`, `heading`, `body`, `control`, `caption`, `micro`, `code` — each a function returning a
scaled `NSFont`. Every size is one that was already in the app, named; the migration was not a
redesign. `DS.Text.Scale` (Compact 0.9 / Default 1.0 / Large 1.15 / Larger 1.3) multiplies all of
them, is persisted, and posts `DS.Text.scaleDidChangeNotification` so open stages rebuild rather
than waiting for a new window. macOS has no app-wide Dynamic Type, which is exactly why this
exists: a hardcoded-point-size app offers a low-vision user nothing. Set in Settings →
Appearance. New UI text uses a role; a raw `ofSize:` in a view is now a defect.

**Spacing (added 2026-08-27):** `DS.Spacing` — `xxs 2 / xs 4 / s 6 / m 8 / l 10 / xl 12 /
xxl 14 / section 20`, a 4pt base because every value already in the code was a multiple or
half-step of it. Stack spacing, custom spacing, and edge insets are migrated (~70 call sites);
the few off-scale leftovers (16, 18, 13, 7, 1) were snapped onto the scale rather than given
tokens of their own. Constraint constants are deliberately *not* migrated: those are geometry
against a specific neighbour, not rhythm. Also added the text/editor colors the charter listed
and the code had been carrying as literals — `text`, `textStrong`, `textSecondary`, `textMuted`,
`textFaint`, `comment`, and the four `scrim*` white overlays.

**Token status (audited 2026-08-25):** `DS.Color`, `DS.Radius`, `DS.Motion`, and
`CircularIconButton` exist. `Spacing` and `Type` namespaces named above are **not
yet in code** — the scale is followed by hand, and an audit counted 24 remaining
`NSColor(white:)` uses, 8 numeric `cornerRadius` assignments, and 57 off-scale
layout constants outside `DesignSystem.swift`. Editor/syntax/terminal colors are
the largest legitimate holdouts; the rest is unmigrated.

**Motion:** appearance = fade + 12–16pt rise + 0.96 scale, 0.25–0.3s ease-out.
Hover reveals = alpha animate, ~0.15s. Reordering = let NSStackView/Auto Layout
animate positions. Never animate during a full re-render (reattach lays out
instantly — Think already does this correctly).

## Component canon

- **Card**: `bg1` fill, `hairline` 1pt border, radius 10. Rows inside separated by hairlines,
  never nested borders.
- **Chip**: `bg3` fill, radius 4, mono 11 — branch names, code spans.
- **Status pill**: status color at 16% fill, status color text, semibold 10.5, radius 4.
- **Bubble**: solid fill (accent = sent, `bg4` = received), radius 17, hugs content, no border.
- **Primary action**: one per surface, accent-tinted. Everything else is quiet until hover.
- **Hover affordances**: actions live *beside* content (Tracks rows, bubble copy), revealed at
  alpha, circular hit areas for icon buttons — a circle, measured, not an
  approximation.
- **Empty states**: one sentence, `tertiaryLabelColor`, centered, plus the single action that
  fixes it. Never explainer paragraphs baked into a working screen (see: Think's
  removed intro line). Explaining belongs in empty states and onboarding, not
  permanent chrome.

## Per-surface direction

- **Window title**: humane — `file — track` (project lives in the toolbar already). Never a raw
  worktree filesystem path; the user should never see `Application
  Support/Side/Worktrees/…`.
- **Tabs (Make + Run, one shared system)**: active tab visually attached to the content below it
  (same fill as editor surface, no bottom seam); inactive tabs quiet; circular
  close hover; insert/remove animate (fade+slide); drag = lift (shadow + slight
  scale) and glide, siblings animating aside. Kill the duplicate filename label
  sitting left of the tab strip.
- **Toolbar**: stage switcher is the centerpiece — needs badge states (● pending) and must never
  collapse into overflow. Quick Open gets a minimum window width or a
  functioning collapsed button — a dead control is worse than no control.
- **Menu bar**: `Switch to Tab 1…8` collapses into a `Tabs` submenu (⌘1–8 still work,
  unadvertised at top level). Stages get first-class jump shortcuts (⌃1–⌃5,
  Navigate menu). `Toggle Markdown Preview` moves from File to a View section.
- **Review**: a real diff viewer, not a `git diff` text dump — per-file collapsible cards with
  filename header and +/− counts, line numbers, colored gutter bars rather than
  +/− prefixes. This is the single highest-leverage visual upgrade in the app;
  the same component then serves Make (hunk review), Think (edit proposals), and
  Review.
- **Tracks**: real tree rendering — curved connector lines from parent row to child rows (the
  git-graph read), not just an indent + straight rail. Status pills stay.
- **Run**: terminal gets breathing room (12pt inset) inside a proper container; session tabs use
  the same tab system as Make instead of a floating pill colliding with the
  prompt.
- **Think**: an **iMessage-anatomy composer on Liquid Glass** — `[+] [capsule text field · mic]
  [send]`, one thin row, floating over a full-bleed transcript with no separating line, so
  messages refract through the glass as they scroll (`DS.makeGlass`: `NSGlassEffectView` on
  macOS 26, `NSVisualEffectView` fallback; the glass view needs a `contentView` or it renders
  nothing). + opens Add File Reference / Compact / New Conversation; mic triggers system
  dictation. Sent/received bubbles carry the real iMessage tail — a drawn bezier, not a corner
  radius; errors get no tail, they aren't speech. Session state lives in **one glass pill**
  above the composer's trailing corner ("Claude Sonnet 5 · Build · 1%", tinted by context
  status) opening an NSPopover of real controls: a model popup grouped by provider, capsule
  segmented controls for thinking effort, tool scope, and autonomy, and the context/spend
  figures. One pill, not five chips — the capsule holds only input affordances. The pill and
  composer are added to the view *after* the scroll view, or scrolled bubbles paint over them.
  NSButton is flipped: a menu popped "above" needs negative y. The slash-command palette
  (/compact, /new, /ask, /plan, /build, /manual, /guarded, /full) is the keyboard path to
  everything in the popover. The explainer paragraph stays empty-state only.
- **Preferences**: an `NSTabViewController` with a toolbar tab style — Providers, Usage,
  History. Panes are plain AppKit stacks at 20pt insets; the Usage summary is the one card
  (`DS.Color.bg2`, `DS.Radius.card`), with figures at 20pt semibold over 10.5pt secondary
  captions and fixed-width right-aligned numeric columns so rows line up down the table.

## Audit findings (2026-08-24, all verified live or in code)

Confirmed from the user's report: tab chips are flat floaters with a
non-circular close hover and zero add/close/drag animation polish; Quick Open
collapses into toolbar overflow at narrow widths where it does nothing (and
disappears entirely below ~800pt) — the ⌘P menu item also fails in that state
since the collapsed field can't take first responder; Review is a raw diff dump
with no per-file structure; Tracks' hierarchy is an indent, not a tree; Think
ships an explainer sentence as permanent chrome; Navigate lists eight `Switch to
Tab N` items; no stage-jump shortcuts exist anywhere despite the constitution
promising "keyboard shortcuts … move between stages."

Found in the audit beyond the user's list:
1. **Window titles leak worktree paths** — `greeter.ts – /Users/…/Application Support/Side/Worktrees/side-demo-repo-2951fe0f/src/greeter.ts — track (branch)`.
2. **A duplicate filename label sits left of the tab strip**, looks like a stale second tab, and
   does nothing when clicked.
3. **Run stage has no chrome**: terminal starts at y=0 flush against the toolbar, the shell
   prompt renders under a floating session pill ("1 ✕") in the top-right, and
   Run's tab system shares nothing visually with Make's.
4. **Three duplicated palettes** (`TracksPalette`, `ReviewPalette`, Heron card grays) already
   disagree: proposal cards use 0.13/0.28, cards use 0.145/0.24, Review's stage
   bg is flat 0.1 while Think uses `ChromeBackground` and the terminal is pure
   black.
5. **Custom-drawn views are invisible to accessibility** — tab chips draw their titles in
   `draw(_:)` and expose no AX name (verified: scripting sees `missing value`
   for every chip); same class of problem for any hand-drawn control.
6. **Review's first render after launch can be entirely blank** (pre-existing, already tracked in
   the harness roadmap notes) — worth fixing inside the Review rebuild.
7. **Stage backgrounds differ between stages**, so switching stages visibly "jumps" in tone.

## Sequencing

Fix batches, in order — each lands on the tokens first so nothing is styled
twice:

- **Batch 0**: `DesignSystem.swift` (tokens above), migrate the three palettes onto it. No visual
  change intended; pure consolidation.
- **Batch A — chrome**: window title, tab system rebuild (shared by Make/Run), Quick Open
  min-width fix, menu bar cleanup + stage shortcuts, toolbar/stage-switcher
  polish.
- **Batch B — surfaces**: Review diff viewer (the flagship), Tracks tree connectors, Run
  container/inset, Think copy removal + composer.
- **Batch C — fit and finish**: AX names on custom views, unified stage backgrounds, empty-state
  pass, Review first-render bug.

Harness roadmap Phases 2+ (model picker, modes, usage dashboard) build *on top
of* these tokens and components — the usage dashboard is a Card, the mode
selector is a chip row, the model picker matches the composer. Nothing in those
phases should introduce a new visual primitive without adding it to this
document first.
