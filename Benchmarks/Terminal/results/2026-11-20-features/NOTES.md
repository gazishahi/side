# Feature workloads: the RFC's rule 4 (2026-11-20)

The workloads `docs/SIDE_RFC_TERMINAL_ENGINE.md` (rule 4) asks for before any renderer claim
against Ghostty: ligature-heavy code, box drawing, styled underlines, selection while streaming
and a scrolled-back viewport. Images (kitty graphics) are Tier 2 and not here.

Setups as in `../2026-11-13-tier1/`: **A** SwiftTerm, **C** the Phase 0 prototype renderer over
libghostty-vt, **D** Ghostty (`c7f68a7`, full libghostty), **E** Side's engine (SideTerminal +
AlloyTerminal, commit `01f4810`). Same machine (M3 Pro, 120 Hz), release builds,
`scripts/run-features.sh`, every setup in **Fira Code** (FiraCodeNFM-Reg, 13 pt) at 200×60.

## Workloads

`scripts/make-feature-workloads.py`, deterministic, 64 MB each (4× the earlier workloads, so
start-up weighs less):

- **ligatures**: syntax-highlighted code (each token colored, as bat prints it), dense with
  ligature sequences (`-> => != === <= >= :: |> <$> && ||`…).
- **boxes**: a 200×60 dashboard of 12 panels redrawn in place: light, heavy, double and rounded
  box drawing, eighth-block meters, shades and quadrants, braille graphs, 256 colors.
- **underlines**: scrolling text, 30% of words marked: single, double, curly, dotted, dashed
  underlines with their own colors (SGR 58), strikethrough, overline.
- **Views** (`--view`, D and E): *selected*: select all once the first 400 KB is shown, then
  stream; *scrolled*: scroll back a page, then stream below the viewport. View runs start
  through a FIFO, not a typed line: typing into Ghostty scrolls it to the bottom.

## Features each setup had on

| | ligatures | box drawing | underline styles | strike/overline | selection |
|---|---|---|---|---|---|
| A | no (SwiftTerm doesn't shape) | font glyphs | not checked | not checked | not run |
| C | no | font glyphs | one single underline for every style | no | not run |
| D | yes (Ghostty's defaults) | drawn sprites | all | yes | inverted colors |
| E | yes (CoreText runs) | drawn sprites | all | yes | selection background |

Ghostty ran at its defaults (no custom shaders, no background image), with
`window-padding = 0`, `cursor-style-blink = false`, `scrollback-limit = 10000000` (its
default). E's scrollback is 10,000 lines (Side's). E draws on its own thread per output burst; D
paces frames to the display.

## Throughput (MB/s, median of 5; process CPU for the run)

| | A | C | D | E |
|---|---|---|---|---|
| ligatures | 9.0 / 8.14 s | 109.7 / 0.60 s | 139.6 / 1.20 s | 112.3 / 0.85 s |
| boxes | 5.8 / 12.02 s | 231.2 / 0.29 s | 229.7 / 0.65 s | 218.7 / 0.35 s |
| underlines | 15.6 / 5.00 s | 134.7 / 0.47 s | 168.5 / 0.96 s | 131.2 / 0.66 s |

| views | D | E |
|---|---|---|
| boxes, selected | 232.1 / 0.62 s | 244.4 / 0.32 s |
| tui, selected (16 MB) | 162.1 / 0.19 s | 150.8 / 0.10 s |
| ligatures, scrolled | 154.6 / 1.07 s | 122.2 / 0.74 s |
| ascii, scrolled (36 MB) | 195.1 / 0.38 s | 140.8 / 0.29 s |

Main-thread CPU: E 0.001–0.004 s, D 0.003–0.013 s, C 0.05–0.07 s, A 4–11 s.

Every scrolled run ended still scrolled back in both (`views.txt`). Both prune scrollback during a
64 MB run, and both then keep the viewport at the oldest row, so the viewport's contents keep
changing (E drew 69 frames in a scrolled ligatures run).

## Frame cost (ms, median; CPU of a full frame / its GPU time; offscreen, C and E only)

| | C | E |
|---|---|---|
| ligatures 200×60 | 0.61 / 0.11 | 3.88 / 0.19 |
| boxes 200×60 | 0.97 / 0.18 | 2.63 / 0.19 |
| underlines 200×60 | 0.62 / 0.11 | 2.96 / 0.20 |
| ligatures 440×96 | 1.63 / 0.34 | 7.25 / 0.58 |
| boxes 440×96 | 1.46 / 0.40 | 3.35 / 0.40 |
| underlines 440×96 | 1.68 / 0.34 | 5.60 / 0.50 |

In a ligature font E shapes every row as a run; that is most of its frame (at 200×60 on
ligatures, 3.6 of 3.9 ms is drawing, 0.5 the snapshot). C draws none of these features. D's frame
cost can't be measured this way.

## What these numbers say, and don't

- D is faster than E on ligatures (+24%), underlines (+28%) and a scrolled-back viewport
  (+27–39%) and the tui with a selection (+7%); on boxes, with or without a selection, they're
  within 5% either way.
- E's features cost it little throughput against C, which draws none of them (within 3% on
  ligatures and underlines, 5% on boxes).
- E used less process CPU than D in every run, but D's frame count isn't known (E's is), so this
  is **not** a claim that E's renderer is cheaper: it may be drawing fewer frames.
- One D run on ligatures (49 MB/s) and one on boxes (110) were far below the others; the medians
  aren't moved by them.
- A crash this suite found in E (a cursor outside the grid before layout) is fixed in `e99db57`.
- First pass's view runs passed `--view` as one argument and ran as plain runs; they were
  dropped from `throughput.jsonl` and the views rerun (`PARTS=views`).
