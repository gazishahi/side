# Rule 4 features after Tier 2 (2026-11-21)

`scripts/run-features.sh`: Fira Code (FiraCodeNFM-Reg), 200×60, five interleaved runs, release
builds. Medians with ranges. Load 2.8 at the start, 4.0 at the end (`load-*.txt`; the window
server and Notification Center were busy throughout).

Since `../2026-11-20-reader/`: Tier 2 is done (kitty graphics 723c06d, translucent backgrounds
80b8bf1, font weight 33c7345), the new engine is Side's default (226380c), and there's a new
rule-4 workload, `images.bin`: a listing with 160×100 image previews between its lines, PNG and
raw RGB in turn, each under a new id and shown at 20×5 cells, so every one is decoded, stored and
placed, then scrolled away (`scripts/make-feature-workloads.py`). Only D and E decode kitty
graphics, so only they run it.

## Throughput (MB/s) and process CPU (s)

| | A, SwiftTerm | C, Phase 0 | D, Ghostty | E, Side's engine | E against D |
|---|---|---|---|---|---|
| ligatures | 10 | 126 | 163 [157–170], 1.06 s | 159 [144–169], 0.84 s | −2% |
| boxes | 6 | 247 | 258 [252–267], 0.59 s | 242 [242–267], 0.48 s | −6% |
| underlines | 18 | 154 | 196 [188–201], 0.87 s | 183 [176–190], 0.70 s | −7% |
| images | – | – | 240 [230–258], 0.57 s | 253 [248–280], 0.51 s | +5% |

On images, E's footprint is 303 MB against D's 401 (median). E drew 31–34 frames per run; D's
frame count isn't known.

Against 2026-11-20 (D / E): ligatures 163 / 155 then, 163 / 159 now; boxes 260 / 250, 258 / 242;
underlines 193 / 185, 196 / 183. Unchanged within run-to-run spread: Tier 2 cost nothing
measurable on text.

## Views (MB/s, process CPU)

| | D | E |
|---|---|---|
| ascii, scrolled back | 210, 0.35 s | 193, 0.31 s |
| ligatures, scrolled back | 159, 1.06 s | 159, 0.81 s |
| boxes, selection on screen | 263, 0.58 s | 249, 0.47 s |
| tui, selection on screen | 171, 0.18 s | 154, 0.14 s |

Every scrolled run ended still scrolled back (`views.txt`). D keeps ~5,600 rows of scrollback
here and E ~9,900 (Ghostty's byte limit against Side's 10,000 lines).

## Frame cost (ms, median; `framecost.jsonl`)

| | C full CPU | E full CPU | E GPU |
|---|---|---|---|
| ligatures 440×96 | 1.48 | 2.60 | 0.34 |
| boxes 440×96 | 1.24 | 2.93 | 0.40 |
| underlines 440×96 | 1.51 | 2.71 | 0.38 |

C draws none of these workloads' features (no ligatures, no drawn boxes, plain underlines), so
it's a floor, not a peer. E's ligature frame was 2.43–2.46 ms on 2026-11-20.

## What can be said

- With Tier 1 and Tier 2 done (the RFC's rule 2), Side's engine keeps up with Ghostty: within
  2–7% on ligature-heavy code, box-drawing dashboards and styled underlines, and 5% ahead on
  image previews, through Side's own PTY reader.
- A 440×96 frame of ligature-font code takes Side's engine 2.6 ms of CPU.
- Not claimable: that Side's engine uses less CPU than Ghostty. It does here (10–21% less process
  CPU), but Ghostty's frame count isn't known, so the work done isn't known to be the same. The
  six-sessions measurement (`../2026-11-21-sessions/`) had E at 28% more process CPU than D.
