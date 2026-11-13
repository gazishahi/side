#!/bin/zsh
# The suite's sessions and keypress-latency parts alone (run-all.sh's last loop), for a rerun:
# six sessions, then latency idle and under five sessions' load, three times. Run from
# Terminal.app with Screen Recording allowed and TERMBENCH_CLOCK=display for the display clock.
set -uo pipefail
here=${0:A:h}/..; T=$here/TermBench/.build/release; W=$here/workloads; R=${RESULTS:-$here/results}; mkdir -p $R
bin() { case $1 in A|B) echo $T/TermBenchST;; C) echo $T/TermBenchGV;; D) echo $T/TermBenchGK;; E) echo $here/TermBenchE/.build/release/TermBenchE;; esac }
setups=(${=SETUPS:-A C D E})
: > $R/sessions.jsonl; : > $R/latency.jsonl
for run in 1 2 3; do
  for s in $setups; do
    timeout 200 $(bin $s) --setup $s --mode sessions --sessions 6 --workload $W/tui-burst.bin --cols 200 --rows 60 2>/dev/null | grep '^{' | sed "s/}\$/,\"run\":$run}/" >> $R/sessions.jsonl
  done
  for load in 0 5; do for s in $setups; do
    timeout 120 $(bin $s) --setup $s --mode latency --load $load --load-workload $W/tui-burst.bin --cols 200 --rows 60 2>/dev/null | grep '^{' | sed "s/}\$/,\"run\":$run}/" >> $R/latency.jsonl
    pkill -f tui-burst.bin; sleep 1
  done; done
done
