#!/bin/zsh
# The activity pill's project marks (2026-11-07): Claude Code working in another project shows
# that project's mark; two or three show their marks as a deck; activity in the window's
# own project shows none. Drawn as a deck: the most pressing in front, the rest behind it.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-activity-marks.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-activity-marks
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
dump() { $U post activity-dump; sleep 0.7; awk '/^\[activity\]/{block=""} {block=block $0 "\n"} END{printf "%s", block}' $ROOT/side.log; }
field() { dump | awk -v key="$1" '$1==key{ $1=""; sub(/^ /,""); print }' | tail -1; }

for name in marks-alpha marks-beta marks-gamma marks-delta; do
  P=$ROOT/fixtures/$name
  [[ -d $P/.git ]] || (mkdir -p $P && cd $P && git init -q && echo "# $name" > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
done
A=$ROOT/fixtures/marks-alpha B=$ROOT/fixtures/marks-beta C=$ROOT/fixtures/marks-gamma D=$ROOT/fixtures/marks-delta

$U launch $A
$U post "window-size 1200 760" "stage run"; sleep 2.5
$U claude
$U type "FAKE_CLAUDE_TURN=40 claude
"
$U type "work
"
$U post "stage make"; sleep 1
check "in this window's project: no mark" '[[ $(field marks) == "" ]]' "$(field marks)"

$U post "project-switch $B"; sleep 2.5
$U post "stage make"; sleep 1
check "in another project: its mark" '[[ $(field marks) == "marks-alpha" ]]' "$(field marks) / $(field pill)"
$U shot $OUT/one.png > /dev/null

$U post "stage run"; sleep 2.5
$U claude
$U type "FAKE_CLAUDE_TURN=40 claude
"
$U type "work
"
$U post "project-switch $C"; sleep 2.5
$U post "stage make"; sleep 1
marks=$(field marks)
check "two other projects: two marks" '[[ $marks == "marks-alpha,marks-beta" || $marks == "marks-beta,marks-alpha" ]]' "$marks / $(field pill)"
$U shot $OUT/two.png > /dev/null

$U post "stage run"; sleep 2.5
$U claude
$U type "FAKE_CLAUDE_TURN=40 claude
"
$U type "work
"
$U post "project-switch $D"; sleep 2.5
$U post "stage make"; sleep 1
marks=$(field marks)
check "three other projects: three marks" '[[ $(echo $marks | tr , "\n" | sort | tr "\n" " ") == "marks-alpha marks-beta marks-gamma " ]]' "$marks"
$U shot $OUT/three.png > /dev/null
$U post activity-open; sleep 1
check "the list opens" '[[ $(field popover) == true ]]' "$(field popover)"
mkdir -p $OUT/list; $U post "snapshot-all $OUT/list"; sleep 1.5

$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
