#!/bin/zsh
# The activity pill with two Claude Codes out of sight, then one: it names the most pressing,
# counts the rest ("+1"), lists them on a click, and with one goes straight there.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-activity.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-activity
mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
dump() { $U post activity-dump; sleep 0.7; awk '/^\[activity\]/{block=""} {block=block $0 "\n"} END{printf "%s", block}' $ROOT/side.log; }
field() { dump | awk -v key="$1" '$1==key{ $1=""; sub(/^ /,""); print }' | tail -1; }

$U launch
$U post "window-size 1000 640" "stage run"; sleep 2.5
$U claude
$U type "FAKE_CLAUDE_TURN=12 claude
"
$U post "action newSession"; sleep 2.5
$U claude
$U type "FAKE_CLAUDE_TURN=6 claude
"
sleep 1
$U type "second
"
$U post "run-select 0"; sleep 0.5
$U type "first
"
$U post "stage make"; sleep 0.5
pill=$(field pill)
check "names one and counts the other" '[[ $pill == "Claude Code working +1" ]]' "$pill"
$U shot $OUT/two-working.png > /dev/null
sleep 5
pill=$(field pill)
check "the finished one comes first" '[[ $pill == "Claude Code finished +1" ]]' "$pill"
$U post "activity-open"; sleep 0.8
check "with two, a click lists them" '[[ $(field popover) == true ]]' "$(field popover)"
$U shot $OUT/list.png > /dev/null
$U post "activity-open"; sleep 0.5
sleep 7
pill=$(field pill)
check "both finished" '[[ $pill == "Claude Code finished +1" ]]' "$pill"
$U post "activity-go 0"; sleep 1.5
pill=$(field pill)
check "seeing one leaves the other, uncounted" '[[ $pill == "Claude Code finished" ]]' "$pill"
$U post "stage make"; sleep 1
$U post "activity-open"; sleep 1.5
check "with one, a click goes there" '[[ $(field stage) == run && $(field popover) == false ]]' "$(field stage) $(field popover)"
# A Claude Code working in the tab on screen stays out of the pill while Settings is in front
# of its window (2026-11-05: the pill came and went with the key window).
$U post "stage run" "run-select 0"; sleep 0.5
$U type "go
"
sleep 0.5
check "working on screen, nothing to say" '[[ $(field pill) == "-" ]]' "$(field pill)"
$U post "settings general"; sleep 1.5
check "still nothing with Settings key" '[[ $(field pill) == "-" ]]' "$(field pill)"
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
