#!/bin/zsh
# Switching in place (SIDE_RFC_GIT_TRACKS.md, decision 4): a branch checked out nowhere is checked
# out in the main folder, as git does; with uncommitted changes there, or something running
# there, it opens in a folder of its own instead and nothing in the main folder moves; going
# back to the base checks the default branch out again, and is refused, changing nothing, when
# that isn't safe.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-switch-in-place.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-switch-in-place
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
tracks() { $U post tracks-dump; sleep 0.7; grep '^\[tracks\]' $ROOT/side.log | tail -1; }
head_of() { git -C $P symbolic-ref --short HEAD; }

P=$ROOT/fixtures/in-place
rm -rf $P
mkdir -p $P && cd $P && git init -q -b main && echo "hello" > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
for b in feat-a feat-b feat-c; do git branch $b; done
cd - > /dev/null
worktrees() { git -C $P worktree list | wc -l | tr -d ' '; }

$U launch $P; sleep 2
$U post "window-size 1200 760" "stage make"; sleep 1.5
$U post "track-switch feat-a"; sleep 2.5
line=$(tracks); echo "     $line"
check "a branch checked out nowhere is checked out in the main folder" '[[ $(head_of) == feat-a && $line == *"feat-a:active:main*"* && $(worktrees) == 1 ]]' "$(head_of) $(worktrees) $line"

echo "edit" >> $P/README.md
$U post "track-switch "; sleep 2.5
line=$(tracks); echo "     $line"
check "back to the base with uncommitted changes: refused, nothing changed" '[[ $(head_of) == feat-a && $line == *"feat-a:active:main*"* && $(tail -1 $P/README.md) == edit ]]' "$(head_of) $line"
mkdir -p $OUT/refused; $U post "snapshot-all $OUT/refused"; sleep 1.5
$U post "key escape"; sleep 0.5
$U post "track-switch feat-b"; sleep 3
line=$(tracks); echo "     $line"
check "uncommitted changes in the main folder: its own folder, and the main folder untouched" \
  '[[ $(head_of) == feat-a && $line == *"feat-b:active:worktree*"* && $(tail -1 $P/README.md) == edit ]]' "$(head_of) $line"
git -C $P checkout -q -- README.md

$U post "track-switch feat-a"; sleep 2
$U post "track-switch "; sleep 3
line=$(tracks); echo "     $line"
check "back to the base: the default branch is checked out again" '[[ $(head_of) == main && $line != *"*"* ]]' "$(head_of) $line"

$U post "stage run"; sleep 3
$U type "sleep 60
"
sleep 1
$U post "track-switch feat-c"; sleep 3
line=$(tracks); echo "     $line"
check "something running in the main folder: its own folder" '[[ $(head_of) == main && $line == *"feat-c:active:worktree*"* ]]' "$(head_of) $line"
$U shot $OUT/busy.png > /dev/null

$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
