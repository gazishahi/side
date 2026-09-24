#!/bin/zsh
# Every test: Heron's and Alloy's own (swift test, as their public repositories run them), then the app's.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "==> Heron"
(cd Packages/Heron && swift test)
echo "==> Alloy"
(cd Packages/Alloy && swift test)
echo "==> Side"
xcodebuild -project SIDE.xcodeproj -scheme SIDE -destination 'platform=macOS' test -only-testing:SIDETests "$@" \
  | grep -E " error: |Test case.*failed|TEST (SUCCEEDED|FAILED)"
