#!/bin/zsh
# The RFC's rule 4 suite (docs/SIDE_RFC_TERMINAL_ENGINE.md): workloads that exercise the renderer's
# features, in one ligature font for every setup. Throughput (5 runs, interleaved) of ligatures,
# boxes and underlines in A, C, D and E; selection while streaming and a scrolled-back viewport in
# D and E (the setups that draw them); frame cost of each workload in C and E. Windows open and
# close on screen: leave them uncovered (Ghostty stops drawing an occluded surface).
# Workloads: scripts/make-feature-workloads.py. Results go to $RESULTS (default results/features).
set -uo pipefail
here=${0:A:h}/..; T=$here/TermBench/.build/release; W=$here/workloads; R=${RESULTS:-$here/results/features}  # committed runs: results/<date>-features; mkdir -p $R
font=${FONT:-FiraCodeNFM-Reg}
for w in ligatures boxes underlines; do [[ -f $W/$w.bin ]] || python3 -I $here/scripts/make-feature-workloads.py $W || exit 1; done
(cd $here/TermBench && for p in TermBenchST TermBenchGV TermBenchGK; do swift build -c release --product $p; done) || exit 1
(cd $here/TermBenchE && swift build -c release --product TermBenchE) || exit 1
bin() { case $1 in A) echo $T/TermBenchST;; C) echo $T/TermBenchGV;; D) echo $T/TermBenchGK;; E) echo $here/TermBenchE/.build/release/TermBenchE;; esac }
run() { # setup workload [view]
  local line; local -a view=()
  [[ -n ${3:-} ]] && view=(--view $3)
  line=$(timeout 200 $(bin $1) --setup $1 --font $font --workload $W/$2.bin --cols 200 --rows 60 $view 2>/dev/null | grep -E '^(\{|VIEW)')
  [[ $line != *'{'* ]] && line="{\"setup\":\"$1\",\"workload\":\"$2.bin\",\"view\":\"${3:-}\",\"note\":\"failed\"}"
  print -r -- "$line"
}
# PARTS: any of "plain views framecost" (all by default); a part's files are rewritten.
parts=" ${PARTS:-plain views framecost} "
[[ $parts == *" plain "* ]] && : > $R/throughput.jsonl
[[ $parts == *" views "* ]] && { : > $R/views.jsonl; : > $R/views.txt; }
[[ $parts == *" framecost "* ]] && : > $R/framecost.jsonl
for i in 1 2 3 4 5; do
  [[ $parts == *" plain "* ]] && for w in ligatures boxes underlines; do for s in A C D E; do
    out=$(run $s $w); echo "${${out##*$'\n'}%\}},\"run\":$i}" >> $R/throughput.jsonl
  done; done
  [[ $parts == *" views "* ]] && for v in "boxes selected" "tui selected" "ligatures scrolled" "ascii scrolled"; do set -- ${=v}; for s in D E; do
    out=$(run $s $1 $2)
    echo "${${out##*$'\n'}%\}},\"run\":$i}" >> $R/views.jsonl
    # The viewport at the end: a scrolled run must still be scrolled back.
    [[ $out == *VIEW* ]] && echo "$s $1 $2 run $i: ${${(f)out}[1]}" >> $R/views.txt
  done; done
done
[[ $parts == *" framecost "* ]] && for grid in "200 60" "440 96"; do set -- ${=grid}
  for w in ligatures boxes underlines; do for s in C E; do
    timeout 200 $(bin $s) --setup $s --font $font --mode framecost --workload $W/$w.bin --cols $1 --rows $2 2>/dev/null | grep '^{' >> $R/framecost.jsonl
  done; done
done
echo DONE
