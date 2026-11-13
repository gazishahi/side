#!/bin/zsh
# The whole suite: emulator-only, throughput (3 runs, interleaved), frame cost, six sessions,
# keypress latency idle and loaded. Windows open and close on screen: leave them uncovered
# (Ghostty stops drawing an occluded surface). Results go to results/*.jsonl.
set -uo pipefail
here=${0:A:h}/..; T=$here/TermBench/.build/release; W=$here/workloads; R=${RESULTS:-$here/results}; mkdir -p $R
# The ascii workload is a directory of Swift sources: Side's own for the committed results.
src=${SOURCE:-$here/../../SIDE}; [[ -d $src ]] || { echo "set SOURCE to a directory of Swift sources (the ascii workload)" >&2; exit 2; }
(cd $here/TermBench && for p in TermBenchST TermBenchGV TermBenchGK; do swift build -c release --product $p; done) || exit 1
# E, Side's shipping engine (SideTerminal + AlloyTerminal), builds from this repository's packages.
if [[ " ${SETUPS:-} " == *" E "* ]]; then (cd $here/TermBenchE && swift build -c release --product TermBenchE) || exit 1; fi
bin() { case $1 in A|B) echo $T/TermBenchST;; C) echo $T/TermBenchGV;; D) echo $T/TermBenchGK;; E) echo $here/TermBenchE/.build/release/TermBenchE;; esac }
setups=(${=SETUPS:-A B C D})
$here/VTBench/.build/release/VTBench $src | grep -v "screen check" > $R/emulator-only.txt
: > $R/throughput.jsonl; : > $R/framecost.jsonl; : > $R/sessions.jsonl; : > $R/latency.jsonl
for run in 1 2 3; do
  for grid in "80 24" "200 60"; do set -- ${=grid}
    for w in ascii colors unicode cursor tui scroll; do for s in $setups; do
      line=$(timeout 200 $(bin $s) --setup $s --workload $W/$w.bin --cols $1 --rows $2 2>/dev/null | grep '^{')
      [[ -z $line ]] && line="{\"setup\":\"$s\",\"workload\":\"$w.bin\",\"grid\":\"$1x$2\",\"note\":\"failed\"}"
      echo "${line%\}},\"run\":$run}" >> $R/throughput.jsonl
    done; done
  done
done
for grid in "80 24" "200 60" "440 96"; do set -- ${=grid}
  for w in tui ascii; do for s in ${setups:#D}; do
    timeout 200 $(bin $s) --setup $s --mode framecost --workload $W/$w.bin --cols $1 --rows $2 2>/dev/null | grep '^{' >> $R/framecost.jsonl
  done; done
done
for run in 1 2 3; do
  for s in $setups; do
    timeout 200 $(bin $s) --setup $s --mode sessions --sessions 6 --workload $W/tui-burst.bin --cols 200 --rows 60 2>/dev/null | grep '^{' | sed "s/}\$/,\"run\":$run}/" >> $R/sessions.jsonl
  done
  for load in 0 5; do for s in $setups; do
    timeout 120 $(bin $s) --setup $s --mode latency --load $load --load-workload $W/tui-burst.bin --cols 200 --rows 60 2>/dev/null | grep '^{' | sed "s/}\$/,\"run\":$run}/" >> $R/latency.jsonl
    pkill -f tui-burst.bin; sleep 1
  done; done
done
python3 -I $here/scripts/summarize.py $R
