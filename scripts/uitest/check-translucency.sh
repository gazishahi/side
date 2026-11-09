#!/bin/zsh
# Translucent background (Settings › Appearance): the window's backdrop shows a loud pattern
# behind the window through the stages and the terminal, the editor only with "Editor too", and
# turning it off gives the solid canvas back.
#
#   scripts/uitest/uitest.sh build && scripts/uitest/check-translucency.sh
set -uo pipefail
U=$(dirname "$0")/uitest.sh
ROOT=${SIDE_UIT:-/tmp/side-uit}
OUT=$ROOT/check-translucency
rm -rf $OUT; mkdir -p $OUT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (${3:-})"; failures=$((failures + 1)); fi; }
# How far apart the white and the black stripe behind the window read at a height (0–1) of a
# capture: 0 is a solid surface.
spread() {
  python3 -c "
from PIL import Image
im = Image.open('$1').convert('L'); w, h = im.size; y = int(h * $2)
print(abs(im.getpixel((int(w * 11 / 12), y)) - im.getpixel((int(w * 7 / 12), y))))"
}
shot() { $U post "snapshot-screen $OUT/$1.png"; sleep 1; }

$U launch; sleep 2
$U post "appearance dark" "translucent off" "translucent-editor off" "minimap on" "window-size 1280 800"; sleep 1
$U post "behind on"; sleep 0.5
$U post "stage think"; sleep 1.5; shot think-off
check "off is solid" '(( $(spread $OUT/think-off.png 0.3) <= 2 ))' "$(spread $OUT/think-off.png 0.3)"

$U post "translucent on"; sleep 1; shot think-on
check "Agent's stage shows through" '(( $(spread $OUT/think-on.png 0.3) >= 10 ))' "$(spread $OUT/think-on.png 0.3)"

$U post "stage run"; sleep 2; shot run-on
check "the terminal shows through" '(( $(spread $OUT/run-on.png 0.6) >= 6 ))' "$(spread $OUT/run-on.png 0.6)"

# The Editor stage is one surface: the corners above and below the minimap match the text's
# background, solid or translucent (they showed the glass beside a solid editor, 2026-11-08).
# Over the black stripe, where the backdrop's own tone is what differs.
corners() {
  python3 -c "
from PIL import Image
im = Image.open('$1').convert('L'); w, h = im.size; x = w - 40
# In the top row; beside the minimap, past its lines; under the search button.
above, beside, below = im.getpixel((x, 20)), im.getpixel((x, int(h * 0.7))), im.getpixel((x, h - 8))
print(max(abs(above - beside), abs(below - beside)))"
}
$U post "open $ROOT/repo/docs/SIDE_RFC_SESSIONS.md"; sleep 2; shot editor-solid
check "the editor stays solid" '(( $(spread $OUT/editor-solid.png 0.6) <= 2 ))' "$(spread $OUT/editor-solid.png 0.6)"
$U post "behind black"; sleep 0.5; shot editor-solid-black
check "solid: the corners match the editor" '(( $(corners $OUT/editor-solid-black.png) <= 2 ))' "$(corners $OUT/editor-solid-black.png)"
$U post "translucent-editor on"; sleep 1; shot editor-on-black
check "Editor too: the corners match the editor" '(( $(corners $OUT/editor-on-black.png) <= 2 ))' "$(corners $OUT/editor-on-black.png)"
$U post "behind on"; sleep 0.5; shot editor-on
check "Editor too lets it through as the terminal does" '(( $(spread $OUT/editor-on.png 0.6) >= 10 ))' "$(spread $OUT/editor-on.png 0.6)"

# The switches themselves, clicked as a person would: each stays where it's put.
$U post "translucent off" "translucent-editor off"; sleep 0.5
$U post "settings appearance"; sleep 1.5
switched() { $U post "settings-switch $1"; sleep 0.8; grep "^\[switch\] $1 " $ROOT/side.log | tail -1 | awk '{print $NF}'; }
check "Translucent background switches on" '[[ $(switched "Translucent background") == on ]]'
check "Editor too switches on and stays" '[[ $(switched "Editor too") == on ]]'
check "Editor too switches off" '[[ $(switched "Editor too") == off ]]'
$U post "settings-end"; sleep 0.5

$U post "appearance light"; sleep 1.5; shot editor-light
$U post "translucent off" "translucent-editor off" "behind off" "appearance dark"; sleep 0.5
$U quit
echo "$failures failed; captures in $OUT"
exit $(( failures > 0 ))
