#!/bin/zsh
# The board (SIDE_RFC_GIT_TRACKS.md, phase 2): Branches lists what runs on each branch under
# its row (a Claude Code working, on the base and on a branch in its own worktree; switching
# with Terminal in front starts the branch's terminal there).
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-board.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-board
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
board() { $U post board-dump; sleep 0.7; grep '^\[board\]' $ROOT/side.log | tail -1; }

P=$ROOT/fixtures/board
W=$ROOT/fixtures/board-wt
rm -rf $P $W
mkdir -p $P && cd $P && git init -q -b main && echo "hello" > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
git worktree add -q -b feature-board $W
cd - > /dev/null

$U launch $P; sleep 2
$U post "window-size 1300 800" "stage run"; sleep 2.5
$U claude
$U type "FAKE_CLAUDE_TURN=60 claude
"
$U type "work on the base
"
$U post "track-switch feature-board"; sleep 2.5
# Switched with Terminal in front: the branch's terminal starts there (it was blank before).
sleep 2.5
$U claude
$U type "FAKE_CLAUDE_TURN=60 claude
"
$U type "work on the branch
"
$U shot $OUT/branch-run.png > /dev/null
$U post "stage tracks"; sleep 2
line=$(board); echo "     $line"
check "each branch lists what runs on it" '[[ $line == *"(base): "*"Working"* && $line == *"feature-board: "*"Working"* ]]' "$line"
$U shot $OUT/board.png > /dev/null

$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
