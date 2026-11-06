#!/bin/zsh
# A project switch: the indicator above the chip shows each project's own mark (its logo when it
# has one), and it and the track pill spring to their new widths rather than jumping. A folder
# that isn't a repository is "Base", not " · Base" (the owner, 2026-11-05).
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-project-indicator.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-project-indicator
rm -rf $OUT; mkdir -p $OUT/motion $OUT/pill
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
indicator() { $U post indicator-dump; sleep 0.5; grep '^\[indicator\]' $ROOT/side.log | tail -1; }

for name in webapp a-much-longer-project-name; do
  dir=$ROOT/fixtures/$name
  [[ -d $dir/.git ]] || (mkdir -p $dir && cd $dir && git init -q && echo x > a.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
done
# A logo of its own: a red square.
[[ -f $ROOT/fixtures/webapp/logo.png ]] || sips -s format png -z 64 64 /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericFolderIcon.icns --out $ROOT/fixtures/webapp/logo.png > /dev/null
mkdir -p $ROOT/fixtures/plain-folder

$U launch
$U post "window-size 1100 700"; sleep 1
for name in webapp a-much-longer-project-name plain-folder; do $U post "project-switch $ROOT/fixtures/$name"; sleep 2.5; done

line=$(indicator)
echo "     $line"
check "outside a repository the pill says Base" '[[ $line == *"pill=Base pillWidth"* ]]' "$line"
$U post "project-switch $ROOT/fixtures/webapp"; sleep 0.4
first=$(indicator)
echo "     $first"
check "it shows, the current project named after its mark" '[[ $first == *"shown=true"* && $first == *"|webapp|"* ]]' "$first"
# Again while it shows: frames of the change.
$U post "project-switch $ROOT/fixtures/a-much-longer-project-name" "snapshots $OUT/motion 8 40"; sleep 1
second=$(indicator)
echo "     $second"
check "the name moved to the next project's mark" '[[ $second == *"|a-much-longer-project-name"* ]]' "$second"
w1=$(echo $first | sed -E 's/.* width=([0-9.]+).*/\1/'); w2=$(echo $second | sed -E 's/.* width=([0-9.]+).*/\1/')
check "and the indicator widened for it" '(( w2 > w1 + 40 ))' "$w1 -> $w2"
# To the folder that isn't a repository: the track pill closes up from "master · Base" to "Base".
$U post "project-switch $ROOT/fixtures/plain-folder" "snapshots $OUT/pill 8 40"; sleep 1
third=$(indicator)
echo "     $third"
p1=$(echo $second | sed -E 's/.*pillWidth=([0-9.]+).*/\1/'); p2=$(echo $third | sed -E 's/.*pillWidth=([0-9.]+).*/\1/')
check "the track pill closed up to Base" '[[ $third == *"pill=Base pillWidth"* ]] && (( p2 < p1 - 20 ))' "$p1 -> $p2"
$U shot $OUT/after.png > /dev/null
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
