# Side: Design Direction 03, "Motion, status and tabs"

Status: agreed with the owner 2026-10-30 (decisions in §8). Nothing here is built yet. Once agreed, the
rules move into `SIDE_DESIGN.md` (the charter) and the tokens into `DesignSystem.swift`, and this
document stays as the reasoning and the build order.

Scope: the owner's groups 2 and 3 (2026-10-29): the tab rework in Make and Run, a general
animation pass, status indicators, sound when something waits on you, and an update UI in place
of Sparkle's window. Notifications follow later on the same rules.

## 1. Why a third direction

Direction 02 set the tones, type and status dots, and it set motion deliberately low: "nothing
else moves". That kept Side calm, but it also left it feeling static and, in the owner's words
about the tabs, cheap: things change place without showing where they went, a dragged tab
lags behind a system drag image, and the same dot means five things in five sizes.

The fix isn't more animation everywhere. It's three systems, each defined once and reused:

1. **Motion** that explains space: what moved, where it came from, where it went.
2. **Status** with one vocabulary: one dot, one set of meanings, one place for the words.
3. **Components** shared by every surface that needs them: one tab strip, one glass pill, one
   progress ring.

What the survey of the current build found (2026-10-30):

- Make and Run share `TabChipView`, but each owns a copy-pasted strip builder, drag handler and
  close animation. Run can't rename a tab. A reorder may not be saved until the next rebuild.
- Tear-out starts 36 pt from the *press point*, not the strip's edge. A straight vertical pull
  never starts a drag at all. The preview is a separate window shown without a transition.
- Dots come in four sizes (5, 6, 7, 8). Two are hand-drawn with no accessibility. The explorer
  borrows status colors to mean git states. Tracks says "Done" over a dot named "Verified".
- About a dozen `animator()` calls skip `DS.Motion` (implicit 0.25 s, no Reduce Motion), and a
  few fixed durations have no curve.
- The only sound in the app is `NSSound.beep()` for errors. Updates are Sparkle's stock window.

## 2. Motion

### 2.1 The rule

**Motion is for change of place, never for waiting.** Something that moves shows its path;
something that appears comes from where it was summoned; something that leaves goes back where
it came from. Nothing the user is waiting on animates (unchanged from the charter): expanding,
folding, re-rendering and loading lay out at once.

Three further rules make it feel physical instead of decorative:

- **Direct manipulation is 1:1.** While the pointer is down, the thing under it follows exactly:
  no easing, no lag, no catch-up. Springs start only on release, from where the thing is.
- **Everything is interruptible.** Every animation starts from the layer's presentation state,
  so a second action mid-flight redirects it instead of jumping or queueing (the explorer's
  double-press bug, fixed 2026-10-29, was this rule missing).
- **One gesture, one motion.** A change that is one thing to the user is one animation: a tab
  becoming a window is a single continuous morph, not a drag image, then a panel, then a window.

### 2.2 Tokens

Three springs, replacing the single curve. Every duration still goes through `DS.Motion` so
Reduce Motion applies everywhere.

The feel is **fluid and a little springy**, as in Rex (the owner, 2026-10-30): things overshoot
their place slightly and settle, and motion that follows a gesture keeps the speed the hand left
it with. A spring at damping 0.88 or above barely overshoots and reads as a plain ease-out, so
the springs sit lower.

| Token | Spring (response, damping) | Overshoot | Use |
|---|---|---|---|
| `DS.Motion.snappy` | 0.26 s, 0.80 | about 1% | settling after direct manipulation: a tab set down, neighbours sliding aside, a press releasing |
| `DS.Motion.smooth` | 0.40 s, 0.76 | about 2% | presentations: panels, Side's own popovers, the preview morph, a pill growing |
| `DS.Motion.fade` | 0.15 s, ease-out, opacity only | none | hover reveals, crossfades, anything that changes but doesn't move |

- **Velocity carries over.** A spring that ends a gesture (a tab let go mid-throw, a preview
  released) starts with the pointer's last velocity, so a flick lands with momentum instead of
  stopping and restarting.
- **Opacity never overshoots.** Springs move position, size and scale; alpha always uses `fade`,
  so nothing flashes past fully opaque or blinks.
- **Text doesn't stretch.** A pill or chip that springs to a new size moves its edges; its title
  crossfades and never scales with the overshoot.

The numbers are a starting point, tuned by eye on the tab drag (step 2) before anything else
adopts them.

`DS.Motion.press` and `DS.Motion.appear` stay, rebuilt on these. The working ring's breath
(2 s) stays the only thing that moves on its own.

**Reduce Motion** stops being "duration zero". Per Apple's guidance, movement becomes a short
crossfade (0.1 s) and scale effects are dropped, so a panel still visibly arrives instead of
popping.

### 2.3 Where motion goes

| Surface | Motion |
|---|---|
| Tabs | the whole of §4: lift, follow, neighbours aside, morph to a preview, set down |
| Stage switch | the stage control's thumb slides (`snappy`); stage content crossfades (`fade`). Content never slides sideways: stages are places, not pages |
| File explorer, palette | slide and fade in from their edge (`smooth`), out the same way |
| Update pill, attention pills | grow out of the bar (`smooth`); content changes inside them crossfade |
| Rows appearing (Tracks, Think) | `appear` (rise and fade), once, never on a full reload |
| Hover and selection | `fade` |

**Retire:** every bare `animator()` and fixed duration listed in the survey moves onto a token.
`TokenComplianceTests` gains a check: no `animator()` outside a `DS.Motion` context, and no
literal duration.

## 3. Status

### 3.1 One vocabulary

A dot means **an agent's or a process's state**, and nothing else. There are five meanings:

| State | Word | Shape | Color | When |
|---|---|---|---|---|
| Needs you | Needs you | filled | amber (`statusNeedsYou`) | waiting on approval, an answer or a choice |
| Working | Working | ring, breathing | `label` α .6 | an agent or task is running |
| Ready | Ready for review | filled | green (`statusVerified`) | a turn finished with changes to review, a check passed |
| Failed | Failed | filled | red (`statusFailed`) | a run, check or command failed |
| Quiet | Idle / Parked | hollow ring, still | `quaternaryLabel` | nothing happening |

Color is used tastefully by giving each one a single meaning: **amber is the only color that
asks for you**, red is only failure, green is only a result. Accent blue never means status.
"Done" and "Verified" become "Ready for review"; one word per state, everywhere.

Two things that look like status aren't, and stop borrowing its dots:

- **Unseen output** (a Run tab printed while you were away): a 5 pt `secondaryLabel` dot. It's
  the system's "new" mark, not a state, and it never takes a status color.
- **Unsaved** (Make's dirty tab): the same 5 pt dot, where the close button goes, as macOS does.
- **Git marks** in the explorer become letters (`M`, `A`, `U` for conflict), tertiary text,
  tinted with the diff colors. A dot in the explorer would read as an agent.

### 3.2 One geometry

- **Dot:** 6 pt, centred on the text's x-height, 6 pt before its word. Ring: 6 pt with a 1.5 pt
  stroke. One `DS.StatusDot`; no hand-drawn dots.
- **Words:** caption (11 pt), secondary. The status's own word comes first; detail follows after
  a middle dot ("Needs you · approve a command").
- **A dot alone** (stage control, tab strip, switcher rows) must still say its word: a tooltip
  and an accessibility label, always. It appears only for Needs you, Failed and Working; a quiet
  dot is never shown alone.
- **Placement:** before the subject in rows; at the trailing edge of a segment or tab, after the
  title, in compact chrome. Never inside a filled pill (unchanged).

### 3.3 Sound

Sound marks one thing: **something is waiting on you and you aren't looking at it.**

| Event | Sound | Default |
|---|---|---|
| An agent starts needing you | system "Glass" | on |
| A run or check fails | system "Funk" | on |
| A turn finishes with changes | system "Tink" | off (Settings) |

Rules:

- Only when the change happens out of view: the window isn't key, or it shows another track or
  stage. Never for what you're watching happen.
- At most one sound every 3 s across all windows; the app decides once, not each window. Today
  every window's observer would fire.
- Plays at the system's alert volume and respects Focus (it's skipped when Focus silences
  notifications, as it will be for notifications).
- One hook: the diff in `ShellViewController.runnerActivityChanged()`, lifted to an app-level
  `AttentionCenter` so sound, the Dock badge and (later) notifications share one decision.
- Settings › Notifications: "Play a sound when an agent needs you" (on), "Also when a turn
  finishes" (off). System sounds, which people already recognize (the owner, 2026-10-30:
  no custom sounds for now).

**Notifications (later)** use the same events, the same out-of-view rule and the same throttle.
A notification carries the sound instead of the app playing it, so nothing plays twice.

## 4. Tabs

### 4.1 One component

`TabStrip` becomes one component that owns the chips, the glass track, ordering, drag, tear-out,
rename, insert and close. Make and Run each give it a model (titles, states, which is active) and
receive its events. Every behavior below is written once.

**Anatomy (kept from today):** a 30 pt glass track; chips 24 pt tall, 96 to 200 pt wide; the
active chip on `selectedCapsule`; title in body medium, secondary when inactive. The status slot
is the trailing 14 pt: the close button on hover, else the unsaved or unseen dot (§3.1), else
a status dot (Run tabs running an agent).

### 4.2 Drag

1. **Press.** The chip darkens slightly (`fade`). Nothing moves yet.
2. **Lift**, after 3 pt of movement in any direction (today: 4 pt, horizontal only). The chip
   scales to 1.03 with a soft shadow drawn from the capsule's own path, so there's never a box
   around it (the dark-box bug was a shadow without a path). `snappy`.
3. **Follow.** The chip follows the pointer 1:1 along the strip. Vertically it follows with
   rubber-band resistance, so a pull visibly stretches before it breaks free. Neighbours slide
   aside as its centre crosses theirs (`snappy`).
4. **Tear.** Past the strip's edge plus 24 pt (measured from the strip, not the press point),
   the chip **becomes** the preview in one `smooth` morph: the capsule widens into a large
   rounded card showing the file or terminal, anchored under the pointer at the point you
   grabbed. It's the same layer throughout, not a system drag image and a second window. The
   card is big, as Rex's is (the owner, 2026-10-30): the window's proportions at 45% of its
   size, between 420 and 640 pt wide, so it reads as the window it will become.
5. **Over another place.** Over the strip again, it morphs back into a chip and a slot opens.
   Outside the window, the card grows a little more (55%) and takes the window's top row, to say
   "a window lands here".
6. **Drop.** In the strip: the chip settles into its slot (`snappy`), and the order is saved.
   Outside: the card expands into the new window's frame (`smooth`), and the window takes over
   from it, so the window visibly comes out of the tab.

Escape during a drag sends everything back where it started (`snappy`).

### 4.3 Rename (Run)

Double-click a Run tab's title, or choose Rename from its menu. The title becomes a field in
place, the same width, all text selected. Return commits, Escape cancels, and an empty name
returns to the automatic one (the running command). Names are remembered with the track's tab
shape. Make's tabs are files and keep their file names.

### 4.4 Insert and close

- **Insert:** the new chip grows from zero width at its slot while it fades in, and neighbours
  make room (`smooth`). New tabs arrive at the end, or after the active tab when opened from it.
- **Close:** the chip fades and narrows to nothing; neighbours close the gap (`snappy`). Closing
  the active tab activates the one to its right, else its left, as browsers do.
- The strip still hides with one tab; its arrival and departure use `fade`.

## 5. Update UI

Sparkle stays for the work it does well (finding, downloading, verifying the signature,
installing). Side replaces its windows with its own user driver (`SPUUserDriver`).

### 5.1 The pill

An update is a **glass pill in the floating bar**, beside search, made with the same glass
capsule as the bar's other pieces. It grows out of the bar (`smooth`) and changes in place:

| Stage | Pill | Action |
|---|---|---|
| Available | "Update to 0.3.0" | click: a popover with the release notes, **Install and Relaunch**, **Later** |
| Downloading | a progress ring and "Downloading 42%" | click: the popover with Cancel |
| Preparing | the ring, indeterminate, "Preparing" | |
| Ready | "Relaunch to Update" | click: relaunches; quitting also installs |
| Failed | failed dot, "Update failed" | click: the reason and Try Again |

- **Later** hides the pill until the next launch or the next version.
- A check you ask for ("Check for Updates…") that finds nothing shows "Side is up to date" in
  the same place for 3 s, then the pill leaves.
- Sparkle's second-launch permission prompt goes: Side checks automatically by default, as the
  privacy page already says, and Settings › Updates keeps the switch. (The page says the switch
  is in Settings › General; one of the two changes to match.) Nothing downloads until you click.
- The release notes popover renders the same Markdown as the appcast notes, in the reading
  type of Markdown previews.

### 5.2 Why this and not a window or a notification

A window interrupts and asks for a decision at a bad moment. A system notification is easy to
miss and can't show progress. The pill is visible but never in the way, shows progress where
you clicked, and is the same component as the rest of the bar.

## 6. Shared components

Each is built once and used by every surface named here. Anything new goes into this table
first.

| Component | Used by |
|---|---|
| `TabStrip` (§4) | Make, Run |
| `GlassPill`: a glass capsule with an optional leading dot or ring, a title, and grow and shrink | the bar's track and stage pieces, the update pill, Think's docked pills |
| `ProgressRing`: 12 pt, determinate or indeterminate, `label` α .6 | the update pill, Run's task chip |
| `StatusDot`, `StatusLabel` (§3.2) | everywhere a state is shown |
| `AttentionCenter` (§3.3) | sound, the Dock badge, notifications |

## 7. Build order

Each step lands with tests and is usable alone.

1. **Tokens.** The three springs, Reduce Motion as crossfade, `StatusDot` at one size, the word
   table, and the compliance check (it will list the sites step 4 fixes).
2. **TabStrip.** Extract the shared component from Make and Run, with no visual change and the
   reorder save fixed, then the new drag and tear-out (§4.2), rename (§4.3), insert and close
   (§4.4).
3. **Status pass.** Every site in the survey onto `StatusDot` and the words; explorer git marks
   as letters; the unsaved and unseen dots.
4. **Motion sweep.** Stage switch crossfade, explorer and palette on `smooth`, the bare
   `animator()` sites.
5. **AttentionCenter and sound**, with the two settings.
6. **Update UI:** the user driver and the pill.
7. **Notifications**, on AttentionCenter.

## 8. Decisions (the owner, 2026-10-30)

1. **Sound:** system sounds; no custom sounds for now. Finished is off by default.
2. **Tear-out preview:** big, as Rex's: 45% of the window, 420 to 640 pt wide (§4.2).
3. **Update pill:** beside search in the bar.
4. **Make tabs:** not renameable; they're file names.
5. **Motion:** "motion is for change of place" replaces "nothing else moves", with a fluid,
   slightly springy feel and velocity carried from gestures (§2.2).
