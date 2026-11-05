#!/bin/zsh
# Side reopened over two idle Claude Codes kept running: neither did anything, so the activity
# pill says nothing (2026-11-05: a reattached tab's redraw read as a turn that finished).
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-reopen.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-reopen
mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
dump() { $U post activity-dump; sleep 0.7; awk '/^\[activity\]/{block=""} {block=block $0 "\n"} END{printf "%s", block}' $ROOT/side.log; }
field() { dump | awk -v key="$1" '$1==key{ $1=""; sub(/^ /,""); print }' | tail -1; }

$U launch
$U post "window-size 1000 640" "stage run"; sleep 2.5
$U claude
$U type "claude
"
$U post "action newSession"; sleep 2.5
$U claude
$U type "claude
"
$U post "action newSession"; sleep 2.5
sleep 2
check "idle, nothing to say" '[[ $(field pill) == "-" ]]' "$(field pill)"
$U relaunch
sleep 3
pill=$(field pill)
check "reopened, still nothing to say" '[[ $pill == "-" ]]' "$pill"
dump | grep '^session' 
$U post "window-size 1200 700"; sleep 2
pill=$(field pill)
check "a resize redraws them, still nothing" '[[ $pill == "-" ]]' "$pill"
$U shot $OUT/reopened.png > /dev/null
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
