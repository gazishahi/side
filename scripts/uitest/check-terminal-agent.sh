#!/bin/zsh
# The owner's 2026-11-04 report, as a check: Claude Code in a Terminal tab, a message sent, then
# Editor. Side must name the program `claude` throughout (not the terminal's own replies, not the
# message), and the activity pill appearing must not widen the window.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-terminal-agent.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-terminal-agent
mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }
program() { $U post activity-dump; sleep 0.7; grep -a "^session " $ROOT/side.log | tail -1 | sed -E 's/.*program=(.*) unseen=.*/\1/'; }
width() { sips -g pixelWidth $1 | awk '/pixelWidth/{print $2}'; }

$U launch
$U post "window-size 760 560" "stage run"; sleep 2.5
$U shot $OUT/start.png > /dev/null
before=$(width $OUT/start.png)
$U claude
$U type "claude
"
sleep 1
check "names the program once started" '[[ $(program) == claude ]]'
$U type "fix the login race
"
check "names the program while it works" '[[ $(program) == claude ]]'
$U shot $OUT/working.png > /dev/null
$U post "stage make"; sleep 2
$U shot $OUT/editor.png > /dev/null
check "keeps the window's width while it works ($before → $(width $OUT/working.png))" '[[ $(width $OUT/working.png) == $before ]]'
check "keeps the window's width in Editor ($before → $(width $OUT/editor.png))" '[[ $(width $OUT/editor.png) == $before ]]'
sleep 4
check "names the program after its turn" '[[ $(program) == claude ]]'
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
