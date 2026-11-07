# Side — Design Direction 02: "Tone over lines"

*Rewritten 2026-09-03 after review; **reconciled against HEAD `40199d0`** the same day.
Status: **built** — steps 1–7 shipped 2026-09-04 → 2026-09-23 (step 4 `f066775`…`6d87011`,
step 5 `9f4711c` `65e1335`, step 6 `beb4129`); `SIDE_DESIGN.md` rewritten to match. §2.8 Motion
decided 2026-09-04: option B. §3 replaced 2026-09-22 by chrome v2; the floating bar's trial
ended 2026-09-23 — **kept**.*

Symbols: `ChromeHost` `TrackPill` `StatusDot` `StatusLabel` `EmptyState` `InlineInstruct` `CheckpointSheetController` `FirstRun` `OverlayScrollThumb` `LSPStatusChip`

### As built — where the build departs from the text below

- **Floating bar kept** (§3.0): the trial is over; `.topRow` remains only as the hidden fallback.
- **Bubble arrival** keeps its short rise and fade — a documented exception to §2.8's "only the
  working ring moves"; streaming growth is unaffected (`SIDE_DESIGN.md` › Motion).
- **Run's terminal** is full-bleed with its grid ending above the bar (owner, 2026-09-22/23), not
  on a radius-10 inset card, and keeps the Nerd Font its prompt glyphs need rather than SF Mono.
- **Review:** line numbers are in the editor's gutter (old and new, `13b1f26`); the checkpoint meta line omits scope and autonomy, which checkpoints don't record;
  "Instruct…" is per file, not per hunk — a hunk has no row of its own to hover.
- **Think requires a track** (§6) — conversations started with no track are no longer shown.
- **First run:** replaced by the welcome (`SIDE_DESIGN_WELCOME.md`, 2026-11-07).
- **No first-run preset step** (§3.1): the first-run sheet has three steps (open a project,
  choose a model, create a track); *How do you work?* wasn't built. Pins are set in Settings or
  from the stage control's menu.
- **Beyond the spec:** terminal and file tabs tear out into windows; Run's task chips go through
  the command card via `AgentRunner.proposeUserTask` without answering the model; Heron was
  extracted into `Packages/Heron` between steps 4 and 5.
*Companion docs: `SIDE_DESIGN.md` (charter — updated to match on 2026-09-23),
`SIDE_AUDIT_REPORT_2026-09-01.md` (defects referenced by ID below),
`SIDE_RFC_NAVIGATION_LEDGER.md` (product decisions **not** in scope here).*

## How to use this document

This is a build spec for an implementing agent. Read all of it before touching
code. Every rule has a value. Every section ends in acceptance criteria that are
checkable by test, grep, or a screenshot. Where this document changes something
`SIDE_DESIGN.md` says, this document wins.

**In scope:** design tokens (appearance-adaptive), window chrome (seamless frame,
floating nav bar trial, stage pinning), the four working stages' compositions, transient surfaces, empty/first-run states, inline
instruct in Make, motion rules.
**Out of scope (see the RFC):** cross-project ledger, project-owned terminal
sessions, runner concurrency ceiling, renaming Review, cross-track agent tools.

### Shipped since this was drafted (do not rebuild — reshape or skip)

| Item | State at `40199d0` | What remains |
|---|---|---|
| `DS.Color.dynamic(dark:light:)`, adaptive tokens, forced `darkAqua` removed, appearance as a preference | **shipped** (`9bd2077`) | the **3-tone remap**: replace `bg1…bg4` (9 files) with `canvas / raised / overlay`; delete the ladder |
| Failed runs reach the user (audit A-1) | **shipped** (`e2881bf`) | move the row into the pinned Needs-you group (§4.1) |
| WorkGroupView AX, agent-state announcements (H15, H16) | **shipped** (`0dfa2ee`) | nothing |
| Verification staleness (H14) | **shipped** in the promote dialog | **placement**: also a line in Review's decision header (§4.2) |
| ⇧⌘F Find in Project on shared `ProjectTextSearch` | **shipped** (`aad8315`) | **reshape** field → icon + palette (§3.4); the engine is shared with the agent's tool and must stay |
| Side-by-side diffs, Unified/Split control | **shipped** (`612aeb8`) | keep the control (it is a control, like the session pill); §4.2 rules apply to both layouts |
| `DocStatusTests` asserts Integration/Library are not `Stage` cases | **shipped** (`b8b9f54`) | constitution table edit (RFC R6) |
| All audit **Highs** | **closed** | the "steps 1–2 before Highs" ordering is moot; H7 and H8 (Mediums that are data-integrity) run **alongside** steps 1–2 — see §7 |

**Do not:** add a stage, add a new visual primitive not defined here, add a
color literal outside `DesignSystem.swift`, animate anything the user is waiting
on, or introduce a persistent panel. If a screen seems to need one of these,
stop and write down why instead.

---

## 1. Diagnosis (why — read once)

Think has an idea (glass composer over a full-bleed transcript). Tracks, Review,
Run and Make are correct layouts without one. Three concrete faults:

1. **Boxes in boxes.** Hierarchy is drawn with borders — cards with borders holding
   rows with borders holding chips with borders — so every level looks equally
   important.
2. **State is a sticker.** Status is appended as a filled colored pill that competes
   with content instead of qualifying it.
3. **No composition.** Screens are lists. Nothing is first, larger, or recedes. Run
   has no chrome; Tracks' hierarchy is an indent; Review is equal cards.

The direction: **hierarchy from surface tone, weight and position — not borders,
pills or chrome.** Three tones, two radii, one accent, five type sizes, one motion
curve.

---

## 2. Tokens

All tokens live in `DesignSystem.swift`. Every color is **appearance-adaptive**
via `DS.Color.dynamic(dark:light:)` — **this helper already exists with this
signature and every current token uses it.** The work in this section is the
remap onto three tones and the deletions, not building adaptivity.

```swift
extension DS.Color {
    /// Resolves per appearance. Every surface/status token below uses this.
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
```

Forced `darkAqua` is already removed; appearance follows the Appearance pane.
Keep Preferences and document windows on the same rule.

### 2.1 Surfaces — three tones, no borders

| Token | Dark | Light | Use |
|---|---|---|---|
| `DS.Color.canvas` | `#15171A` | `#F4F4F6` | stage background |
| `DS.Color.raised` | `#1C1F23` | `#FFFFFF` | cards, pinned group, terminal, diff body, active tab |
| `DS.Color.overlay` | `#25292E` | `#E8E8EC` | selected segment, running chip, popover/menu body |
| `DS.Color.hairline` | `white α .08` | `black α .08` | row separators **only** |
| `DS.Color.hairlineStrong` | `white α .13` | `black α .14` | stacked-track connector |

Rules: a `raised` tone **is** the card — no border. Hairlines separate rows, never
enclose them. Popovers in light mode add the system shadow, not a border.
**Terminal background is `raised`** — this replaces the near-black step past
chrome that shipped with light mode (decided: follow this doc).

**Delete:** `TracksPalette`, `ReviewPalette`, the `DiffBody` RGB literals in
`DiffView.swift`, the gutter colors in `LineNumberRulerView.swift`, the
`bg0…bg4` ladder once nothing references it, and every `NSColor(white:)` outside
`DesignSystem.swift`. Terminal background becomes `raised` (not black).

### 2.2 Text

System label colors only: `labelColor`, `secondaryLabelColor`,
`tertiaryLabelColor`, `quaternaryLabelColor` (line numbers, parked rows). They
are already adaptive. Never a hand-mixed gray for text.

### 2.3 Accent

`NSColor.controlAccentColor`, used for exactly three things: focus rings,
selection, and the **single primary action per screen**. **Never for status**
(this removes the accent/amber collision an orange-accent user would hit).

### 2.4 Status — dot + text, never a filled pill

6 pt dot, 12 pt `secondaryLabelColor` text. Meaning is carried by **text and
shape**, color is reinforcement — so it survives any accent, colorblindness, and
both appearances.

| State | Shape | Dark | Light | Motion |
|---|---|---|---|---|
| Needs you | filled | `#D9A441` | `#B8860B` | none |
| Working | **ring** (1.5 pt stroke, hollow) | `labelColor α .6` | `labelColor α .6` | breathes 2.0 s ease-in-out — **the only animated indicator in the app** |
| Verified / review-ready | filled | `#5FBF7A` | `#2E8B57` | none |
| Failed | filled | `#E0655C` | `#C9433A` | none |
| Parked / archived / idle | filled | `quaternaryLabelColor` | `quaternaryLabelColor` | none |

Tokens: `DS.Color.statusNeedsYou`, `.statusWorking`, `.statusVerified`,
`.statusFailed`, `.statusIdle`. Component: `DS.StatusDot(state:)` (an `NSView`,
AX role `.image`, AX label = the state name) and `DS.StatusLabel(state:text:)`.
Remove every filled status pill (Tracks rows, Review headers, stage badges).
Think's session pill stays — it is a *control*, not status.

**Diff tints** (full-row backgrounds; no gutter bars, no `+`/`−` fills):

| Token | Dark | Light |
|---|---|---|
| `DS.Color.diffAdded` | `rgba(95,191,122,.11)` | `rgba(46,139,87,.10)` |
| `DS.Color.diffRemoved` | `rgba(224,101,92,.11)` | `rgba(201,67,58,.09)` |

Editor gutter marks (`LineNumberRulerView`) use `statusVerified` / `statusNeedsYou`
/ `statusFailed` for added / modified / diagnostic, 2 pt wide, from these tokens.

### 2.5 Radius — two values

`DS.Radius.control = 6` (buttons, chips, segments, tabs, status dot container),
`DS.Radius.surface = 10` (cards, terminal, diff body, popovers). Remove `4` and
`17` everywhere **except** Think message bubbles, which keep 17 as the documented
single exception (`DS.Radius.bubble`).

### 2.6 Type — five sizes on the existing `DS.Text` roles

SF Pro / SF Mono. Do not add roles; map these onto the existing ones and delete
the rest. Semibold is reserved for **the subject of a row**; never bold below 15.

| Role | Size · weight | Color | Use |
|---|---|---|---|
| `DS.Text.title` | 20 · 600, tracking −0.02 em | label | stage header (the track intent) |
| `DS.Text.heading` | 15 · 600 | label | checkpoint title, group title |
| `DS.Text.body` | 13 · 400 | label / secondary | row content, descriptions |
| `DS.Text.caption` | 11 · 400 | tertiary | timestamps, meta; **section labels: uppercase, +0.08 em tracking — the only uppercase on screen** |
| `DS.Text.code` | SF Mono 12 · 400 | secondary | branch, SHA, counts, exit codes, paths |

All sizes go through the existing `DS.Text.Scale` multiplier. Make's editor and
Run's terminal font sizes become a **real setting** in Appearance (audit 29.4:
the pane currently claims one exists); default editor 13, terminal 12.5.
`MarkdownRenderer` header sizes derive from the scaled base font (audit 29.3).

### 2.7 Spacing

Existing 4 pt `DS.Spacing`. Fixed values that matter: ledger row **52**; stacked
child indent **26**; stage body inset **28 top / 36 sides / 34 bottom**; terminal
inset **16 / 18**; pinned group padding **6 / 14**.

### 2.8 Motion — one curve, four uses — **DECISION PENDING**

**Decision (2026-09-04): Option B.** Two named exceptions on `DS.Motion.curve` and `DS.Motion.duration`: Promote keeps a single ~300 ms settle, and streaming bubble growth stays (feedback on live content, not layout the user waits on). Nothing else is exempt.

**Addendum (2026-09-22, owner):** a third named exception — the floating bar's glass controls (search) use the Liquid Glass press: swell to 1.12 and spring back (`DS.Motion.press`). The palette's grow-from-the-bar / shrink-back is *presentation* (allowed use 2). Both honour Reduce Motion through `DS.Motion`.

> **Contradiction on record.** As drafted, this section removes the Promote
> bounce (requested 2026-09-01) and makes streaming bubble growth instant (tuned
> for perceived speed). Two coherent options; the owner decides before step 1:
>
> - **A — strict.** One curve, four uses, exactly as below. Promote gets no
>   bounce; streaming text updates instantly. Purest reading of the charter's
>   "never animate layout the user is waiting on."
> - **B — two named exceptions (recommended).** Everything below holds, plus
>   exactly two documented exceptions: (1) **Promote** may play a single
>   ~300 ms settle on the curve — it is the one ceremonial moment in the app;
>   (2) **streaming bubble growth** stays, because it is feedback on live
>   content rather than layout the user is waiting on. Both use `DS.Motion.curve`
>   and `DS.Motion.duration`; nothing else is exempt.
>
> Until decided, implement everything in §2.8 **except** touching those two
> sites.

- `DS.Motion.curve`: **one** timing function for the whole app. Use the system
  default spring (`.spring(response: 0.30, dampingFraction: 0.86)` equivalent /
  `CASpringAnimation` with those values) so Side matches macOS 26. Every
  animation uses this curve. Remove `ChipButton`'s 1.04 overshoot and
  `SlidingSegmentedControl`'s custom bezier; they use `DS.Motion.curve`.
- `DS.Motion.duration(_ base: TimeInterval) -> TimeInterval` returns `0` when
  `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true. **Every**
  `NSAnimationContext` / `animator()` call gets its duration from here (audit
  30.8: zero reduce-motion checks today).
- Allowed motion: (1) hover reveal / selection, 150–200 ms; (2) sheet and popover
  presentation (system); (3) the working ring's breath; (4) tab insert/remove/drag
  as today. **Nothing else moves.** Streaming text, diff expansion, list reload,
  transcript reattach are instant.

### Acceptance — tokens
- [ ] `grep -rn "NSColor(white:" SIDE --include=*.swift | grep -v DesignSystem.swift` → 0 lines.
- [ ] `grep -rn "cornerRadius = [0-9]" SIDE --include=*.swift | grep -v DesignSystem.swift` → 0 lines.
- [ ] `grep -rn "ofSize:" SIDE --include=*.swift | grep -v DesignSystem.swift | grep -v pointSize` → 0 lines.
- [ ] `grep -rn "accessibilityDisplayShouldReduceMotion" SIDE` → exactly 1 hit, in `DesignSystem.swift`.
- [ ] `TracksPalette`, `ReviewPalette` no longer exist; `DiffBody` and `LineNumberRulerView` colors resolve to `DS.Color` tokens (unit test asserts equality).
- [ ] Switching System Settings → Appearance re-renders every stage and Preferences correctly with no forced appearance (screenshot both).
- [ ] `TokenComplianceTests` (extend the existing typography/AX test files) enforce the three greps above at test time.

---

## 3. Window chrome — v2: unified top row + floating nav bar (agreed 2026-09-22)

*Supersedes the 2026-09-03 toolbar layout. The components from that version —
the track pill, the promoted `SlidingSegmentedControl`, the Quick Open palette,
the AX and keyboard rules — carry over unchanged; what changes is **where they
live**.*

### 3.0 Trial status and the revert path (read first)

Chrome v2 has two parts with different commitments:

| Part | Commitment |
|---|---|
| **Seamless frame** — no titlebar, no toolbar, content to the top edge, unified top row (§3.2) | **Permanent.** Ships regardless. The owner's goal is a seamless UI that maximizes usable space; this part serves it either way. |
| **Floating bottom nav bar** (§3.3) | **Trial.** Built to be evaluated in real use. If the owner does not approve of it after implementation, it is **reverted to the top-row placement** (§3.9), without touching the seamless frame. |

Build it so the revert is a small, mechanical change, not a redesign:

1. The navigation components — `TrackPill`, the stage control, the search
   button, and the palette — are **standalone views that know nothing about
   where they are placed.** No component may read the bar's geometry, assume
   it is at the bottom, or position itself relative to the window's bottom edge.
2. A single `ChromeHost` in `ShellViewController` owns placement, switched by
   one enum:
   ```swift
   enum ChromePlacement { case floatingBar, topRow }
   ```
   Everything placement-specific — the bar's glass container, content bottom
   insets, the Think composer merge (§3.4) — lives behind `.floatingBar`.
3. During the trial the value is read from a **hidden** defaults key
   (`SideChromePlacement`, default `floatingBar`), so both layouts can be
   compared on the same build. It is not a user-facing setting.
4. Both placements are implemented and both pass their acceptance criteria
   before the trial starts. Reverting = set the default to `.topRow`, then
   delete the `.floatingBar` branch and the key in a follow-up commit.
5. The permanent parts (§3.1, §3.2, §3.5–3.8) are written so they are
   correct under **both** placements; nothing in them depends on the bar.

### 3.1 Stages and pinning

`ShellViewController.Stage` cases are unchanged (`make, think, review, run,
tracks`). Integration and Library are not stages (RFC R6, done).

The stage control shows the user's **pinned** stages from **Make · Think ·
Review · Run**. Tracks is never in the control; it is reached through the track
pill, ⌘⌥0, and Navigate.

**The rule: a stage is a view over shared engines. Unpinning hides a view,
never a capability.** These invariants hold with any pin set:

- **Tracks** are always reachable (pill). A user with no tracks lives in the
  existing no-track state.
- **Attention** is never hidden. When an **unpinned** stage has something that
  needs the user (Review has a review-ready or failed-verification checkpoint;
  Run has a command awaiting approval), it appears **temporarily** in the stage
  control with its status dot, after the pinned stages, and leaves once the
  user has visited it or the state clears. This is the only case where the
  control's contents change without the user asking.
- **Promotion** is reachable from any pin set — through Review when pinned, and
  through the checkpoint sheet in Think (§5.1) otherwise.
- **Execution** does not depend on Run being pinned: terminals are
  project-owned (R2, done), so agent commands and tasks run headless and their
  output is visible inline (§5.1 terminal tail).

Mechanism — deliberately minimal:
- Pin/unpin the four stages. No reordering, no custom layouts, no hiding the
  bar. At least one stage must stay pinned.
- Pins are an app-wide preference (Settings → General → *Stages*: four
  checkboxes), and also the stage control's context menu.
- **First-run presets** (the §6 first-run sheet gains one step, *How do you
  work?*): **Agent** (Think + Review), **Editor** (Make + Run), **Everything**
  (all four, default). A preset only sets the pins; it is editable afterwards.
- Unpinned stages stay fully reachable through ⌘⌥1–4, Navigate, and the
  palette's command mode. Unpinning never disables a shortcut.
- If the current stage is unpinned while showing, the window stays on it until
  the user navigates away.

### 3.2 The seamless frame and unified top row (permanent)

- Window: `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`,
  `.fullSizeContentView`; no `NSToolbar`. Content extends to the top edge.
- The top edge is **one row**, 38 pt, shared by the traffic lights and the
  stage's own top content:
  - **Make:** file tabs. **Run:** session tabs. Same `TabStripView`
    component, restyled per §2 (active tab `raised`, attached to content, no
    bottom seam).
  - **Think:** conversation title (caption, secondary). **Review:** track
    intent (`heading`) + `code` `branch → target`. **Tracks:** "Tracks" +
    counts. These are the stage headers from §4, moved up into the row.
- **Traffic-light safe area:** content in the row starts at 78 pt from the
  leading edge (after the lights) and never draws beneath them. In full screen,
  where the lights hide, the inset collapses to the normal 12 pt.
- **Drag region:** every empty point in the top row drags the window (tab
  strips report their empty trailing space as draggable;
  `mouseDownCanMoveWindow` on the row's background views). A double-click on
  empty row space performs the system titlebar double-click action (respect
  `AppleActionOnDoubleClick`).
- **Window title is still set** (`window.title`) even though it isn't drawn —
  Mission Control, the Window menu, ⌘\`, and VoiceOver read it. Value per §3.7.
- Row background is `canvas`; a hairline separates it from content **only**
  when content has scrolled beneath it.
- Tabs never go into the floating bar — two kinds of navigation in one control
  is the overload to avoid.

### 3.3 Floating nav bar (trial — `.floatingBar` only)

- One glass capsule, bottom-center, 12 pt above the window's bottom edge,
  height 40, using the existing `DS.makeGlass` (the material Think's composer
  uses). Contents, leading → trailing:
  **[track pill] · [stage control] · [search button]**.
- Width hugs its contents; maximum 640 pt; the stage control never collapses.
  Narrow windows: pill truncates to dot-only first, then the stage control
  switches to icons with the stage name in the tooltip and AX label.
- **Content under the bar:**
  - Scrolling content (editor, transcript, diff, ledger) scrolls **beneath**
    the glass; each scroll view gets a bottom content inset equal to the bar's
    height + 24 pt so the last line can scroll clear of it.
  - **Make:** the caret is never under the bar — scroll-to-visible accounts
    for the inset.
  - **Run:** the terminal gets a **hard** bottom inset (the view is shortened,
    not scrolled under), so the prompt line is never beneath glass.
- The bar is always visible. No auto-hide.
- **Search palette** (§3.6) presents **anchored to the bar, expanding upward**
  when `.floatingBar`; centered in the window when `.topRow`.
- **Info that the earlier idea put on hover** (file, branch, repo) lives in the
  **track pill's popover**, opened by click. Hover shows a tooltip preview
  only. No hover-only information anywhere.

### 3.4 Think: one floating stack, not two bars (trial)

Think's composer is already a floating glass bar at the bottom. Under
`.floatingBar` the two become **one stack**, 10 pt apart, sharing one glass
backdrop region:

- Composer on top; the nav bar directly beneath it, centered, same width as
  the composer's capsule or its own hug width, whichever is smaller.
- While the composer is **first responder with text**, the nav bar dims to
  `tertiaryLabelColor` content (still operable, no animation beyond §2.8).
- The session pill stays attached to the composer, as today.
- The transcript's bottom inset covers the whole stack.

Under `.topRow` Think is unchanged from today.

### 3.5 Track pill (permanent component)

As specified 2026-09-03, unchanged: status dot + intent; no-track state
`<default branch> · No track`; **click → popover** grouped Needs you / Active /
Parked, current track checked, type-to-filter after 2 characters, footer **New
Track…** and **Open Tracks**; selecting a row switches the window's track
without changing stage. **Additions:**
- The popover's header shows what was previously toolbar text: project name,
  branch, and (in Make) the active file's path — as caption/`code` lines.
- RFC R1 v1: a second section, **Other projects**, listing needs-you tracks
  from every other open window's project; selecting one brings that window
  forward on that track.
- AX: `.popUpButton`, "Current track: <intent>, <state>".

### 3.6 Stage control and search (permanent components)

- **Stage control:** Think's `SlidingSegmentedControl`, promoted (the
  `NSSegmentedControl` AX constraint recorded 2026-09-03 still applies).
  Radio-group role, per-segment AX label `"<Stage>, <state>"`, 5 pt dot badge
  (needs-you wins over working), selected segment `overlay` / radius 6.
  Context menu: the pin checkboxes (§3.1).
- **Search button** (`⌘P`) → the palette: modes `files / symbols / text`, plus
  **`commands`** (a `>` prefix, as in most palettes) listing every stage —
  pinned or not — and every Navigate menu item. `text` stays on the shared
  `ProjectTextSearch`. Opens in `files`; Escape restores prior focus; IME-safe
  (`hasMarkedText()`).

### 3.7 Window title and menu bar

- `window.title`: Make `file — track`; other stages `track`; no paths.
- **The menu bar stays canonical.** Every stage (pinned or not), every palette
  mode, the track popover, and pin toggles have menu items with shortcuts. The
  bar is the fast path, never the only one.

### 3.8 Keyboard

Unchanged: stages ⌘⌥1–4, Tracks ⌘⌥0, ⌘P palette, ⇧⌘O symbols, ⇧⌘F text,
⇧⌘T New Track, ⌃⌘T track popover. **Add:** ⌘⇧P palette in `commands` mode;
`⌃Tab` / `⌃⇧Tab` cycle tabs within the current stage's top row. Full Keyboard
Access reaches the bar's three components in order.

### 3.9 Fallback placement (`.topRow`) — the revert target

If the floating bar is not approved, the navigation components move into the
unified top row. Everything in §3.1, §3.2, §3.5–3.8 stays.

- Top row, leading → trailing: traffic lights · **track pill** · [the stage's
  tabs or header, flexible] · **stage control** (compact, 28 pt) · **search
  button**.
- Priority when narrow: stage control and search never collapse; tabs scroll
  horizontally; then the pill truncates to its dot.
- No bottom insets, no composer merge; Think is as it is today; the palette is
  centered in the window.
- Minimum window size under both placements: **760 × 560**.

### Acceptance — chrome
Permanent (must pass under **both** placements):
- [ ] No `NSToolbar`; `fullSizeContentView`; content reaches the top edge; nothing draws under the traffic lights; full-screen collapses the inset.
- [ ] Every empty point of the top row drags the window; double-click performs the system action.
- [ ] `window.title` is set per §3.7 and changes with stage and track.
- [ ] Make and Run tabs render in the top row using one `TabStripView`; Think/Review/Tracks show their header there.
- [ ] Pinning: unpinning a stage removes it from the control but ⌘⌥N, Navigate, and the palette still reach it; at least one stage stays pinned.
- [ ] An unpinned stage with needs-you state appears temporarily in the control with its dot and leaves after it is visited or clears.
- [ ] With only Think pinned, a user can promote (checkpoint sheet) and see command output (terminal tail) without pinning Review or Run.
- [ ] First-run sheet offers Agent / Editor / Everything and sets pins.
- [ ] Pill popover header shows project, branch, and (Make) file path; R1 v1 *Other projects* section works across two windows.
- [ ] Stage control segments have AX labels with state; no `●`/`◑` glyphs; badge is a 5 pt dot.
- [ ] Palette has `files / symbols / text / commands`; opens in `files`; restores focus on Escape; IME-safe.
- [ ] Window resizes to 760 × 560 with no control collapsing into overflow.

Trial (`.floatingBar`):
- [ ] One glass bar, bottom-center, never hidden; scroll views get bottom insets so the last line scrolls clear; Make's caret is never under the bar; Run's prompt is never under the bar (hard inset).
- [ ] Think shows one stack (composer above bar), not two separate bars.
- [ ] Palette anchors to the bar and expands upward.
- [ ] No information is available only on hover.

Revert-readiness:
- [ ] `ChromePlacement` exists with both cases; both pass their criteria on the same build via the hidden `SideChromePlacement` key.
- [ ] `grep -rn "floatingBar" SIDE --include='*.swift'` hits only `ShellViewController` / `ChromeHost` (and Think's composer-merge site) — no navigation component references placement.
- [ ] Screenshots of all five stages in both placements, light and dark, are attached to the PR so the owner can compare.

---

## 4. Stage compositions

Shared rules (all stages): one accent-filled primary action per screen; the
subject is the only semibold; needs-you content is pinned in a `raised` group,
everything else flat on `canvas`; uppercase only for 11 pt section labels; row
actions are **text, revealed on hover in the row's trailing column, and exposed
as AX custom actions** — never kebab-only (audit 30.7).

### 4.1 Tracks
- Header: `title` "Tracks"; caption `N active · N parked · N archived`
  (`N active` is informational only — no limit, no nudge); primary button **New
  Track**; a search field in the header (not the toolbar) filtering intent and
  branch, including archived tracks (constitution: "search retrieves archived
  work").
- **Needs you** group on `raised`, radius 10, padding 6/14, pinned first.
  Contains `needsYou` **and `failed`** tracks (failed-run visibility shipped in
  `e2881bf`; this places it in the pinned group). Rows inside separated by
  hairline.
- Row (52 pt): `[dot] [intent 13·600 / branch code · meta caption] [trailing text
  action]`. The trailing action is the **specific verb**: "Respond" (approval
  waiting), "Retry" (failed), "Review" (review-ready → actually goes to
  Review), "Open" (active), "Resume" (parked). Never a stage name that goes
  elsewhere (audit A-3).
- Hover reveals secondary text actions in the same column (`Watch`, `⋯`), and
  the row takes `raised`.
- Stacked child: indent 26; one `hairlineStrong` connector (vertical from the
  parent row, curving into the child) — replaces the per-row indent rail.
  Children render under their parent in every grouping.
- Parked rows: intent 13 · 500, `secondaryLabelColor`; sorted oldest-last.
- Archived: hidden unless searched or "Show archived" toggled; rendered as
  parked but with `quaternaryLabelColor` intent.
- Untracked branches Side did not create are one line per project ("4
  untracked branches", trailing action "Adopt…"), not rows.
- No card borders anywhere on this stage.

### 4.2 Review
Model: **Think = proposals, pre-apply. Review = checkpoints and promotion,
post-apply.** (Whether the stage should be renamed is in the RFC; build it under
its current name.)
- **Decision header** (the one composed block, on `canvas`):
  - `title` = track intent.
  - `code` line: `branch → target · N checkpoints ahead` (target is the parent
    track's branch for a stacked child).
  - Verification line: `DS.StatusLabel` stating **time and relation to the
    newest checkpoint** — `Verified · swift test passed 4 min ago, after the
    latest checkpoint` / `Verified 2 checkpoints ago · 2 unverified since` /
    `Failed · swift test exit 1, 12 min ago` / `Unverified`. (The staleness
    logic shipped in the promote dialog; this is a **placement** move so it is
    visible before the user reaches for Promote. Reuse it; do not reimplement.)
  - Primary button **Promote to main…** (or **Promote to <parent>…**). Disabled
    with a caption reason when the base is dirty or the parent worktree is
    missing.
- Checkpoints are **sections separated by hairlines**, newest first, not cards:
  - `heading` title; trailing `code` `n · sha` in `tertiaryLabelColor`.
  - Meta caption: `agent · model · scope · autonomy · time · +a −r · N files ·
    <verification word>` — the word colored only when verified or failed.
  - Text actions on hover: `Undo…` (sheet, not `runModal` — audit 32.6),
    `Copy SHA`.
- Files: `code` rows, hairline-separated; `+n` in `statusVerified`, `−n` in
  `statusFailed`; the expanded file's name in `labelColor`, others secondary.
- Diff: `raised`, radius 10; rows tinted with `diffAdded` / `diffRemoved`; line
  numbers `quaternaryLabelColor`, unselectable, 44 pt columns; hunk headers
  tertiary. **No gutter bars, no borders, no visible `+`/`−`** (keep them in AX
  text only, as today). Expansion is instant. **The Unified / Split control
  survives** (shipped `612aeb8`); these rules apply to both layouts, and the
  control itself follows §3.3's segmented-control treatment.
- Overlap banner (8a) sits directly under the decision header as a caption line
  with a dot: `Overlaps 2 files with "Migrate ledger…"`.

### 4.3 Run
- Tab strip **identical to Make's** (`raised` active tab attached to the
  content, no bottom seam; unseen output = 5 pt `statusWorking`-colored dot
  trailing the title).
- **Task row** under the tabs (the unbuilt human half of Phase 10a): caption
  label `Tasks` + one `code` chip per `ProjectTasks` entry on `raised`, radius
  6. The running task's chip is on `overlay` with a leading working ring.
  Clicking a chip runs the task **in the active session through the existing
  `run_shell_command` approval path** — same card, same policy; nothing new
  executes. A **Verify** chip appears when a verification task exists and the
  track's newest checkpoint is unverified; its result attaches to that
  checkpoint.
- Terminal on `raised`, radius 10, inset 16/18; SF Mono at the Appearance
  setting.
- **Status line** (caption, `code`): `cwd · last exit N · duration · running
  <task> in tab N`. cwd is the session's **live** directory; if it is outside
  the track worktree it is shown in `statusNeedsYou` and agent commands in that
  session require approval regardless of autonomy (audit D-10).
- Empty state (no project): one sentence + the single action, as today.

### 4.4 Think (align only)
Already closest to the direction. Remove remaining card borders (proposal and
command cards → `raised`, radius 10); bubble radius stays 17; session pill on
`overlay`. The composer gets an AX label and placeholder value (audit 30.10).
(`WorkGroupView` AX and state announcements — H15/H16 — are **shipped**; do not
redo.) No other change.

### 4.5 Make (least change)
- Tab strip adopts `raised` / `overlay`; LSP indicator moves here (trailing,
  caption + dot).
- Gutter colors from §2.4 tokens; the clickable gutter band is the full ruler
  width (audit 30.5).
- Editor and terminal text size become Appearance settings (§2.6).
- Editor regains first responder on stage return (audit 31.5).
- **Inline instruct** (new, on-philosophy — see §5.3).

### Acceptance — stages
- [ ] No filled status pills anywhere; all status via `DS.StatusDot` / `DS.StatusLabel`.
- [ ] Tracks: failed tracks appear in Needs you; trailing verbs match the table above; stacked children use one connector; header search finds archived tracks.
- [ ] Review: header states verification recency relative to the newest checkpoint for all four cases; checkpoints are hairline sections; diff has no gutter bars or borders; Undo uses a sheet.
- [ ] Run: task chips render from `ProjectTasks`; clicking runs via the approval path (test: chip click produces a `ProposedCommand`); Verify chip appears/disappears per checkpoint state; status line shows live cwd and flags out-of-worktree.
- [ ] Only the working ring animates anywhere in the app (Instruments/visual check).

---

## 5. Transient surfaces — reducing stage switches without a second canvas

Non-negotiable #9 permits capabilities that "appear when needed." These are
**dismissible overlays**, never persistent panels, and never a second canvas.
Each is scoped to the current track.

### 5.1 In Think
- A proposal card's diff expands **in place** to the full-file diff (same
  component as Review's), instead of requiring a trip to Make/Review.
- A command result shows the **terminal tail** inline (last 40 lines, `raised`,
  radius 10, `code`), with "Open in Run" as a text action.
- A checkpoint meta line ("✓ Checkpoint 3 · 4 files") opens a **sheet**
  containing that checkpoint's Review section (files + diff), with "Open in
  Review" and "Undo…" as actions.

### 5.2 In Run
- A task's completion line offers "Attach to checkpoint" when the newest
  checkpoint is unverified — the manual verification path.

### 5.3 In Make — inline instruct
- Select text (or place the caret on a diagnostic) → `⌘K` → a small popover
  anchored to the selection with a single text field and two verbs:
  **Change** / **Ask**. Sends to the track's Think conversation as a message
  carrying a **pointer** (`@path#L12-L40`, same design as `@`-mentions — never
  inlined content).
- **Change** → the resulting `edit_file` proposal appears as a Think card **and**
  as a compact card anchored in Make's gutter at that range (Apply / Reject /
  Open in Think). Applying goes through `ProposedEditApplier` exactly as from
  Think. **Ask** → the answer shows in a dismissible popover at the selection,
  with "Continue in Think".
- Also from Review: hovering a hunk shows "Instruct…", which does the same with
  a pointer to that file range.
- Autonomy and scope rules are unchanged; this is only a new *entry point* into
  the existing loop.

### Acceptance — transient surfaces
- [ ] Proposal diff expands in place; command results show a terminal tail; checkpoint meta opens a sheet — none of them changes `currentStage`.
- [ ] `⌘K` in Make with a selection sends a message whose text contains `@path#Lx-Ly` and no file content; the proposal round-trips to a gutter card and applies through `ProposedEditApplier`.
- [ ] All overlays dismiss on Escape and on stage change; none persists across launches.

---

## 6. Empty and first-run states

Impressions form here; the audit found the alpha loop undiscoverable.

- **No project:** Make's hero as today (recents + Open/New Project).
- **Project, no track:** pill reads `<default branch> · No track`. Make works on
  the checkout as today. Think's empty state is one sentence + **New Track** —
  Think requires a track. Review/Run/Tracks empty states are one sentence +
  the one action that fixes it (existing pattern).
- **Track, no provider or harness configured:** the composer's send action is
  replaced by **Set up a model…** (opens Preferences → Providers); the message
  text is preserved (audit #26 fix stays).
- **First run** (no recents, no keys): a single sheet on first launch —
  three steps in one column: *Open a project · Choose a model · Create a track*,
  each a button that completes it, dismissible forever. No tour, no tooltips.

### Acceptance — empty states
- [ ] Every stage has exactly one primary action in its empty state and no paragraph of explainer.
- [ ] Sending with no provider preserves the composer text and opens Providers.
- [ ] First-run sheet appears once and never again after dismissal (UserDefaults flag).

---

## 7. Implementation order

0. **Decide §2.8 Motion** (owner). **Measure the Release launch** first
   (`-SideLaunchReport YES`, compare to the 08-30 numbers: firstFrame
   216–228 ms, restoreSession 21 ms) — session restore now brings back Run tabs
   and Make tabs, and any PTY spawn, `$SHELL -lic` LSP resolve, `xcodebuild
   -list`, or synchronous file decode that landed before the first frame must
   move after it. Not design work, but it gates the "feels fast" claim the
   motion decision depends on.
1. **Tokens (§2)** — adaptive colors, radii, status components, motion helpers;
   delete duplicate palettes; extend token tests. Intended visual change: tone
   only.
2. **Borders and pills off (§4 shared rules)** across Tracks/Review/Run/Think.
   Most of the visible change; no logic.
3. **Chrome v2 (§3)** — in this order: (a) seamless frame + unified top row
   with tabs/headers (permanent); (b) track pill, stage control, palette as
   placement-agnostic components; (c) `ChromeHost` with **both** placements;
   (d) stage pinning + presets; (e) the Think stack. Ship with
   `.floatingBar` as the default for the trial; the owner decides after use
   (§3.0). If reverted, set `.topRow` and delete the bar branch.
4. **Stage compositions (§4.1–4.5)** — Tracks groups and verbs, Review decision
   header, Run task row and status line, Make gutter/LSP/settings.
5. **Transient surfaces (§5)** — in-place diff, terminal tail, checkpoint sheet,
   inline instruct.
6. **Empty and first-run states (§6).**
7. Update `SIDE_DESIGN.md` §Tokens/Motion/Per-surface to match; mark this
   document **built** with the commit.

**Alongside steps 1–2, not after step 7:** audit **H7** (binary/non-UTF-8 files
open as Latin-1 and save-corrupt) and **H8** (no file watching; the agent's own
applied edits go stale under clean tabs, `@` index frozen at first attach). Both
are data-integrity and both get worse as the agent does more.

**Before step 4 (Run's composition):** RFC **R2** (project-owned terminal
sessions), so Run's tab strip, task row and status line are built once on the
right ownership. **Immediately:** RFC **R6** (constitution table edit) and
**R4** (two read-only tools). **In step 3:** RFC **R1 v1** (the pill's *Other
projects* section).

Each step is a separate commit or PR with its acceptance checklist in the
description.

## 8. Files most affected (orientation, not a limit)

`DesignSystem.swift` · `ShellViewController.swift` (frame, top row,
`ChromeHost`, stage control, title, pinning) · `AppDelegate.swift` (appearance, menus, shortcuts, first run) ·
`TracksWorkspaceViewController.swift` · `ReviewWorkspaceViewController.swift` ·
`DiffView.swift` · `RunWorkspaceViewController.swift` ·
`TerminalViewController.swift` · `ThinkWorkspaceViewController.swift` ·
`MakeWorkspaceViewController.swift` (tab strip, Quick Open palette, gutter,
inline instruct) · `LineNumberRulerView.swift` · `MarkdownRenderer.swift` ·
`AppearanceViewController.swift` · `Heron/ProjectTasks.swift` (task chips read
it) · tests: `AccessibilityTests`, `TypographyTests`, `WorkGroupViewTests`, new
`TokenComplianceTests`.
