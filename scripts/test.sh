#!/bin/zsh
# Every test: Heron's own (swift test, as its public repository runs them), then the app's.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "==> Heron"
(cd Packages/Heron && swift test)
echo "==> Side"
xcodebuild -project SIDE.xcodeproj -scheme SIDE -destination 'platform=macOS' test -only-testing:SIDETests "$@" \
  | grep -E " error: |Test case.*failed|TEST (SUCCEEDED|FAILED)"
