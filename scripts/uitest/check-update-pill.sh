#!/bin/zsh
# The update pill's states (SIDE_DESIGN_POLISH_0.5.md §4), light and dark: plain glass for status,
# a fill only for an action waiting on you; the × on hover in the mark's place; up to date closes
# up to its checkmark and goes. Crops of the bar's trailing end in $SIDE_UIT/check-update-pill.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-update-pill.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-update-pill
rm -rf $OUT; mkdir -p $OUT/leave
crop() { sips -c 120 760 --cropOffset 1140 1440 $1 --out $1 >/dev/null; }

$U launch
$U post "window-size 1100 640"; sleep 1
for look in light dark; do
  $U post "appearance $look"; sleep 0.8
  for state in checking uptodate available "downloading 0.42" preparing ready failed; do
    $U post "update $state"; sleep 0.9
    name=${state// /-}
    $U shot $OUT/$look-$name.png >/dev/null; crop $OUT/$look-$name.png
  done
  for state in uptodate available failed; do
    $U post "update $state"; sleep 0.6; $U post "update hover"; sleep 0.4
    $U shot $OUT/$look-$state-hover.png >/dev/null; crop $OUT/$look-$state-hover.png
    $U post "update hover off"; sleep 0.3
  done
done
$U post "update uptodate"; sleep 0.8
$U post "update none" "snapshots $OUT/leave 12 40"; sleep 1.5
for f in $OUT/leave/*.png; do crop $f; done
$U quit
echo "captures in $OUT"
