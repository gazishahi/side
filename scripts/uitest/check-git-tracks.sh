#!/bin/zsh
# Every branch is a track (SIDE_RFC_GIT_TRACKS.md, phase 1): branches already in git are tracks
# with no adopting, one in a linked worktree in play and the rest resting; a branch made in a
# terminal shows up on its own; a deleted one goes and, re-created, comes back as it was; and
# Changes on the base shows its own uncommitted work.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-git-tracks.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-git-tracks
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
tracks() { $U post tracks-dump; sleep 0.7; grep '^\[tracks\]' $ROOT/side.log | tail -1; }
changes() { $U post changes-dump; sleep 0.7; grep '^\[changes\]' $ROOT/side.log | tail -1; }

P=$ROOT/fixtures/git-tracks
W=$ROOT/fixtures/git-tracks-wt
rm -rf $P $W
mkdir -p $P && cd $P && git init -q -b main && echo "hello" > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
git branch feature-old
git worktree add -q -b feature-live $W
cd - > /dev/null

$U launch $P; sleep 2
$U post "window-size 1200 760" "stage tracks"; sleep 2
line=$(tracks); echo "     $line"
check "branches in git are tracks, with no adopting" '[[ $line == *"feature-old:parked"* && $line == *"feature-live:waiting:worktree"* ]]' "$line"
check "the default branch is the base, not a track" '[[ $line != *"main:"* ]]' "$line"
$U shot $OUT/branches.png > /dev/null

git -C $P branch from-terminal; sleep 2
line=$(tracks); echo "     $line"
check "a branch made in a terminal shows up on its own" '[[ $line == *"from-terminal:parked"* ]]' "$line"

git -C $P branch -D -q feature-old; sleep 2
line=$(tracks); echo "     $line"
check "a deleted branch's track goes, kept aside" '[[ $line != *"feature-old:"* && $line == *"gone=feature-old"* ]]' "$line"
git -C $P branch feature-old; sleep 2
line=$(tracks); echo "     $line"
check "re-created, it comes back" '[[ $line == *"feature-old:parked"* && $line == *"gone= "* || $line == *"feature-old:parked"* && $line == *"gone=" ]]' "$line"

git -C $P checkout -q from-terminal; sleep 2
line=$(tracks); echo "     $line"
check "a checkout in a terminal makes its branch the window's track" '[[ $line == *"from-terminal:active:main*"* ]]' "$line"
git -C $P checkout -q main; sleep 2

echo "changed" >> $P/README.md
echo "new" > $P/notes.txt
$U post "stage review"; sleep 2.5
line=$(changes); echo "     $line"
check "Changes on the base shows its own work" '[[ $line == "[changes] main Base · 2 uncommitted changes files=2" ]]' "$line"
$U shot $OUT/changes-base.png > /dev/null

$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
