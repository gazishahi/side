# ptyread: the PTY read path on its own

`cat` a workload through a PTY into libghostty-vt, timed, with Ghostty's own reader (an exact
port of `src/termio/Exec.zig` at `c7f68a7`: gather and parse threads, a ring of 4 × 64 KiB,
non-blocking reads, 16 spin retries then a 1 ms poll once a read fills the kernel's ~1 KiB,
3 ms per batch) or a blocking read-then-parse loop (the harness's, and in effect the keeper's).

    X=../../../Packages/SideSessions/GhosttyVt.xcframework/macos-arm64_x86_64
    clang -O2 -o ptyread ptyread.c -I$X/Headers $X/libghostty-vt.a -lc++
    ./ptyread ../workloads/ligatures.bin ghostty|serial [parse|noparse] [initiated|interactive]

2026-11-20, ligatures.bin (64 MB), 6 interleaved runs on a loaded machine (load 11–14):

| | median MB/s | best | CPU |
|---|---|---|---|
| Ghostty's reader, parsing | 135.9 | 159.7 | 0.82 s |
| blocking reader, parsing | 125.7 | 129.0 | 0.48 s |
| Ghostty's reader, no parsing | 150.2 | 172.0 | 0.42 s |
| blocking reader, no parsing | 121.3 | 122.4 | 0.27 s |

Rerun the same evening once the machine was quiet (load under 3.5 at the start; tight spreads):

| | median MB/s | best | CPU |
|---|---|---|---|
| Ghostty's reader, parsing | 183.8 | 185.9 | 0.68 s |
| blocking reader, parsing | 143.7 | 145.7 | 0.44 s |
| Ghostty's reader, no parsing | 188.2 | 190.9 | 0.34 s |
| blocking reader, no parsing | 126.2 | 130.2 | 0.24 s |

Ghostty's reader is 28% ahead with parsing, about Ghostty's own lead over Side's engine (setup D
against E with drawing off, `../results/2026-11-20-rerun/`). The blocking reader wakes per
~1 KiB, in lockstep with the writer, as Ghostty's source says; the spin costs CPU.
