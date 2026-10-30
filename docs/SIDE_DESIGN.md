# Side — Design Charter

Status: reference — governs every UI change; the token layer it names is `DS` in `DesignSystem.swift`. Tokens, motion, components and surfaces rewritten 2026-09-23 to match Direction 02 as built.

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
3. **Motion with purpose** — motion is for change of place, never for waiting: what moves
   shows its path, what appears comes from where it was summoned. Fluid and a little springy,
   never animating layout the user is waiting on (Direction 03, 2026-10-30).
4. **Depth** — the active thing reads as physically closer: attached to its content, brighter,
   lifted. The inactive recedes. An active tab should feel *part of the editor*,
   not a chip floating above it.

## Tokens

One source of truth in code: `DesignSystem.swift` — `DS.Color`, `DS.Text`, `DS.Spacing`,
`DS.Radius`, `DS.Motion`. No color literal, raw `ofSize:` or numeric corner radius outside it;
`TokenComplianceTests` greps the app and the Heron package for them. Rewritten 2026-09-23 when
Direction 02 ("tone over lines") was built — that document holds the reasoning; this one holds
the rules.

**Surfaces — three tones, no borders.** Every color is dynamic (`DS.Color.dynamic(dark:light:)`);
Appearance is a preference (Match System / Light / Dark).
| Token | Dark | Light | Use |
|---|---|---|---|
| `canvas` | `#15171A` | `#F4F4F6` | stage background |
| `raised` | `#1C1F23` | `#FFFFFF` | the card itself (a tone *is* the card), pinned groups, terminal, diff body |
| `overlay` | `#25292E` | `#E8E8EC` | chips on a raised surface, running task, hover on raised rows |
| `hairline` | white/black α .08 | | row separators only — never enclosing |
| `hairlineStrong` | α .13 / .14 | | the stacked-track connector |

Also: `bubbleReceived`, `selectedCapsule` (stage control, tabs), `tabActive`, `tabCloseHover`,
`scrollKnob` (Side's own overlay thumb), `diffAdded` / `diffRemoved` (full-row tints), and the
`scrim*` overlays. New layer colours go through `bindLayerBackground`, never a resolved
`.cgColor` — that would freeze the appearance at the moment it was read.

**Text:** system label colours only (`label` / `secondary` / `tertiary` / `quaternary` — the last
for line numbers, archived rows). Never a hand-mixed gray.

**Accent:** `controlAccentColor`, for focus, selection and the *one* primary action per screen.
Never status.

**Status — dot + text, never a filled pill.** `DS.StatusDot(state:)`, one size (6 pt, 6 pt
before its word), and `DS.StatusLabel(state:text:)`. A dot means an agent's or process's state
and nothing else: Needs you (amber, the only colour that asks for you), Working (a ring,
breathing, the only thing that moves on its own), Ready for review (green), Failed (red), Idle
(a still quaternary ring). A dot shown without its word carries it as a tooltip. Unsaved and
unseen output are marks, not states, and never take a status colour (Direction 03 §3).

**Type — five roles** on `DS.Text`, each scaled by `DS.Text.Scale` (Compact / Default / Large /
Larger, Settings › Appearance): `title` 20, `heading` 15, `body` 13, `caption` 11, `code`
(monospaced), plus `custom(_:)` for the few one-off sizes that still scale. Section labels are
caption, uppercase and tracked (`sectionLabelAttributes`) — the only uppercase on screen.
The subject of a row is the only semibold. The editor and terminal have their own sizes
(`DS.Text.CodeSize`), separate from the interface scale.

**Spacing:** `xxs 2 / xs 4 / s 6 / m 8 / l 10 / xl 12 / xxl 14 / section 20`. Constraint
constants that are geometry against a neighbour aren't rhythm and stay literal.

**Radius:** `control` 6 (buttons, chips, segments), `surface` 10 (cards, diff body, terminal
tail, popovers), `bubble` 17 (Think's bubbles only), and `capsule(height:)` for glass capsules,
whose radius is always half their height.

## Motion

Direction 03 (2026-10-30) holds the reasoning; these are the rules.

- **Motion is for change of place, never for waiting.** Expanding, folding, re-rendering and
  reattaching lay out at once.
- **Three tokens.** `DS.Motion.snappy` (0.26 s, damping 0.80) settles direct manipulation;
  `DS.Motion.smooth` (0.40 s, 0.76) presents panels, popovers, pills and the tab preview;
  `DS.Motion.fade` (0.15 s, ease-out) is for opacity only. The springs overshoot a little and
  settle: fluid, never wobbly. Opacity never springs, and text never stretches with a spring.
- **Direct manipulation is 1:1** while the pointer is down; springs start on release and carry
  the pointer's velocity (`DS.Motion.spring(_:keyPath:velocity:distance:)`).
- **Everything is interruptible:** animations start from the presentation state.
- **Through the helpers:** `DS.Motion.animate`, `DS.Motion.fade`, or a group timed by
  `DS.Motion`. No bare `animator()`, no literal duration (`TokenComplianceTests`).
- **Reduce Motion** turns movement into a 0.1 s crossfade (`animate(_:crossfading:)`); fades
  stay. Consulted only in the token file.
- **Press:** glass controls swell and spring back (`DS.Motion.press`). **Appearance:**
  `DS.Motion.appear` (rise and fade), never on a full re-render. **The working ring** breathes on
  a 2 s cycle, the only thing that moves on its own.

## Component canon

- **Card:** a `raised` tone, radius 10, no border. Rows inside are separated by hairlines.
- **Chip:** `overlay` on raised (or glass in the bar), radius 6, code type for branches and
  task names.
- **Status:** `DS.StatusDot` / `DS.StatusLabel`. There is no status pill.
- **Bubble:** solid fill (accent = sent, `bubbleReceived` = received), radius 17, a drawn iMessage
  tail, hugs its content.
- **Glass capsule:** `DS.makeGlass`, radius half the height — the floating bar's pieces, tab
  track, Promote.
- **Primary action:** one per screen, accent-filled. Everything else is a text action.
- **Row actions:** text, revealed on hover in the row's trailing column, and always exposed as
  accessibility custom actions — never kebab-only.
- **Empty state:** `DS.EmptyState` — one sentence plus the one action that fixes it, performed by
  the shell (`EmptyStateAction`). Never an explainer paragraph.
- **Transient surfaces:** popovers, sheets and in-place expansions only — scoped to the current
  track, dismissed by Escape and by any stage change, never persisted, never a second canvas.

## Per-surface direction

- **Window:** a seamless frame — no toolbar, no drawn title bar; the traffic lights sit on the
  top row's centre line. The title (for Mission Control and VoiceOver) is humane: never a
  worktree path.
- **Top row (38 pt):** each stage's own header — Make's and Run's tab capsule, Review's
  `intent · branch → target · N checkpoints ahead`, Think's conversation title. Clear at rest; it
  frosts only once content scrolls beneath it.
- **Floating bar (kept, 2026-09-23):** track pill at the leading margin, stage capsule centred,
  search at the trailing margin, each on glass. Think's changes and session pills dock into the
  bar row when the window is wide enough and stay above the composer when it isn't — the bar
  never widens the window. `ChromeHost` owns placement; the `.topRow` fallback still exists
  behind the hidden `SideChromePlacement` key.
- **Tabs (Make and Run):** capsule chips in one glass track; hidden with a single tab; drag to
  reorder, drag out (or the tab's menu) to tear off into a window of its own — terminals move
  with their process running. The track pill marks a torn-out window.
- **Make:** editor with its own text size; the file explorer (left or right, Settings ›
  General); the language-server chip trailing the tabs; ⌘K inline instruct — a pointer
  (`@path#L12-L40`) sent to the track's conversation, never the code itself.
- **Think:** a full-bleed transcript under an iMessage-anatomy glass composer; one session pill
  for model, effort, scope and autonomy. Think works on a track. Proposal cards expand to the whole
  file in place; command cards show the terminal's tail; checkpoint lines open a sheet.
- **Review:** the decision header (verification recency relative to the newest checkpoint,
  Promote with its reason when it can't), checkpoints as hairline sections, files as code rows
  over raised diff bodies — no gutter bars, no borders, no visible `+`/`−`.
- **Run:** the terminal is the whole window, its grid ending above the bar; a task row
  (ProjectTasks chips, Verify, the approval question in place) and a status line (live cwd,
  last exit, duration, the running task); a cwd outside the track's worktree is flagged and
  stops agent commands auto-running there.
- **Tracks:** Needs you pinned on `raised`; everything else flat on canvas; specific trailing
  verbs (Respond, Retry, Review, Open, Resume); stacked children under one connector; search
  reaches archived tracks.
- **First run:** one sheet, three steps (open a project, choose a model, create a track), each a
  button that does it; dismissed once, gone for good.

## History — the 2026-08-24 audit

Every finding below was resolved by the batches that followed and by Direction 02; kept as the
record of where the design started.

### Audit findings (2026-08-24, all verified live or in code)

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

### Sequencing (complete)

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
