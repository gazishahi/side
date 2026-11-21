# With Side's own reader (2026-11-20, night)

The full suite again (`scripts/run-features.sh`, then `scripts/run-throughput-sources.sh`), after
f0679aa: Side's PseudoTerminalProcess reads its PTY as Ghostty does (a gather thread, batches of up
to 64 KiB, the writer's refill gaps bridged), and setup E reads through it, fed as Side's surface
feeds it: the reader's thread, then the main thread, then a parse queue (2585a44). Everything else
as in `../2026-11-20-rerun/` (M3 Pro, 120 Hz, Fira Code 13 pt, 200×60, release builds, one
interleaved pass; load 4.0–4.5 through it, `load.txt`).

This supersedes the E columns of `../2026-11-20-rerun/`: there E read through the harness's
blocking reader, not Side's. A, C and D are unchanged (C still reads through the harness's
reader, so E against C is no longer a like-for-like comparison of renderers).

Features each setup had on: as in `../2026-11-20-features/NOTES.md`.

## Throughput (MB/s, median of 5, range; process CPU)

| | A | C | D | E | D ahead |
|---|---|---|---|---|---|
| ligatures | 9.5 | 127.7 | 162.7 [162–166] / 1.05 s | 155.3 [149–165] / 0.84 s | 5% |
| underlines | 17.4 | 156.7 | 193.1 [181–194] / 0.89 s | 185.3 [185–190] / 0.68 s | 4% |
| boxes | 6.4 | 247.6 | 259.7 [253–265] / 0.59 s | 250.0 [235–267] / 0.47 s | 4% |

| views | D | E | D ahead |
|---|---|---|---|
| ligatures, scrolled back | 165.1 [160–170] / 1.03 s | 163.3 [156–173] / 0.79 s | 1% |
| ascii (36 MB), scrolled back | 208.0 [199–226] / 0.37 s | 202.1 [180–226] / 0.31 s | 3% |
| boxes, all selected | 257.0 [242–278] / 0.59 s | 249.4 [242–253] / 0.47 s | 3% |
| tui (16 MB), all selected | 165.4 [162–205] / 0.18 s | 154.0 [144–186] / 0.14 s | 7% |

Before the reader (`../2026-11-20-rerun/`), D was ahead by 26–44% on the same rows.

## Where E's throughput goes now (`gap.jsonl`)

| MB/s, median of 5 | D | E | E, drawing off |
|---|---|---|---|
| ligatures | 158.0 | 158.4 | 166.7 |
| underlines | 193.9 | 189.7 | 198.7 |
| ascii | 214.3 | 193.3 | 207.2 |

- With the reader no longer the limit, drawing costs E 5–7% of its throughput.
- E ties D on ligatures in this pass and trails by 2% on underlines and 10% on plain text, where
  parsing is cheapest and the rest of the path shows most.

## CPU

- **Process CPU: E below D in every run**: ligatures 0.84 against 1.05 s, underlines 0.68 against
  0.89, boxes 0.47 against 0.59, ascii scrolled 0.31 against 0.37. D's frame count still isn't
  known, so this says nothing about whose renderer is cheaper.
- **Main-thread CPU: E 0.006–0.013 s per run, D 0.004–0.009.** Side's surface passes each batch
  through the main thread on its way to the parser, so E's main thread now does a little more than
  D's. The earlier "E's main thread does nothing" (≤0.004 s) was setup E feeding the parser from
  the harness's reader thread, not Side's path; it no longer stands. It is about 1% of a run either
  way.

## Behind Side's session keeper (`keeper.jsonl`, MB/s, median of 3)

| | old keeper | new keeper (7be08ba) |
|---|---|---|
| E, ligatures | 86.7 | 103.1 |
| E, ascii | 95.3 | 123.5 |
| D, ligatures | 79.3 | 89.7 |
| D, ascii | 91.6 | 113.9 |

D behind the relay is not how Ghostty ships; these rows compare keepers. In Side, a terminal kept by
its keeper (the default) reads at these rates; a command tab, or a shell with keepers off, reads at
the rates above.

## Frame cost and the reader on its own

Frame cost (`framecost.jsonl`) is unchanged from `../2026-11-20-rerun/` (it doesn't involve the
reader): a ligature-font frame at 440×96 is 2.43 ms. `reader.txt`: Ghostty's loop 187.2 MB/s,
the blocking loop 145.1, as before.

## What can be said

- Can: with Tier 1's features on and Ghostty's reading design, Side's engine reads, parses and
  draws within 1–10% of Ghostty on these workloads (ties within run-to-run range on several),
  using 8–24% less process CPU.
- Can: Side's renderer, with its features, costs 5–7% of its throughput.
- Can't: that Side's renderer is cheaper than Ghostty's (D's frames unknown), or that Side's main
  thread does less than Ghostty's (it does slightly more).
- Can't: a single Side-against-Ghostty number as users see it: Side's kept terminals read through
  the keeper (103–124 MB/s); Ghostty reads directly.
- Still to do: keypress latency on the display clock after today's changes (needs Terminal.app).
