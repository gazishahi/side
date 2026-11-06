#!/bin/zsh
# Settings › Appearance › Surfaces: Liquid Glass or Solid, applied on restart (the row to restart
# appears once the choice differs from what's drawn); solid surfaces draw the bar and panels.
# The Dock icon's menu: the open projects with what they're doing, recent ones, New Window and
# Open Project… (2026-11-06).
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-surfaces-and-dock.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-surfaces; rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }

$U launch; sleep 1.5
$U post "window-size 1100 700" "project-switch $ROOT/fixtures/webapp"; sleep 2.5
$U post "project-switch $ROOT/fixtures/pdf-project"; sleep 2.5
$U post "dock-dump"; sleep 0.6
dock=$(grep '^\[dock\]' $ROOT/side.log | tail -1); echo "     $dock"
check "the Dock menu lists the open projects, then New Window and Open Project…" '[[ $dock == *"pdf-project"*"webapp"* && $dock == *"New Window | Open Project…"* ]]' "$dock"
$U post "settings appearance"; sleep 1.5
mkdir -p $OUT/before $OUT/after; $U post "snapshot-all $OUT/before"; sleep 1
$U post "settings-popup Surfaces 1"; sleep 1
$U post "snapshot-all $OUT/after"; sleep 1
$U quit
SIDE_SURFACES=solid $U launch > /dev/null; sleep 1.5
$U post "window-size 1100 700" "stage make" "open $ROOT/repo/README.md"; sleep 2
$U shot $OUT/solid.png > /dev/null
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
