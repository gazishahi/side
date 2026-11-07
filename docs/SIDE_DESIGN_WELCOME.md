# The welcome: Side's onboarding

Status: built (2026-11-07). Agreed 2026-11-07: the owner took every recommendation, asked for a
premium, Apple-like onboarding with thoughtful motion and demos, chose the title type (SF,
medium, set tight; never a serif) and no decorative gradient, and asked for a quick replay in
debug builds.
Symbols: `WelcomeWindowController`, `WelcomeViewController`, `WelcomeStageShowcase`, `WelcomeDemo`, `OtherEditorRecents`, `FirstRun`.

Replaces the first-run sheet of Direction 02 §6 (three steps, shown only with no recent project
and no agent installed, so most people never saw it; its "Create a track" step predated tracks
from git).

## When

- **A new install:** no project in Side yet, and not seen. Someone with projects already is marked
  as having seen it. Closing it at any point counts as seen.
- **Help › Welcome to Side** shows it again, any time. Help is a menu of its own now (the audit's
  UX-13 had none), so macOS adds its search field.
- **Debug builds:** Help › Reset and Show Welcome (⌃⌥⌘W) forgets it was seen and starts again from
  the first page.
- `-SideForceFirstRun YES` shows it at launch without recording it.

## The window

One size (900 × 620), its own window rather than a sheet, the canvas tone in both appearances
with nothing behind the content. Title bar hidden; close only. A bar along the bottom: Back, the
page dots (the current page a longer capsule; a dot goes to its page), and the one primary
button in the accent ("Get Started", "Continue", "Start Using Side"). Return continues, ← and →
page, Escape closes.

**Type:** titles in `DS.Text.display`, SF at 36 pt (44 on the first page), medium, tracked
−2.8 %; subtitles SF 15 in the secondary colour. Body text is Side's own roles.

**Motion** (all `DS.Motion`): a page slides 60 pt and fades as the next comes in from the side
it's on, on the smooth spring; its title, subtitle and content then rise in 70 ms apart. The
app icon lands from 82 % with the spring's overshoot. Under Reduce Motion nothing moves:
pages cut, demos show their finished picture, still.

## The pages

1. **Welcome to Side.** The icon, the name, one line: the editor built around your agents and the
   terminals they run in.
2. **Five stages, one window.** The five stages listed with their glyph, a line each and their
   shortcut, beside a miniature Side window playing that stage: a file being typed (in the
   current editor theme's colours), a conversation whose answer draws a diagram, a diff read and
   committed, Claude Code at work in a Terminal tab whose dot turns from working to done, and the
   branches board filling in. The bar along the miniature's bottom is Side's own, its capsule
   springing between stages. The list moves on by itself every 5.5 s, a bar filling under the
   current stage; a click picks one.
3. **Side remembers your work.** Three cards, each a short loop: every branch is a track (branches
   drawn off a line and named), terminals keep running (the window goes, the terminal carries
   on), one chat in two places (a conversation carried from Terminal to Agent).
4. **Make it yours.** Accent swatches, the keymap (Xcode, VS Code, JetBrains, each with two of its
   real chords), the editor theme (Side, GitHub, One Dark, drawn as a few lines of their own
   code), Import a VS Code Theme…, and the interface-follows-theme switch. Each applies as it's
   picked; the editor and terminal preview beside them, the welcome's own button and every
   accent on screen follow at once.
5. **Bring your agent.** Each agent Side knows, its mark, and Ready or its install command with
   Copy. Side never installs anything. The line under it names the agent new conversations use.
6. **Open a project.** Open Folder… and New Project… as two tiles, and folders recently open in
   VS Code, Zed and Cursor, read from their own records (read only, immutable; local folders that
   still exist), the editors taking turns. Opening one closes the welcome onto the project.

## Demos

Drawn, not recorded (`WelcomeDemos.swift`): layers made of the design tokens, scripted with
`at(_:)` and looped. They stay sharp at any scale, follow light and dark, the accent and the
editor theme, and add nothing to the download. Each stops when its page goes.

## Checks

- `scripts/uitest/check-welcome.sh`: every page in dark and light, mid-move and settled, for
  looking at; Help shows it, the pages move, closing clears it.
- `StageCompositionTests`: when it shows; the other editors' recent folders read from sample
  databases.
