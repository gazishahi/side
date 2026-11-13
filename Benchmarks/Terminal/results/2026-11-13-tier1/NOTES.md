# Tier 1 done: Side's engine (setup E) against A, C and D (2026-11-13)

Setup **E** is new: Side's shipping terminal engine, SideTerminal (libghostty-vt, parsed on the
reader's thread) drawn by AlloyTerminal with every Tier 1 feature of
`docs/SIDE_RFC_TERMINAL_ENGINE.md` (run shaping and ligatures, drawn box/block/legacy symbols,
underline styles, cursor styles and blink, highlights, synthetic styles, sRGB color, minimum
contrast). It builds from this repository's packages (`TermBenchE/`), so unlike A–D it isn't
reproducible from the public harness until Alloy is published. **C** is the Phase 0 prototype
renderer over the same emulator; **A** is SwiftTerm as Side ships it; **D** is Ghostty
(`c7f68a7`). Same machine as earlier results (M3 Pro, 120 Hz), Menlo 13, release builds,
`run-all.sh` and `run-sessions-latency.sh`, latency on the display clock.

## Throughput (MB/s, median of 3)

| 200×60 | A | C | D | E |
|---|---|---|---|---|
| ascii | 34.3 | 118.2 | 183.2 | 113.8 |
| colors | 13.2 | 127.7 | 171.8 | 125.1 |
| unicode | 6.4 | 86.8 | 135.5 | 89.0 |
| cursor | 11.4 | 46.7 | 55.3 | 47.5 |
| tui | 22.9 | 146.4 | 155.2 | 131.3 |
| scroll | 25.1 | 111.9 | 146.2 | 108.8 |

80×24 shows the same order. E is within about 10% of C; its features don't cost throughput.

## Frame cost (ms, median; CPU of a full frame / its GPU time)

| | A | C | E |
|---|---|---|---|
| tui 200×60 | 4.74 / – | 0.15 / 0.10 | 0.48 / 0.10 |
| ascii 200×60 | 3.47 / – | 0.45 / 0.11 | 1.71 / 0.10 |
| ascii 440×96 | 10.76 / – | 1.40 / 0.31 | 4.35 / 0.40 |

E's CPU per full frame is about 3× C's: shaping each row as a run (CoreText) is most of it, which
is why plain text costs most. GPU time is the same. Side's default font has no ligatures, so
skipping shaping for fonts without them would bring plain text back near C (not done yet).

## Keypress latency (ms, display clock, 200×60; median of 3 runs' medians, 60 keys each)

| | A | C | D | E |
|---|---|---|---|---|
| idle | 16.1 | 13.8 | 24.2 | 14.8 |
| 5 sessions' load | 16.7 | 14.4 | 22.3 | 14.0 |
| p95, idle | 23.5 | 17.8 | 33.7 | 18.2 |

E keeps C's latency. D's extra ~8 ms is Ghostty's extra frame (see `../validation/` and the
note to Ghostty's author); without it D measured 16.6 ms.

## Six sessions (tui-burst, 200×60; median of 3)

| | process CPU | main-thread CPU | footprint | frames drawn |
|---|---|---|---|---|
| A | 3.27 s | 2.56 s | 69 MB | – |
| C | 0.76 s | 0.30 s | 171 MB | 210 |
| D | 1.44 s | 0.37 s | 318 MB | – |
| E | 1.11 s | 0.001 s | 173 MB | 445 |

E draws every burst on its own render thread (445 frames to C's 210, which draws on the display
link's ticks), so more of its CPU is drawing; its main thread does nothing.

## What these numbers can't say yet

- The RFC's rule 4: the workloads above don't exercise the new features (ligature-heavy code in
  a ligature font, box drawing, styled underlines, selection while streaming, a scrolled-back
  viewport). Until those run, with the same font in D and E, no claim about the renderer's cost
  against Ghostty's.
- Short runs: at 16 MB, a run takes 0.1–0.4 s, and E's fixed start-up (fonts, the first
  shaping) shows: tui at 200×60 on a single run measured 40 MB/s before the three-run medians
  above. An 8× workload (134 MB) gave E 226–232 MB/s against C's 236–258.
- The first suite pass's latency and sessions failed (Terminal had lost Screen Recording; E's
  sessions source was let go of, a harness bug, fixed). The tables use the rerun.
