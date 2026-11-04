# Terminal engine benchmarks

The harness behind `docs/SIDE_TERMINAL_BENCHMARKS_2026-11-03.md`: four ways to build Run's
terminal, measured the same way.

| Setup | Emulator | Drawing |
| --- | --- | --- |
| A | SwiftTerm 1.20.0 | SwiftTerm's CoreText view (Side today) |
| B | SwiftTerm 1.20.0, on a reader thread | Alloy renderer prototype |
| C | libghostty-vt, on a reader thread | Alloy renderer prototype |
| D | full libghostty | Ghostty's own renderer |

## Layout

- `VTBench/` measures emulator-only throughput (SwiftTerm vs libghostty-vt, no window or PTY) and writes the workloads.
- `TermBench/` is the end-to-end harness. `Harness` is shared: the PTY, metrics, the Alloy grid renderer (`GridRenderer.swift`, over Alloy's atlas copied in as `AlloyGlyphAtlas.swift`), frame cost and latency. It builds three executables, because GhosttyKit and libghostty-vt can't link into one binary:
  - `TermBenchST`: setups A and B
  - `TermBenchGV`: setup C
  - `TermBenchGK`: setup D
- `Keeper/keeper.c` is the prototype session keeper behind the memory figures in `docs/SIDE_RFC_SESSION_RESTORE.md`: a PTY and a headless libghostty-vt terminal, measured idle, with full scrollback, and compressed.
- `scripts/` holds the build, workload, suite and summary scripts.
- `results/` holds the raw results the write-up was made from, plus `memory/`, the `footprint` breakdowns.

## Running

```sh
brew install zig                 # 0.17
scripts/build-ghostty.sh         # pinned Ghostty commit -> the two xcframeworks (git-ignored)
scripts/make-workloads.sh        # workloads/*.bin (git-ignored)
scripts/run-all.sh               # about 30 minutes; SETUPS="B C" scripts/run-all.sh for a subset
```

Windows open and close on screen while it runs. Leave them uncovered, because Ghostty stops drawing a surface that's hidden. Keypress latency captures the harness's own windows, which needs no Screen Recording permission.

One run by hand:

```sh
TermBench/.build/release/TermBenchGV --setup C --workload workloads/tui.bin --cols 200 --rows 60
```

- Modes are `--mode throughput` (the default), `framecost`, `sessions --sessions 6`, and `latency [--load 5 --load-workload workloads/tui-burst.bin]`.
- `TERMBENCH_SHOT=/path.png` writes the final frame, so you can check a run drew what it should.
- `TERMBENCH_SCROLLBACK=500` sets B's scrollback.

## Rules that keep it fair

- Same font (Menlo 13), colors and command for all four. Each window is sized from its engine's own cell metrics, so every setup gets the same grid.
- The clock starts when the shell, already waiting on `read`, gets its line. No setup's startup is counted, Ghostty's `login` wrapper included.
- libghostty-vt runs with grapheme clustering (mode 2027) on, as Ghostty.app does, and with its default 10,000-byte scrollback cap removed (it overrides the line limit).
- Check the screenshots before trusting a number. Two invalid runs were caught that way.
