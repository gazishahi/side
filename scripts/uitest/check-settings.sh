#!/bin/zsh
# Every Settings pane, captured for looking at, in light and dark (SIDE_DESIGN_POLISH_0.5.md §5).
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-settings.sh [pane…]
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-settings
rm -rf $OUT; mkdir -p $OUT
panes=(general notifications agents usage appearance languages shortcuts history)
(( $# )) && panes=($@)
$U launch
$U post "settings general"; sleep 1.5
$U post "settings-size ${SETTINGS_SIZE:-1000 700}"; sleep 1
for look in light dark; do
  $U post "appearance $look"; sleep 1
  for pane in $panes; do
    mkdir -p $OUT/$look-$pane
    $U post "settings $pane"; sleep 1.2
    $U post "snapshot-all $OUT/$look-$pane"; sleep 1
  done
done
# Shortcuts' filters: by keys, what two commands share, a search with no match.
if (( ${panes[(Ie)shortcuts]} )); then
  n=0
  $U post "appearance light" "settings shortcuts"; sleep 1
  for step in "shortcuts-toggle Editor" "shortcuts-toggle Window" "shortcuts-toggle Editor" "shortcuts-toggle Window" "shortcuts-keys cmd k" "shortcuts-keys none" "shortcuts-filter conflicts" "shortcuts-filter none" "shortcuts-search zzz" "shortcuts-search tab"; do
    n=$((n + 1)); name=$(printf "%02d-%s" $n ${step// /-})
    mkdir -p $OUT/$name
    $U post "$step"; sleep 0.8
    $U post "snapshot-all $OUT/$name"; sleep 1
  done
fi
$U quit
ls -d $OUT/*/ | wc -l
