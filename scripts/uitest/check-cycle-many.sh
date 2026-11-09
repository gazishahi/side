#!/bin/zsh
# The ⌃⇥ strip with many projects open (the owner, 2026-11-09: six ran off both sides, and the
# pointer did nothing). One row always: wider, then smaller tiles, then a row that slides under
# faded edges; every tile that shows is whole. Hover picks a tile, a click switches.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-cycle-many.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-cycle-many
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
cycle() { $U post cycle-dump; sleep 0.7; grep '^\[cycle\]' $ROOT/side.log | tail -1; }
field() { echo "$1" | sed -E "s/.* $2=([^ ]+).*/\1/"; }
# The panel inside the window: x ≥ 0 and x + width ≤ the window's width.
inside() { echo "$1" | sed -E 's/.*frame=\(([-0-9.]+), [-0-9.]+, ([0-9.]+), [0-9.]+\).*/\1 \2/'; }

names=(alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo)
for name in $names; do
  dir=$ROOT/fixtures/$name
  [[ -d $dir/.git ]] || (mkdir -p $dir && cd $dir && git init -q && echo x > a.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
done

$U launch
$U post "window-size 1280 800"; sleep 1
opened=1
for count in 6 10 12; do
  while (( opened < count )); do $U post "project-switch $ROOT/fixtures/${names[$opened]}"; sleep 2; opened=$((opened + 1)); done
  $U post cycle; sleep 0.4
  line=$(cycle)
  echo "     $count: $line"
  read x w <<< "$(inside "$line")"
  check "$count open: the panel is inside the window" '(( ${x%.*} >= 0 && ${x%.*} + ${w%.*} <= 1280 ))' "x=$x w=$w"
  $U shot $OUT/open-$count.png > /dev/null
  [[ $count == 6 ]] && check "6 open: every tile shows, full size" '[[ $(field "$line" visible) == 6 && $(field "$line" tile) == 88.0 ]]' "$line"
  [[ $count == 10 ]] && check "10 open: smaller tiles, all showing" '[[ $(field "$line" visible) == 10 ]] && (( $(field "$line" tile | cut -d. -f1) < 88 ))' "$line"
  # Hover the first tile (it shows: the pick is the second).
  $U post "cycle-hover 0"; sleep 0.4
  line=$(cycle)
  first=$(echo $line | sed -E 's/.*entries=\["([^"]+)".*/\1/')
  check "$count open: hovering a tile picks it" '[[ $line == *"selected=$first "* ]]' "$line"
  if [[ $count == 12 ]]; then
    check "12 open: the smallest tiles, the row slides" '[[ $(field "$line" tile) == 64.0 ]] && (( $(field "$line" visible) < 12 ))' "$line"
    for step in 1 2 3 4 5 6 7 8 9 10 11; do
      $U post cycle; sleep 0.3
      line=$(cycle)
      check "the pick shows whole at step $step" '[[ $(field "$line" pickShows) == true ]]' "$line"
      [[ $step == 6 ]] && $U shot $OUT/slid-12.png > /dev/null
    done
  fi
  $U post "cycle-click 2"; sleep 1.5
  check "$count open: a click switches and closes it" '[[ $(cycle) == *closed* ]]'
done
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
