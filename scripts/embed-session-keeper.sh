#!/bin/zsh
# Xcode build phase "Embed session keeper": builds Packages/SideSessions' keeper and the notifier
# app (Helpers/SideNotifier), both as apps in Side.app/Contents/Helpers, signed like Side
# (SIDE_RFC_SESSION_RESTORE.md). Runs in Xcode's
# environment; swift build runs in a clean one, since Xcode's settings confuse SwiftPM.
set -euo pipefail
cd "$SRCROOT"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
scripts/build-ghostty-vt.sh > /dev/null
config=debug
[[ "${CONFIGURATION:-Debug}" == Release ]] && config=release
scratch="${OBJROOT:-build}/SideSessions"
/usr/bin/env -i PATH="$PATH" HOME="$HOME" DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
  xcrun swift build -c "$config" --package-path Packages/SideSessions --product SideSessionKeeper --scratch-path "$scratch" > "$scratch.log" 2>&1 \
  || { tail -30 "$scratch.log"; exit 1; }
dest="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$dest"
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
# Hardened runtime and a timestamp for release builds, which are notarized.
timestamp=--timestamp=none
[[ "$config" == release ]] && timestamp=--timestamp
icon="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/AppIcon.icns"

# The keeper, as an app of its own: macOS's privacy settings hold a grant for a bundle
# identifier across updates, and a keeper outlives the Side that started it, so it answers for
# its terminals' commands itself (Helpers/SessionKeeper/Info.plist). Built beside the
# destination, then renamed over it: never written in place. A running process whose executable
# changes under it is killed by the kernel (an invalid code page); keepers run a copy anyway
# (SessionKeepers.keeperURL).
keeper="$dest/Side Session Keeper.app"
staging="$dest/.Side Session Keeper.staged.app"
rm -rf "$staging"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
sed -e "s/\$(MARKETING_VERSION)/${MARKETING_VERSION:-0}/" -e "s/\$(CURRENT_PROJECT_VERSION)/${CURRENT_PROJECT_VERSION:-0}/" -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/${PRODUCT_BUNDLE_IDENTIFIER:-com.shahi.side}/" \
  Helpers/SessionKeeper/Info.plist > "$staging/Contents/Info.plist"
cp -f "$scratch/$config/SideSessionKeeper" "$staging/Contents/MacOS/SideSessionKeeper"
[[ -f "$icon" ]] && cp "$icon" "$staging/Contents/Resources/AppIcon.icns"
if [[ -n "$identity" && "$identity" != "-" ]]; then
  codesign --force --sign "$identity" --options runtime $timestamp --entitlements Helpers/SessionKeeper/SessionKeeper.entitlements "$staging"
else
  codesign --force --sign - --entitlements Helpers/SessionKeeper/SessionKeeper.entitlements "$staging"
fi
rm -rf "$keeper"
mv "$staging" "$keeper"
# The bare keeper of earlier builds.
rm -f "$dest/SideSessionKeeper"

# The notifier: a tiny background app keepers run to post notifications under Side's name.
notifier="$dest/Side Notifier.app"
staging="$dest/.Side Notifier.staged.app"
rm -rf "$staging"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
sed -e "s/\$(MARKETING_VERSION)/${MARKETING_VERSION:-0}/" -e "s/\$(CURRENT_PROJECT_VERSION)/${CURRENT_PROJECT_VERSION:-0}/" -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/${PRODUCT_BUNDLE_IDENTIFIER:-com.shahi.side}/" \
  Helpers/SideNotifier/Info.plist > "$staging/Contents/Info.plist"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos15.0" Helpers/SideNotifier/main.swift -o "$staging/Contents/MacOS/Side Notifier"
[[ -f "$icon" ]] && cp "$icon" "$staging/Contents/Resources/AppIcon.icns"
if [[ -n "$identity" && "$identity" != "-" ]]; then
  codesign --force --sign "$identity" --options runtime $timestamp "$staging"
else
  codesign --force --sign - "$staging"
fi
rm -rf "$notifier"
mv "$staging" "$notifier"
