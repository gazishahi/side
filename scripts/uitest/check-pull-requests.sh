#!/bin/zsh
# Pull requests (SIDE_RFC_GIT_TRACKS.md, phase 3), with what `gh pr list` would say given to Side
# directly (the UI-test build has no GitHub sign-in): a branch whose open PR targets `staging`
# takes `staging` as its base, says where it came from, and shows its PR on its row and in the
# detail pane; a merged PR shows as merged and moves no base.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-pull-requests.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-pull-requests
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
detail() { $U post detail-dump; sleep 0.7; grep '^\[detail\]' $ROOT/side.log | tail -1; }

P=$ROOT/fixtures/pull-requests
rm -rf $P
mkdir -p $P && cd $P && git init -q -b main && echo "hello" > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
git branch staging && git checkout -q -b feature-x staging && echo "x" > x.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm x
git checkout -q main && git branch old-work
cd - > /dev/null

$U launch $P; sleep 2
$U post "window-size 1300 800" "stage tracks"; sleep 2
$U post 'pr-fake [{"number":42,"url":"https://github.com/o/r/pull/42","state":"OPEN","isDraft":false,"headRefName":"feature-x","baseRefName":"staging"},{"number":7,"url":"https://github.com/o/r/pull/7","state":"MERGED","isDraft":false,"headRefName":"old-work","baseRefName":"staging"}]'
sleep 1
$U post "select-track feature-x"; sleep 1
line=$(detail); echo "     $line"
check "an open PR's base is the branch's base, and its PR is in the detail" '[[ $line == *"Stacked on: staging"* && $line == *"Pull request: #42 · Open · into staging"* ]]' "$line"
$U shot $OUT/feature-x.png > /dev/null
$U post "select-track old-work"; sleep 1
line=$(detail); echo "     $line"
check "a merged PR shows as merged and moves no base" '[[ $line == *"Pull request: #7 · Merged"* && $line != *"Stacked on"* ]]' "$line"
$U shot $OUT/old-work.png > /dev/null

$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
