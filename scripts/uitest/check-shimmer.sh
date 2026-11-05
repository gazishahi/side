#!/bin/zsh
# A working tab's shimmer still moves after going to another stage and back (2026-11-05: it
# stood still until another tab was chosen). Two captures apart must differ over the tab.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-shimmer.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-shimmer
rm -rf $OUT; mkdir -p $OUT/before $OUT/after
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
# How much the first tab's title changed between two frames (0 = still).
moved() { python3 -I -c "
from PIL import Image, ImageChops
a=Image.open('$1/frame-000.png').convert('L').crop((180,10,700,70))
b=Image.open('$1/frame-001.png').convert('L').crop((180,10,700,70))
print(sum(ImageChops.difference(a,b).getdata()))"; }

$U launch
$U post "window-size 1000 640" "stage run"; sleep 2.5
$U claude
$U type "FAKE_CLAUDE_TURN=40 claude
"
$U type "go
"
$U post "action newSession"; sleep 2
$U post "snapshots $OUT/before 2 500"; sleep 1.5
before=$(moved $OUT/before)
check "shimmering at first" '(( before > 0 ))' "$before"
$U post "stage make"; sleep 1
$U post "stage run"; sleep 1
$U post "snapshots $OUT/after 2 500"; sleep 1.5
after=$(moved $OUT/after)
check "still shimmering after another stage" '(( after > 0 ))' "$after"
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
