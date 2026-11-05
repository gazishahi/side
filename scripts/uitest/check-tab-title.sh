#!/bin/zsh
# A click on a tab's title selects it (2026-11-05: the single tab's name, faded out but still
# laid over the first tabs, took the click). Then the strip lets go of a long-titled tab: frames
# of the name taking over from the tab's cut title, for looking at.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-tab-title.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-tab-title
rm -rf $OUT; mkdir -p $OUT/frames
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
tabs() { $U post tabs-dump; sleep 0.5; grep '^\[tabs\]' $ROOT/side.log | tail -1; }

$U launch
$U post "window-size 1000 640" "stage run"; sleep 2.5
$U post "action newSession"; sleep 2
$U type "printf '\\033]0;A long title that the tab has to cut short somewhere\\007'; sleep 600
"
$U post "action newSession"; sleep 2
for index in 0 1 2 0; do
  $U post "tab-click-title $index"; sleep 0.6
  t=$(tabs)
  check "a click on tab $index's title selects it" '[[ $t == *"active=$index" ]]' "$t"
done
$U post "run-select 1"; sleep 0.6
$U post "tab-click-title 0"; sleep 0.4
$U post "run-close-tab"; sleep 0.8
$U post "tab-click-title 1"; sleep 0.4
$U post "run-close-tab" "snapshots $OUT/frames 14 33"; sleep 2
t=$(tabs)
check "one tab left, no strip" '[[ $t == *"strip= "* ]]' "$t"
$U shot $OUT/after.png > /dev/null
$U quit
echo "$failures failed; frames in $OUT/frames"
exit $(( failures > 0 ))
