#!/bin/zsh
# The DMG's artwork, rendered from background.html and volume-icon.html with a Chromium browser
# (Helium, Chrome or Arc): background.tiff (1x and 2x, for Retina) and VolumeIcon.icns.
#
#   scripts/dmg/build-assets.sh <out-dir> <version>
set -euo pipefail
here=${0:A:h}
out=${1:?out dir}; version=${2:?version}
mkdir -p "$out"
browser=""
for candidate in "/Applications/Helium.app/Contents/MacOS/Helium" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                 "/Applications/Chromium.app/Contents/MacOS/Chromium" "/Applications/Arc.app/Contents/MacOS/Arc"; do
  [[ -x $candidate ]] && { browser=$candidate; break; }
done
[[ -n $browser ]] || { echo "No Chromium browser found to render the DMG artwork." >&2; exit 1; }
render() { # html, query, width, height, scale, out
  "$browser" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size=$3,$4 --force-device-scale-factor=$5 --virtual-time-budget=2000 \
    --screenshot="$6" "file://$here/$1$2" >/dev/null 2>&1
  [[ -s $6 ]] || { echo "Couldn't render $1" >&2; exit 1; }
}
render background.html "?version=$version" 640 400 1 "$out/background.png"
render background.html "?version=$version" 640 400 2 "$out/background@2x.png"
tiffutil -cathidpicheck "$out/background.png" "$out/background@2x.png" -out "$out/background.tiff" >/dev/null
render volume-icon.html "" 1024 1024 1 "$out/volume-1024.png"
set=$out/VolumeIcon.iconset; rm -rf "$set"; mkdir -p "$set"
for size in 16 32 128 256 512; do
  sips -z $size $size "$out/volume-1024.png" --out "$set/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$out/volume-1024.png" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o "$out/VolumeIcon.icns"
echo "$out/background.tiff $out/VolumeIcon.icns"
