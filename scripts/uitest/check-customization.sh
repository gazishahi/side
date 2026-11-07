#!/bin/zsh
# Customization (SIDE_DESIGN_SESSIONS_2026-11-06.md, session 3): the accent changes live, and
# the interface theme takes Side's surfaces from the editor theme's background, only for the
# appearance the theme was made for.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-customization.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-customization
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
tokens() { $U post tokens; sleep 0.6; grep '^\[tokens\]' $ROOT/side.log | tail -1; }
field() { echo "$1" | tr '|' '\n' | grep "$2" | sed "s/.*$2 //; s/ *$//"; }

$U launch; sleep 2
$U post "accent system" "interface-theme off" "theme-dark side" "theme-light side" "appearance dark"; sleep 1
base=$(tokens)
check "Side's own dark canvas" '[[ $(field "$base" canvas) == "21 23 26" ]]' "$base"

$U post "accent pink"; sleep 0.6
t=$(tokens)
check "the accent changes live" '[[ $(field "$t" accent) == "224 100 182" ]]' "$t"
mkdir -p $OUT/settings-pink
$U post "settings appearance"; sleep 1.2
$U post "snapshot-all $OUT/settings-pink"; sleep 1
$U post "settings-end"; sleep 0.5
$U post "think-track claude-code"; sleep 2
$U shot $OUT/agent-pink.png > /dev/null

$U post "theme-dark one-dark" "interface-theme on"; sleep 0.8
mkdir -p $OUT/settings-one-dark
$U post "settings appearance"; sleep 1.2
$U post "snapshot-all $OUT/settings-one-dark"; sleep 1
$U post "settings-end"; sleep 0.5
t=$(tokens)
check "the canvas is the theme's background" '[[ $(field "$t" canvas) == "40 44 52" ]]' "$t"
check "raised is a step lighter" '[[ $(field "$t" raised) != "40 44 52" && $(field "$t" raised) != "28 31 35" ]]' "$t"
$U shot $OUT/one-dark.png > /dev/null

$U post "theme-dark github-dark"; sleep 0.8
t=$(tokens)
check "a new theme retints at once" '[[ $(field "$t" canvas) == "13 17 23" ]]' "$t"

$U post "appearance light"; sleep 1
t=$(tokens)
check "light keeps Side's own under a dark-only choice" '[[ $(field "$t" canvas) == "244 244 246" ]]' "$t"
$U post "theme-light github-light"; sleep 0.8
t=$(tokens)
check "a white theme steps its canvas down" '[[ $(field "$t" raised) == "255 255 255" && $(field "$t" canvas) != "255 255 255" ]]' "$t"
$U shot $OUT/github-light.png > /dev/null

$U post "interface-theme off"; sleep 0.8
t=$(tokens)
check "off gives Side's own back" '[[ $(field "$t" canvas) == "244 244 246" ]]' "$t"

$U post "accent system" "theme-dark side" "theme-light side"; sleep 0.5
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
