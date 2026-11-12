#!/bin/zsh
# Phase 0: what makes full libghostty draw a frame before a key's echo (NOTES.md section 13).
# Builds a copy of the pinned Ghostty with patches/ghostty-no-redraw-before-echo.diff applied, a
# copy of TermBench against it, and runs the stage profile (TERMBENCH_STAGES) for stock D and the
# patched D, with and without vsync, 3 runs interleaved. The patch is a diagnostic, not a fix:
# it drops the render a keypress queues and the redraw the IO thread queues for any message.
#   PATCH=both      (default) both renders dropped
#   PATCH=keypress  only the keypress's render (src/Surface.zig)
#   MARKS=1         also apply patches/ghostty-stage-marks.diff, which reports when Ghostty parses,
#                   updates, draws, commits and presents (Stages.swift's g_ stages), and run C
#                   alongside (NOTES.md section 14)
# Needs scripts/build-ghostty.sh run first, Zig 0.17, and Screen Recording permission for the
# app this runs in (Terminal.app works; a terminal inside Side doesn't get Side's).
set -euo pipefail
here=${HERE:-${0:A:h}/..}; T=$here/TermBench/.build/release
work=$here/.ghostty-patched; patch=${PATCH:-both}
rm -rf $work && mkdir -p $work
git clone -q $here/.ghostty $work/ghostty
commit=$(git -C $here/.ghostty rev-parse HEAD)
git -C $work/ghostty checkout -q $commit
case $patch in
  both) git -C $work/ghostty apply $here/patches/ghostty-no-redraw-before-echo.diff;;
  keypress) git -C $work/ghostty apply --include=src/Surface.zig $here/patches/ghostty-no-redraw-before-echo.diff;;
  *) echo "PATCH is both or keypress" >&2; exit 2;;
esac
[[ ${MARKS:-} == 1 ]] && git -C $work/ghostty apply $here/patches/ghostty-stage-marks.diff
(cd $work/ghostty && zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native)
rsync -a --exclude .build --exclude GhosttyKit.xcframework $here/TermBench/ $work/TermBench/
cp -R $work/ghostty/macos/GhosttyKit.xcframework $work/TermBench/
(cd $work/TermBench && swift build -c release --product TermBenchGK)
P=$work/TermBench/.build/release

set +e
R=$here/results/validation/${VALIDATION_DATE:-$(date +%F)}-ghostty-redraw; mkdir -p $R; out=$R/latency-$patch.jsonl; : > $out
variants=(D D-patched D-novsync D-patched-novsync)
[[ ${MARKS:-} == 1 ]] && { variants=(C C-renderthread D-patched D-patched-novsync); out=$R/latency-$patch-marks.jsonl; : > $out; }
for run in 1 2 3; do for v in $variants; do
  b=$T/TermBenchGK; g=""; s=D; e=""
  [[ $v == C* ]] && { b=$T/TermBenchGV; s=C; }
  [[ $v == C-renderthread ]] && e=renderthread
  [[ $v == D-patched* ]] && b=$P/TermBenchGK
  [[ $v == *novsync ]] && g="window-vsync = false"
  TERMBENCH_STAGES=1 TERMBENCH_KEYS=events TERMBENCH_CLOCK=display TERMBENCH_EXP=$e TERMBENCH_GHOSTTY_CONFIG="$g" \
    timeout 120 $b --setup $s --mode latency --load 0 --cols 200 --rows 60 2>/dev/null | grep '^{' \
    | sed "s/}\$/,\"variant\":\"$v\",\"patch\":\"$patch\",\"run\":$run}/" >> $out
  sleep 0.7
done; done
echo "done: $out"
