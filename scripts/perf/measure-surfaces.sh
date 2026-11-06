#!/bin/zsh
# What Liquid Glass costs (2026-11-06): the UI-test build, drawn with each surface mode
# (SIDE_SURFACES=glass|vibrancy|solid), through the same scenes, sampled once a second:
#   gpu   the whole system's GPU use (ioreg's "Device Utilization %"), so other apps count too:
#         compare against the baseline taken with the test build closed
#   ws    WindowServer's CPU, where much of the compositing of glass happens
#   side  Side's CPU, and its Energy Impact (top's POWER)
#   watts the whole Mac's draw from the battery (its current times its voltage, once a second):
#         only on battery power, so unplug it, and keep the brightness and other apps the same
#         for every scene. On AC power the battery passes nothing and this column reads 0.
# Needs no admin rights. The scenes: Make idle on a long file; Make scrolling continuously;
# the Terminal printing continuously under the stage bar.
#
#   scripts/uitest/uitest.sh build && scripts/perf/measure-surfaces.sh [seconds per scene] [rounds]
#   On battery, longer scenes: scripts/perf/measure-surfaces.sh 120 2
set -uo pipefail
U=$(dirname "$0")/../uitest/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
SECONDS_PER=${1:-15}
ROUNDS=${2:-2}
OUT=$ROOT/perf-surfaces; mkdir -p $OUT
RESULTS=$OUT/results.tsv
echo "round\tmode\tscene\tgpu_avg\tgpu_max\tws_cpu\tside_cpu\tside_power\twatts" > $RESULTS
pmset -g batt | grep -q "AC Power" && echo "On AC power: the watts column needs the Mac on battery."

# The Mac's draw from the battery now, in watts (0 on AC power).
watts() {
  ioreg -rn AppleSmartBattery -a | python3 -I -c '
import plistlib, sys
b = plistlib.loads(sys.stdin.buffer.read())[0]
amps = b.get("InstantAmperage", 0)
amps = amps - 2**64 if amps >= 2**63 else amps
print(round(max(0, -amps) * b.get("Voltage", 0) / 1e6, 2))'
}
WS=$(pgrep -x WindowServer | head -1)

# One scene: samples for $SECONDS_PER seconds, appends a row.
sample() {
  local round=$1 mode=$2 scene=$3 pid=${4:-}
  local gpufile=$OUT/gpu.txt wattfile=$OUT/watts.txt; : > $gpufile; : > $wattfile
  ( for _ in $(seq 1 $SECONDS_PER); do ioreg -r -d 1 -c IOAccelerator | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2 >> $gpufile; watts >> $wattfile; sleep 1; done ) &
  local gpujob=$!
  local pids="-pid $WS"; [[ -n $pid ]] && pids="$pids -pid $pid"
  # The first of top's samples has no CPU figures yet: skipped.
  top -l $((SECONDS_PER + 1)) -s 1 -stats pid,cpu,power ${=pids} | awk -v ws=$WS -v side=${pid:-0} '
    /^PID/ { n++; next }
    n > 1 && $1 == ws { wsc += $2; wsn++ }
    n > 1 && $1 == side { sc += $2; sp += $3; sn++ }
    END { printf "%.1f\t%.1f\t%.1f\n", (wsn ? wsc/wsn : 0), (sn ? sc/sn : 0), (sn ? sp/sn : 0) }' > $OUT/top.txt
  wait $gpujob
  local gpu=$(awk '{ s += $1; if ($1 > m) m = $1 } END { printf "%.1f\t%d", s/NR, m }' $gpufile)
  local w=$(awk '{ s += $1 } END { printf "%.2f", s/NR }' $wattfile)
  echo "$round\t$mode\t$scene\t$gpu\t$(cat $OUT/top.txt)\t$w" >> $RESULTS
  echo "  $mode $scene: gpu avg/max $gpu  ws/side cpu, side power $(cat $OUT/top.txt)  watts $w"
}

for round in $(seq 1 $ROUNDS); do
  echo "round $round"
  $U quit > /dev/null 2>&1; sleep 2
  sample $round none baseline
  for mode in glass vibrancy solid; do
    SIDE_SURFACES=$mode $U launch > /dev/null; sleep 2
    pid=$(cat $ROOT/side.pid)
    $U post "window-size 1400 900" "stage make"; sleep 1
    $U post "open $ROOT/repo/SIDE/MakeWorkspaceViewController.swift"; sleep 3
    sample $round $mode idle $pid
    $U post "scroll $((SECONDS_PER * 60))"
    sample $round $mode scrolling $pid
    $U post "stage run"; sleep 2
    $U type "while true; do ls -la /usr/bin | head -60; sleep 0.03; done
"
    sleep 1
    sample $round $mode terminal $pid
    $U quit > /dev/null; sleep 2
  done
done
echo "results: $RESULTS"
