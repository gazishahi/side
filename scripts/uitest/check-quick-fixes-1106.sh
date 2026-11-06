#!/bin/zsh
# The owner's quick fixes, 2026-11-06: a folder holding one repository just inside offers it
# instead of "Initialize Git…"; the Agent stage's pill names the default agent, not Heron, with
# no track; every stage's tooltip has its shortcut; the Markdown preview draws <img> pictures,
# badges and its pictures at their own height.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-quick-fixes-1106.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-quick-fixes
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
last() { $U post "$1"; sleep 0.6; grep "$2" $ROOT/side.log | tail -1; }

F=$ROOT/fixtures/outer
mkdir -p $F/inner $F/notes
[[ -d $F/inner/.git ]] || (cd $F/inner && git init -q && echo x > a && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)

$U launch
$U post "window-size 1200 760" "project-switch $F"; sleep 2.5
$U post "stage think"; sleep 1.5
$U shot $OUT/agent.png > /dev/null
pill=$(last agent-pill '^\[agent-pill\]')
echo "     $pill"
check "with no track the agent pill doesn't say Heron" '[[ $pill != *Heron* ]]' "$pill"
tips=$(last stage-tips '^\[stage-tips\]')
echo "     $tips"
check "each stage's tooltip names its shortcut" '[[ $tips == *"Agent  ⌥⌘2"* && $tips == *"Terminal  ⌥⌘4"* ]]' "$tips"
$U post "stage review"; sleep 1.2
$U shot $OUT/changes.png > /dev/null
$U post "open $F/notes/README.md"; sleep 1.5
$U post "toggle-preview"; sleep 1.5
$U shot $OUT/preview.png > /dev/null
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
