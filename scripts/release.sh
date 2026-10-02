#!/bin/zsh
# Builds a Developer ID–signed, notarized Side.dmg (docs/SIDE_DISTRIBUTION.md).
#
# One-time setup on the machine that ships:
#   1. A "Developer ID Application" certificate in the login keychain (Xcode › Settings ›
#      Accounts › Manage Certificates, or developer.apple.com).
#   2. Notary credentials stored once, never in this repo:
#        xcrun notarytool store-credentials side-notary --apple-id <you> --team-id <TEAM>
#   3. export SIDE_TEAM_ID=<TEAM>  (and SIDE_NOTARY_PROFILE if not "side-notary")
#
#   4. Sparkle's update-signing key, once: generate_keys --account side (the private key stays in
#      the login Keychain; the public key is SUPublicEDKey in SIDE/Info.plist).
#
# Usage: scripts/release.sh            full build, notarize, staple
#        scripts/release.sh --dry-run  build and sign only; no notarization
set -euo pipefail

cd "$(dirname "$0")/.."
TEAM="${SIDE_TEAM_ID:?Set SIDE_TEAM_ID to your Apple Developer Team ID}"
PROFILE="${SIDE_NOTARY_PROFILE:-side-notary}"
DRY_RUN=0; [[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

SETTINGS=$(xcodebuild -project SIDE.xcodeproj -scheme SIDE -configuration Release -skipPackagePluginValidation -showBuildSettings 2>/dev/null || true)
VERSION=$(awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}' <<< "$SETTINGS")
BUILD=$(awk -F' = ' '/ CURRENT_PROJECT_VERSION /{print $2; exit}' <<< "$SETTINGS")
# Nothing is deleted or built without a real version: an empty one made OUT build/release/, and
# the rm -rf below took every earlier release with it, dSYMs included (2026-09-30 audit, REL-1).
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || { echo "couldn't read MARKETING_VERSION (got '$VERSION'); nothing was deleted" >&2; exit 1; }
[[ "$BUILD" =~ '^[0-9]+(\.[0-9]+)*$' ]] || { echo "couldn't read CURRENT_PROJECT_VERSION (got '$BUILD'); nothing was deleted" >&2; exit 1; }
OUT="build/release/$VERSION"
SPM="build/spm"
RELEASES_REPO="${SIDE_RELEASES_REPO:-gazishahi/side-releases}"
ARCHIVE="$OUT/Side.xcarchive"
APP="$OUT/export/Side.app"
DMG="$OUT/Side-$VERSION.dmg"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "warning: the working tree has uncommitted changes; this build won't match a commit." >&2
fi
rm -rf "$OUT"; mkdir -p "$OUT"
echo "Side $VERSION ($BUILD), team $TEAM"

echo "==> Archive"
# The hardened runtime is on here, not in the project: signed ad hoc (a local Release run from
# Xcode), library validation refuses Sparkle, which has no team either, and Side ends at launch.
# SwiftTerm 1.19+ runs a build plugin (SwiftTermBuildInfoPlugin); xcodebuild refuses an
# untrusted plugin unless told to skip validation. Xcode itself asks once.
xcodebuild -project SIDE.xcodeproj -scheme SIDE -configuration Release -destination 'generic/platform=macOS' -skipPackagePluginValidation \
  -archivePath "$ARCHIVE" -clonedSourcePackagesDirPath "$SPM" archive \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES \
  | grep -E ":[0-9]+:[0-9]+: error:|error: .*sign|ARCHIVE (SUCCEEDED|FAILED)" || true
[[ -d "$ARCHIVE" ]] || { echo "archive failed" >&2; exit 1; }

echo "==> Export (Developer ID)"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" | grep -E "^error:|: error:|EXPORT (SUCCEEDED|FAILED)" || true
[[ -d "$APP" ]] || { echo "export failed" >&2; exit 1; }

echo "==> Verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime" >/dev/null \
  || { echo "not signed with Developer ID and the hardened runtime" >&2; exit 1; }

echo "==> Check linked frameworks resolve inside the app"
# A framework the binary links through @rpath must be in Contents/Frameworks, or the app dies at
# launch; tests can't catch it (the test runner supplies its own framework path).
for lib in $(otool -L "$APP/Contents/MacOS/Side" | awk '/@rpath\//{print $1}'); do
  [[ -e "$APP/Contents/Frameworks/${lib#@rpath/}" ]] || { echo "missing from the app: $lib" >&2; exit 1; }
done
LOAD_COMMANDS=$(otool -l "$APP/Contents/MacOS/Side")  # captured: grep -q would break the pipe under pipefail
[[ "$LOAD_COMMANDS" == *"@executable_path/../Frameworks"* ]] || { echo "no @executable_path/../Frameworks rpath" >&2; exit 1; }

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

if (( ! DRY_RUN )); then
  echo "==> Notarize the app"
  ditto -c -k --keepParent "$APP" "$OUT/Side.zip"
  notarize "$OUT/Side.zip"
  xcrun stapler staple "$APP"
fi

echo "==> Disk image"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Side $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"

if (( ! DRY_RUN )); then
  echo "==> Notarize the disk image"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo "==> Appcast"
# Sparkle's own tool: signs the DMG's EdDSA signature into the feed with the "side" key.
UPDATES="$OUT/updates"; mkdir -p "$UPDATES"
cp "$DMG" "$UPDATES/"
"$SPM/artifacts/sparkle/Sparkle/bin/generate_appcast" --account side \
  --download-url-prefix "https://github.com/$RELEASES_REPO/releases/download/v$VERSION/" \
  -o "$OUT/appcast.xml" "$UPDATES"

echo "Done: $DMG"
echo "Publish (not run here; it's public):"
echo "  gh release create v$VERSION -R $RELEASES_REPO --title \"Side $VERSION\" \"$DMG\" \"$OUT/appcast.xml\""
