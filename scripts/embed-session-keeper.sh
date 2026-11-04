#!/bin/zsh
# Xcode build phase "Embed session keeper": builds Packages/SideSessions' keeper and puts it in
# Side.app/Contents/Helpers, signed like the app (SIDE_RFC_SESSION_RESTORE.md). Runs in Xcode's
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
cp -f "$scratch/$config/SideSessionKeeper" "$dest/SideSessionKeeper"
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -n "$identity" && "$identity" != "-" ]]; then
  # Hardened runtime and a timestamp for release builds, which are notarized.
  timestamp=--timestamp=none
  [[ "$config" == release ]] && timestamp=--timestamp
  codesign --force --sign "$identity" --options runtime $timestamp "$dest/SideSessionKeeper"
else
  codesign --force --sign - "$dest/SideSessionKeeper"
fi
