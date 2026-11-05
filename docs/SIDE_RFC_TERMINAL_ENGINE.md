# Terminal on libghostty-vt, drawn by Alloy

Status: proposed (2026-11-04). Decisions pending, listed at the end. Nothing built yet. Phase 0
is a validation gate: if it fails, this RFC changes before any of Phase 1 is written.

## Why

The Terminal stage is where Side is used: Claude Code, several at once, in Terminal tabs. Its
terminal is SwiftTerm, which parses and draws on the main thread with CoreText. The benchmarks
(`docs/SIDE_TERMINAL_BENCHMARKS_2026-11-03.md`) measured that ceiling: SwiftTerm handles 4–17×
less output than Ghostty's emulator, at six streaming sessions it kept the main thread busy
about a fifth of the time, and an ultrawide full-screen frame costs it 10–11 ms (more than a
120 Hz frame).

## Where it stands today

- **The keeper already runs libghostty-vt** (0.4.0, `Packages/SideSessions`): each terminal's
  PTY lives in a keeper process with a headless libghostty-vt terminal, so sessions outlive Side.
  It's pinned at Ghostty `c7f68a7`, built by `scripts/build-ghostty-vt.sh`.
- **The screen is still SwiftTerm.** The keeper sends bytes over its socket, and SwiftTerm in
  Side parses them again and draws them. On reattach the keeper's VT-formatted snapshot is fed
  into a fresh SwiftTerm terminal.
- **Only `SIDE/TerminalViewController.swift` imports SwiftTerm.** Everything else goes through
  `SideTerminalView` and `TerminalViewController`, so the swap has one seam.

## How sure we are: what the benchmarks settled and what they didn't

The question is whether C (libghostty-vt + Alloy) is enough, compared with D (full libghostty:
Ghostty's own emulator, threads and Metal renderer), and whether it can beat it.

**Settled, and still accurate.** The benchmarks pinned the same Ghostty commit and the same
SwiftTerm (1.20.0) Side ships today, so none of this has gone stale:
- **The emulator.** C and D run the same parser, so neither has an edge there. Both leave
  SwiftTerm 6–21× behind with no PTY or window, with identical screens on every workload.
- **CPU and memory with many sessions.** C won outright: 0.79 s of CPU for six streaming
  sessions against D's 1.40 s, and 178 MB at 24 sessions against D's 750 MB. That's structural,
  not tuning. D gives every session a full surface with its own framebuffers, hidden or not; C
  draws only the session on screen.
- **Frame cost.** Alloy draws a 440×96 frame in about 2 ms. libghostty-vt's render state reports
  exactly which rows changed, so a one-row change costs C almost nothing.
- **Latency against D.** C already beats D: 13.7 ms median against 21.9 ms. D's latency is
  Ghostty's own vsync-paced design, checked two ways.

**Not settled:**
1. **Latency against Side today.** SwiftTerm's view is still the quickest (6.8 ms median). C's
   frames take under 0.5 ms; the gap is in how a Metal frame reaches the screen. Two fixes were
   tried; the promising ones (`CAMetalDisplayLink`, presenting at a chosen time, a render
   thread) weren't. Going from 7 ms to 13 ms is a regression in the one thing typing feels.
2. **Throughput against D.** D is 6–63% ahead on bulk output. The write-up blames the lock C's
   reader and renderer share, but the prototype already holds it only for
   `ghostty_render_state_update`, as libghostty's render API intends. The cause is a hypothesis.
   The likelier suspects are the reader's slice-and-yield handoff (`FairLock`) and drawing on the
   main thread's schedule.
3. **Real output.** Every workload is synthetic. The `tui` one is shaped like Claude Code, not
   recorded from it.
4. **Side as it is now.** The benchmarks predate the keeper. Every setup owned its PTY directly.
   Side today goes PTY → keeper (libghostty-vt) → socket → SwiftTerm, so each byte is parsed
   twice, and that path was never measured. For D it matters more: full libghostty starts and
   owns its own process, so attaching it to a keeper means running a small relay as its command,
   one more hop that nothing has measured.
5. **The renderer is an afternoon's prototype.** It has no selection, IME, cursor styles,
   ligatures, accessibility or mouse. Its numbers are a floor for Alloy; Ghostty's are a mature
   reference.
6. **One machine, no external display.** Ultrawide was offscreen only, and D wasn't in that test.

**Can C beat D?**
- **CPU and memory:** it already does, by design.
- **Keypress latency:** it already does. The target is SwiftTerm's 7 ms, not D.
- **Throughput:** at best a tie, since the parser is the same. Bulk output already runs near
  the PTY's 200 MB/s ceiling, so the win there is closing the gap, not passing D.
- **What D has that C must build:** years of renderer polish and features. Ghostty's renderer
  gives font fallback, ligatures, cursor styles, kitty images and selection for free. That's the
  real cost of C, not speed.

D also fits Side worse:
- its embedding API isn't supported for apps other than Ghostty;
- it starts commands through `/usr/bin/login`;
- it can't share Alloy's text engine with the Editor;
- it fights the keeper design, which already owns the PTY.

## Phase 0: validate before building

Each item adds to the benchmark harness (`Benchmarks/Terminal`) and re-runs it; results go into
the benchmarks write-up as a dated section.

1. **A real Claude Code capture.** Record raw bytes from Side's `onRawDataReceived` hook over a
   long working session, with timing. Replay it through A, C and D, both at full speed and at
   recorded pace.
2. **The keeper in the loop.**
   - A′: Side today, PTY → keeper → socket → SwiftTerm.
   - C′: the same with libghostty-vt + Alloy as the client.
   - D′: full libghostty running a relay to a keeper, if the relay works at all.
   - Measured on throughput, CPU, six sessions and latency.
3. **Close the latency gap.** Try, each measured separately:
   - `CAMetalDisplayLink`;
   - presenting with `present(afterMinimumDuration:)` / at a target time;
   - a render thread of its own;
   - one drawable in flight while idle;
   - keeping ProMotion at full rate while typing (`CADisplayLink` preferred frame-rate range).
4. **Find the throughput gap's cause before fixing it.** Profile C against D on `ascii` and
   `scroll`, then try the obvious candidates:
   - a reader that parses whole reads without yielding;
   - a render-state update off the main thread;
   - a double-buffered render state.

**The gate.** On the real capture, with the keeper in the loop, C′ must meet all three, or this
RFC is revisited (D′, or a hybrid) before Phase 1:
- **Keypress latency:** a median at or below A′'s, and a p95 under 17 ms.
- **Throughput:** within 15% of D′ (or of D, if D′ can't be built).
- **Load:** no worse than the benchmarks' C on CPU and memory at six and 24 sessions.

## The design (if Phase 0 passes)

**Where the code lives:**
- **`AlloyTerminal`, a new module in Alloy (open source).** A grid renderer and view that know
  nothing about the emulator. They take a grid of cells (codepoints or graphemes, style, wide and
  spacer flags) with dirty rows, plus the cursor, selection and marks. They draw with Alloy's
  glyph atlas and quad shaders, the same ones the Editor uses, so the two look alike. Alloy stays
  free of Zig and Ghostty.
- **`SideTerminal`, a new package in Side.** The Swift wrapper over libghostty-vt's C API, shared
  with the keeper, which uses it for its headless terminal. It feeds the render state into
  `AlloyTerminal`'s grid. The one wrapper is also where the C API's instability is contained:
  pin a commit, upgrade deliberately.

**Threads:**
- A reader thread parses socket bytes into libghostty-vt.
- A frame takes the terminal's lock only for `ghostty_render_state_update`, then builds quads
  without it.
- Drawing is wherever Phase 0 found the lowest latency.
- Hidden tabs parse and never draw; showing one builds a frame (under 1 ms at 200×60).

**Reattach** moves to libghostty-vt's binary snapshot (`ghostty_snapshot_encode`), restored
straight into the client's terminal. That's phase 4 of `docs/SIDE_RFC_SESSION_RESTORE.md`, which
was waiting for this. The VT-replay path and its per-mode tests go away.

**Command tabs** (an agent's `terminal/create`, the debugger's program terminal) stay in Side's
process, as now. Side gets its own small PTY spawner in place of SwiftTerm's `LocalProcess`, with
`childfd` and `shellPid` for the debugger's TTY handoff.

### What has to work before Terminal switches over

Today's features and where each comes from:

| Feature | Today | With libghostty-vt + Alloy |
| --- | --- | --- |
| Key input, option-as-meta, kitty keyboard | SwiftTerm | `key/encoder.h` |
| IME (marked text) | SwiftTerm's `NSTextInputClient` | Side's: the view implements it, with marked text drawn inline |
| Selection and copy | SwiftTerm | `selection.h`; drawing and dragging in `AlloyTerminal` |
| Paste, bracketed | SwiftTerm, Side for drops | `paste.h` |
| Mouse reporting | SwiftTerm | `mouse/encoder.h` |
| Focus reports | SwiftTerm | `focus.h` |
| Links: OSC 8, detected URLs, Side's file links into Editor | SwiftTerm, Side's `requestOpenLink` | OSC 8 from the cells' hyperlink; URL detection Side's own; file links unchanged |
| Bell, title, OSC 7 | SwiftTerm delegates | libghostty-vt callbacks (the keeper uses them already) |
| OSC 133 marks, agent OSC 6973, DEC 2031 | Side's own byte scans | Unchanged at first, since they sit on the byte stream; 2031 can move to `color_scheme.h` |
| Theme, palette, font size | `installPalette`, `font` | The renderer's palette and Alloy's font settings |
| Scrollback and Side's scroll thumb | SwiftTerm's view, reverse-derived | Read directly from the terminal; the thumb gets real numbers |
| Accessibility (one text area, visible rows) | Side's code over `getLine` | The same, reading the render state's rows |
| Drag and drop of files and images | Side's code | Unchanged |
| Tab drag preview | `cacheDisplay` of the view | A frame drawn offscreen by the renderer (Metal layers don't cache) |
| Cursor styles and blink | SwiftTerm | `AlloyTerminal` |
| Wide characters, emoji, flags, combining marks | SwiftTerm | Grapheme clustering (mode 2027) on, as in the keeper |

**New for free:** find in the terminal (`search.h`); the 10,000 lines of scrollback the keeper
already keeps, which SwiftTerm couldn't show without slowing down.

**Later, not for the switch:** kitty graphics (`kitty_graphics.h`); ligatures.

**Known regression:** Arabic draws one letter per cell, unjoined, as Ghostty does. SwiftTerm
shapes it.

**Tests to port:**
- `AccessibilityTests` (the terminal's text area);
- `SessionKeeperTests` (reading the screen);
- `TerminalCaptureTests` (titles);
- `AppearanceTests` (palette type);
- the UI test hooks `typeForTesting` and `terminalBackgroundForTesting`;
- the third-party notices check, which keeps SwiftTerm until it's removed.

## Phases

0. **Validate** (above), with the gate.
1. **`SideTerminal` and `AlloyTerminal`, behind a setting.** Draw, type, scroll, resize, theme and
   reattach by binary snapshot. On in the owner's builds first, SwiftTerm the default for
   everyone else.
2. **Parity**: the table above, then the ported tests. UI checks on screen in light and dark,
   with Claude Code, vim, lazygit and htop.
3. **The default**, with SwiftTerm kept one release as the fallback setting.
4. **SwiftTerm removed**: the dependency, its build-plugin flag (`-skipPackagePluginValidation` in
   test, budgets and release scripts) and its notices.

Ghostty's MIT notice is missing today, though the keeper has linked libghostty-vt statically
since 0.4.0. It goes into the third-party notices now, not with this work.

Alloy gets its own render and terminal benchmarks, compared against itself over time, as agreed
on 2026-11-03.

## Decisions pending

1. **The Phase 0 gate**, as written, or stricter (for example, latency below A′'s, not equal to
   it).
2. **`AlloyTerminal` in Alloy (open source), or in Side.** Recommended: in Alloy. It keeps Alloy
   one text engine and needs nothing from Ghostty.
3. **The Arabic regression**: accept it, as Ghostty does, or shape right-to-left runs with
   CoreText later.
4. **The fallback**: keep SwiftTerm as a setting for one release, or switch outright once parity
   passes.
