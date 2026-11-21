# Six sessions, with Side's own reader (2026-11-21)

`--mode sessions --sessions 6`: six terminals, the first shown and the rest hidden, each
streaming the tui burst (13 KB, 20 times a second for 10 seconds), 200×60, Menlo 13. Three
interleaved rounds, medians with ranges; load 3.2–3.9. Same machine as the other results.

Setup E now reads every session through Side's PseudoTerminalProcess (Ghostty's reading design,
f0679aa) and feeds it as Side's surface does: the reader's thread, then the main thread, then the
session's parse queue; only the shown session draws. Before this, its sessions mode read through
the harness's blocking reader and fed the parser from that thread, so its main-thread figure
(0.001 s in `../2026-11-20-latency/`) wasn't Side's. `TERMBENCH_E_READER=harness` keeps the old
path.

| | process CPU | main-thread CPU | footprint | frames drawn |
|---|---|---|---|---|
| A, SwiftTerm | 2.85 s [2.77–2.89] | 2.39 s [2.31–2.42] | 78 MB | – |
| C, the Phase 0 prototype | 0.58 s [0.56–0.59] | 0.20 s [0.20–0.20] | 176 MB | 208 |
| D, Ghostty | 0.95 s [0.93–1.02] | 0.23 s [0.23–0.24] | 321 MB | – |
| E, Side's engine | 1.22 s [1.22–1.28] | 0.108 s [0.103–0.109] | 177 MB | 410 |

- E's main thread does about half of Ghostty's work (0.108 s against 0.23 s), and E uses 45% less
  memory (177 MB against 321).
- E uses about 28% more process CPU than Ghostty here. It drew 410 frames for the one shown
  session (it draws per burst on its own thread; C draws on display ticks, 208); Ghostty's frame
  count isn't known, so how much of the difference is drawing can't be said.
- This replaces the six-sessions rows of `../2026-11-13-tier1/` and `../2026-11-20-latency/`
  for E. Those had E at 1.11 s against D's 1.48 s, under more load and with the harness's reader;
  E's lower process CPU there doesn't stand.
- C still reads through the harness's reader, so E against C isn't like for like.
