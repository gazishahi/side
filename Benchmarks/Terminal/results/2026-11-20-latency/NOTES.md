# Keypress latency after the 2026-11-20 changes

Display clock (`TERMBENCH_CLOCK=display`, ScreenCaptureKit), run from Terminal.app, 200×60, Menlo
13, release builds, `scripts/run-sessions-latency.sh`: three rounds, each 60 keys idle and 60 keys
with five hidden sessions streaming the tui burst. Same machine as `../2026-11-13-tier1/`.

Since 2026-11-13: the shaping cache (a5c9ceb), the keeper's bridged reader (7be08ba), Side's own
bridged reader (f0679aa), and setup E's latency mode now types and reads through Side's own
PseudoTerminalProcess (fc47434), as Side's surface does. **Behind the keeper**: the same through
`Keeper/relay.c` and the new keeper, D and E only (`../2026-11-20-latency-keeper/`).

## Latency (ms; median of the three rounds' medians; p95 the median of the rounds' p95s)

| | A | C | D | E |
|---|---|---|---|---|
| idle | 16.4 | 14.8 | 22.9 | 14.6 |
| 5 sessions' load | 17.4 | 13.3 | 22.1 | 13.7 |
| p95, idle | 20.3 | 17.8 | 34.0 | 18.4 |
| p95, loaded | 24.0 | 17.6 | 25.6 | 18.0 |

Rounds, idle: A 16.6 / 16.4 / 16.2, C 14.8 / 15.0 / 13.3, D 27.0 / 22.9 / 21.8, E 14.6 / 14.7 / 14.5.
No key timed out.

Behind the keeper:

| | D | E |
|---|---|---|
| idle | 22.0 (p95 31.7) | 14.7 (p95 18.3) |
| 5 sessions' load | 21.5 (p95 28.6) | 14.7 (p95 18.4) |

Against 2026-11-13 (E 14.8 idle / 14.0 loaded, p95 18.2): unchanged within run-to-run spread. The
bridged readers hand a keystroke's echo over at once, as designed. D's ~8 ms more is Ghostty's
extra frame per key (`../validation/`, and the note drafted for Ghostty's author), as before.

## Six sessions (`sessions.jsonl`, median of 3)

| | process CPU | main-thread CPU | footprint |
|---|---|---|---|
| A | 3.39 s | 2.72 s | 69 MB |
| C | 0.77 s | 0.27 s | 171 MB |
| D | 1.48 s | 0.35 s | 318 MB |
| E | 1.11 s | (0.001 s) | 171 MB |

E's sessions mode still read through the harness's reader here, feeding the parser from that
thread, not Side's path: its row is superseded by `../2026-11-21-sessions/NOTES.md` (Side's
reader: main thread 0.108 s, process 1.22 s against D's 0.95 s, 177 MB against 321).

## What can be said

- Side's engine answers a keypress in 14.6 ms idle and 13.7 ms under load (p95 18.4 / 18.0), on
  the display clock, through Side's own reader; 14.7 ms through the keeper. Ghostty measured
  22.9 / 22.1 here; its extra frame per key is the known reason.
- Today's throughput work didn't cost latency.
