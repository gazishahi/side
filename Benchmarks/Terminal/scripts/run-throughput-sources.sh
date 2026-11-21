#!/bin/zsh
# Where Side's throughput goes (2026-11-20), in one interleaved pass, Fira Code, 200×60:
#   gap:     D, E and E with drawing off (TERMBENCH_NODRAW) on ligatures, underlines, ascii (5 runs)
#   keeper:  E and D behind an old and a new SideSessionKeeper, through Keeper/relay.c (3 runs)
#   reader:  Reader/ptyread, Ghostty's reader against a blocking one, parsing and not (6 runs)
# OLD_KEEPER and NEW_KEEPER are SideSessionKeeper builds; without them the keeper part is skipped.
# Windows open and close on screen: leave them uncovered. Results go to $RESULTS.
set -uo pipefail
here=${0:A:h}/..; W=$here/workloads; R=${RESULTS:?a results directory}; mkdir -p $R
font=FiraCodeNFM-Reg
D=$here/TermBench/.build/release/TermBenchGK; E=$here/TermBenchE/.build/release/TermBenchE
(cd $here/TermBench && swift build -c release --product TermBenchGK) >/dev/null || exit 1
(cd $here/TermBenchE && swift build -c release --product TermBenchE) >/dev/null || exit 1
X=$here/../../Packages/SideSessions/GhosttyVt.xcframework/macos-arm64_x86_64
clang -O2 -o $R/ptyread $here/Reader/ptyread.c -I$X/Headers $X/libghostty-vt.a -lc++ || exit 1
clang -O2 -o $R/keeper-relay $here/Keeper/relay.c || exit 1
one() { # label, then the command; one JSON line tagged with the label
  local line; line=$("${@:2}" 2>/dev/null | grep '^{')
  [[ -z $line ]] && line='{"note":"failed"}'
  print -r -- "${line%\}},\"label\":\"$1\"}"
}
: > $R/gap.jsonl; : > $R/keeper.jsonl; : > $R/reader.txt
for i in 1 2 3 4 5; do for w in ligatures underlines ascii; do
  one "D $w" timeout 120 $D --setup D --font $font --workload $W/$w.bin --cols 200 --rows 60 >> $R/gap.jsonl
  one "E $w" timeout 120 $E --setup E --font $font --workload $W/$w.bin --cols 200 --rows 60 >> $R/gap.jsonl
  TERMBENCH_NODRAW=1 one "E-nodraw $w" timeout 120 $E --setup E --font $font --workload $W/$w.bin --cols 200 --rows 60 >> $R/gap.jsonl
done; done
if [[ -n ${OLD_KEEPER:-} && -n ${NEW_KEEPER:-} ]]; then
  run=/tmp/tbk-rerun; mkdir -p $run; chmod 700 $run
  for i in 1 2 3; do for w in ligatures ascii; do for s in E D; do for k in old new; do
    kb=$OLD_KEEPER; [[ $k == new ]] && kb=$NEW_KEEPER; b=$E; [[ $s == D ]] && b=$D
    TERMBENCH_RELAY="$R/keeper-relay $kb $run" one "$s $w $k-keeper" timeout 120 $b --setup $s --font $font --workload $W/$w.bin --cols 200 --rows 60 >> $R/keeper.jsonl
  done; done; done; done
  # The benchmark's own keepers only, by their run directory: never Side's real ones.
  pkill -TERM -f -- "--launch $run/" || true
fi
for i in 1 2 3 4 5 6; do for cfg in "ghostty parse" "serial parse" "ghostty noparse" "serial noparse"; do
  timeout 60 $R/ptyread $W/ligatures.bin ${=cfg} >> $R/reader.txt
done; done
uptime >> $R/reader.txt
echo DONE
