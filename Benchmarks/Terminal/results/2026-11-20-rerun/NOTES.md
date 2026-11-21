# Rerun after the shaping cache and the keeper's reader (2026-11-20, evening)

The RFC's rule 4 suite (`../2026-11-20-features/`) again, after two changes, plus a breakdown of
where Side's throughput goes. Same machine (M3 Pro, 120 Hz), Fira Code (FiraCodeNFM-Reg, 13 pt),
200×60 unless stated, release builds, all parts in one interleaved pass
(`scripts/run-features.sh`, then `scripts/run-throughput-sources.sh`). The pass started once the
one-minute load fell below 3.5; run-to-run spreads were tight (see the ranges).

What changed since the first pass:

- **a5c9ceb**, AlloyTerminal: text is shaped and cached a word at a time instead of a row at a time
  (streaming rows never repeat; words do).
- **7be08ba**, Side's session keeper: while a client is attached, its PTY reader bridges a flood's
  refill gaps as Ghostty's reader does (non-blocking reads, 16 retries, a 1 ms wait).

Setups as before: **A** SwiftTerm, **C** the Phase 0 prototype renderer, **D** Ghostty
(`c7f68a7`), **E** Side's engine (SideTerminal + AlloyTerminal). Features each had on: as in
`../2026-11-20-features/NOTES.md` (D and E draw ligatures, underline styles, strikethrough,
overline, drawn box characters and selection; C none of these; A no ligatures).

## Throughput (MB/s, median of 5, range; process CPU for the run)

| | A | C | D | E |
|---|---|---|---|---|
| ligatures | 9.4 / 7.49 s | 127.9 [126–135] / 0.54 s | 161.9 [160–164] / 1.06 s | 125.0 [121–129] / 0.59 s |
| underlines | 17.4 / 4.40 s | 156.6 [154–157] / 0.43 s | 195.7 [188–197] / 0.87 s | 152.2 [144–155] / 0.47 s |
| boxes | 6.5 / 10.80 s | 255.6 [247–259] / 0.28 s | 260.9 [258–266] / 0.59 s | 249.8 [234–258] / 0.32 s |

| views | D | E |
|---|---|---|
| ligatures, scrolled back | 160.3 [156–164] | 127.1 [127–131] |
| ascii (36 MB), scrolled back | 209.7 [187–232] | 145.3 [145–145] |
| boxes, all selected | 256.7 [249–261] | 248.7 [227–250] |
| tui (16 MB), all selected | 165.1 [164–170] | 153.8 [142–187] |

Main-thread CPU: E 0.001–0.004 s, D 0.003–0.009 s, C ~0.05 s, A 3.6–9.7 s. Every scrolled run
ended still scrolled back (`views.txt`).

- D leads E by 30% on ligatures, 29% on underlines, 26–44% scrolled back, 7% on the tui, 3–4% on
  boxes. E is within 2–3% of C on every workload, though C draws none of these features.

## Where E's throughput goes (`gap.jsonl`, `reader.txt`)

| MB/s, median of 5 | D | E | E, drawing off | C-reader port, blocking | C-reader port, Ghostty's |
|---|---|---|---|---|---|
| ligatures | 162.0 | 124.9 | 129.3 | 143.7 | 183.8 |
| underlines | 194.4 | 149.2 | 155.9 | | |
| ascii | 212.1 | 150.8 | 152.4 | | |

- **Drawing costs E 1–5% of its throughput** (E against E with no frames at all).
- **The rest of the gap is the PTY reader.** E's harness reads with a blocking read-then-parse loop.
  `Reader/ptyread` puts libghostty-vt behind each reader with nothing else: Ghostty's own loop
  (`Exec.zig`, ported exactly) reads and parses ligatures.bin at 183.8 MB/s, a blocking loop at
  143.7: 28% apart, the size of the D–E gap. Without parsing: 188.2 against 126.2. Ghostty's loop
  costs more CPU (0.68 s against 0.44 s).
- So E's renderer, with its features on, is not what Ghostty's lead comes from: E's engine minus
  its drawing runs at 129–156 MB/s; D leads that by 25–39%, about what the reader alone accounts for (28% on ligatures).

## Behind Side's session keeper (`keeper.jsonl`, MB/s, median of 3)

In Side every terminal reads through its keeper (here through `Keeper/relay.c`, the same hop for
both setups). Old keeper (before 7be08ba) against new:

| | old keeper | new keeper |
|---|---|---|
| E, ligatures | 94.2 | 107.4 (+14%) |
| E, ascii | 97.2 | 116.8 (+20%) |
| D, ligatures | 80.1 | 89.9 |
| D, ascii | 93.6 | 108.4 |

D behind the relay is not how Ghostty ships (it reads its own PTY), so these rows compare keepers,
not engines. Keypress echo through the keeper was unchanged by 7be08ba (median 0.28–0.34 ms either
way); an attached flood from a writer slower than the keeper costs about 20% more keeper CPU.

## Frame cost (ms, median; a full frame's CPU / GPU; offscreen, C and E only)

| | C | E now | E, first pass |
|---|---|---|---|
| ligatures 200×60 | 0.55 / 0.11 | 1.06 / 0.11 | 3.88 / 0.19 |
| underlines 200×60 | 0.55 / 0.12 | 1.04 / 0.14 | 2.96 / 0.20 |
| boxes 200×60 | 0.79 / 0.18 | 2.16 / 0.19 | 2.63 / 0.19 |
| ligatures 440×96 | 1.66 / 0.34 | 2.46 / 0.34 | 7.25 / 0.58 |
| underlines 440×96 | 1.53 / 0.35 | 2.52 / 0.38 | 5.60 / 0.50 |
| boxes 440×96 | 1.24 / 0.40 | 2.83 / 0.40 | 3.35 / 0.40 |

A ligature-font frame at 440×96 went from 7.25 to 2.46 ms (the 120 Hz budget is 8.3). C draws none
of the features. D's frame cost can't be measured this way.

## What can be said, and what can't

- Can: with Tier 1's features on, Side's renderer costs it 1–5% of throughput, and its engine
  stays within 3% of the feature-less prototype. Ghostty's 26–44% throughput lead on these
  workloads comes from how it reads the PTY, shown with a standalone reproduction of both readers.
- Can: E's main thread does nothing while output streams (≤0.004 s per run), against Ghostty's
  0.003–0.009 s.
- Can't: that E's renderer is cheaper than Ghostty's. E used less process CPU in every run, but
  D's frame count isn't known.
- Can't: a Side-against-Ghostty throughput number as users see it. Side reads through its keeper
  (107–117 MB/s now); Ghostty reads its PTY directly (162–212).
- Not yet done: latency on the display clock after these changes (needs Terminal.app).

## After E's own reader (f0679aa, later the same evening)

Side's PseudoTerminalProcess (a terminal reading its own PTY: a command tab, a shell with keepers
off) now reads as Ghostty does, and setup E reads through it, fed as Side's surface feeds it
(2585a44). A 3-round interleaved check, not the full suite (load 4.2–4.6), MB/s and process CPU:

| | D | E, Side's reader | E, harness reader |
|---|---|---|---|
| ligatures | 156–158 / 1.09 s | 155–158 / 0.87 s | 125–129 / 0.57 s |
| underlines | 178–192 / 0.94 s | 163–185 / 0.72 s | 138–149 / 0.49 s |
| ascii | 189–223 / 0.37 s | 171–176 / 0.40 s | 123–131 / 0.34 s |

E now matches Ghostty on ligatures and underlines and is about 20% behind on plain code, down from
about 40%. The faster reader costs CPU (ligatures 0.57 → 0.87 s), still under D's. The full suite
hasn't been rerun with it; the tables above use the harness's reader.
