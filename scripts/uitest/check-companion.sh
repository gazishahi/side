#!/bin/zsh
# The companion (SIDE_DESIGN_SESSIONS_2026-11-06.md, session 1): a Terminal session docked
# beside the Editor, its tabs ending where it begins; Follow showing the file a running program
# changed, and stopping at a click in the Editor; hidden in a narrow window until asked for,
# then floating; hidden on Terminal; back in Terminal's tabs when closed.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-companion.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-companion
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
state() { $U post companion-dump; sleep 0.7; grep '^\[companion\]' $ROOT/side.log | tail -1; }

P=$ROOT/fixtures/companion-project
rm -rf $P; mkdir -p $P/src
(cd $P && git init -q && for i in {1..80}; do echo "let value$i = $i"; done > src/main.swift && echo "let other = 1" > src/other.swift \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)

$U launch $P; sleep 1
$U post "window-size 1400 860" "stage Make"; sleep 1
$U post companion-toggle; sleep 2
line=$(state); echo "     $line"
check "opens docked beside the Editor" '[[ $line == *"mode=docked width=480 stage=920"* && $line == *"follow=on"* && $line == *"stageName=Editor"* ]]' "$line"
$U shot $OUT/docked.png > /dev/null

# A program running in it changes line 41: the Editor shows that file.
$U post "companion-type sh -c 'sleep 1; sed -i \"\" \"41s/.*/let changed = true/\" src/main.swift; sleep 4'"; sleep 4
line=$(state); echo "     $line"
check "Follow shows the file the program changed" '[[ $line == *"file=main.swift"* ]]' "$line"
$U shot $OUT/followed.png > /dev/null
sleep 2

$U post companion-editor-click; sleep 0.5
line=$(state); echo "     $line"
check "a click in the Editor turns Follow off" '[[ $line == *"follow=off"* ]]' "$line"
$U post "companion-type sh -c 'sleep 1; echo \"let more = 2\" >> src/other.swift; sleep 3'"; sleep 4
line=$(state); echo "     $line"
check "with Follow off, the Editor stays put" '[[ $line == *"file=main.swift"* ]]' "$line"
sleep 1

$U post "window-size 860 700"; sleep 1.5
line=$(state); echo "     $line"
check "a narrow window hides it" '[[ $line == *"mode=hidden"* ]]' "$line"
$U post companion-toggle; sleep 1
line=$(state); echo "     $line"
check "the toggle floats it there" '[[ $line == *"mode=floating"* ]]' "$line"
$U shot $OUT/floating.png > /dev/null

$U post "window-size 1400 860"; sleep 1.5
line=$(state); echo "     $line"
check "wide again, it docks" '[[ $line == *"mode=docked"* ]]' "$line"
$U post "stage Run"; sleep 1.5
line=$(state); echo "     $line"
check "hidden on Terminal" '[[ $line == *"mode=hidden"* ]]' "$line"
$U post "stage Make"; sleep 1.5
$U post "companion-type echo still-here"; sleep 1
$U shot $OUT/after-terminal.png > /dev/null
$U post "stage Review"; sleep 1.5
line=$(state); echo "     $line"
check "beside Changes too" '[[ $line == *"mode=docked"* && $line == *"stageName=Changes"* ]]' "$line"
$U shot $OUT/changes.png > /dev/null

$U post "stage Make" companion-toggle; sleep 1
line=$(state); echo "     $line"
check "the toggle sends it back to Terminal's tabs" '[[ $line == *"none"* ]]' "$line"
$U shot $OUT/closed.png > /dev/null

$U quit
echo "screenshots: $OUT"
exit $failures
