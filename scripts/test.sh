#!/bin/zsh
# Every test: SideAgents', Alloy's and SideSessions' own (swift test, as their public repositories run them), then the app's.
# The app's tests run in a debug build, whose defaults are com.shahi.side.dev, not com.shahi.side:
# look there (`defaults read com.shahi.side.dev`) for a setting a test may have left behind.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "==> SideAgents"
(cd Packages/SideAgents && swift test)
echo "==> Alloy"
(cd Packages/Alloy && swift test)
echo "==> SideSessions"
scripts/build-ghostty-vt.sh > /dev/null
(cd Packages/SideSessions && swift test)
echo "==> Side"
# SwiftTerm 1.19+ runs a build plugin (SwiftTermBuildInfoPlugin); xcodebuild refuses an
# untrusted plugin unless told to skip validation. Xcode itself asks once.
xcodebuild -project SIDE.xcodeproj -scheme SIDE -destination 'platform=macOS' -skipPackagePluginValidation test -only-testing:SIDETests "$@" \
  | grep -E " error: |Test case.*failed|TEST (SUCCEEDED|FAILED)"
