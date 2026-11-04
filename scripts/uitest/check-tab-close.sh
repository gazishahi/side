#!/bin/zsh
# Closing tabs by their X in quick succession (the owner, 2026-11-04: sometimes the X did
# nothing, and then the tab couldn't be clicked either). Each click closes the tab under it,
# and the strip and the stage's own list agree throughout. Then ⌘1 and ⌘9 in Terminal.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-tab-close.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
tabs() { $U post tabs-dump; sleep 0.4; grep -a "^\[tabs\]" $ROOT/side.log | tail -1 | sed 's/^\[tabs\] //'; }

$U launch
$U post "window-size 1100 640"
# Editor: six files, then the X on the second, four times, 120 ms apart.
for f in README.md scripts/test.sh scripts/release.sh scripts/budgets.sh docs/SIDE_RFC_VIM.md docs/SIDE_RFC_GIT_TRACKS.md; do $U post "open $ROOT/repo/$f"; sleep 0.4; done
sleep 1
before=$(tabs)
for i in 1 2 3 4; do $U post "tab-x 1"; sleep 0.12; done
sleep 1
after=$(tabs)
strip=$(echo $after | sed -E 's/strip=(.*) model=(.*) active=.*/\1/'); model=$(echo $after | sed -E 's/strip=(.*) model=(.*) active=.*/\2/')
check "Editor: four quick X clicks close four tabs" '[[ $(echo $strip | tr "|" "\n" | wc -l | tr -d " ") == 2 ]]' "$before → $after"
check "Editor: the strip and the tabs agree" '[[ $strip == $model ]]' "$after"
check "Editor: the first and last stay" '[[ $strip == "README.md|SIDE_RFC_GIT_TRACKS.md" ]]' "$strip"
# Terminal: five tabs, then the X on the second, three times.
$U post "stage run"; sleep 2.5
for i in 1 2 3 4; do $U post "action newSession"; sleep 1.5; done
sleep 1
for i in 1 2 3; do $U post "tab-x 1"; sleep 0.12; done
sleep 1.5
after=$(tabs)
strip=$(echo $after | sed -E 's/strip=(.*) model=(.*) active=.*/\1/'); model=$(echo $after | sed -E 's/strip=(.*) model=(.*) active=.*/\2/')
check "Terminal: three quick X clicks close three tabs" '[[ $(echo $strip | tr "|" "\n" | wc -l | tr -d " ") == 2 ]]' "$after"
check "Terminal: the strip and the terminals agree" '[[ $strip == $model ]]' "$after"
# ⌘1–9 reach Terminal's tabs (2026-11-04: they did nothing there).
active() { tabs | sed -E 's/.* active=//'; }
$U post "key cmd+1"; sleep 0.6
check "Terminal: ⌘1 selects the first tab" '[[ $(active) == 0 ]]' "$(active)"
$U post "key cmd+9"; sleep 0.6
check "Terminal: ⌘9 selects the last tab" '[[ $(active) == 1 ]]' "$(active)"
$U quit
echo "$failures failed"
exit $(( failures > 0 ))
