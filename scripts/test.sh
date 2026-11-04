#!/bin/zsh
# Every test: Heron's, Alloy's and SideSessions' own (swift test, as their public repositories run them), then the app's.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "==> Heron"
(cd Packages/Heron && swift test)
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
