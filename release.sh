#!/bin/sh
# Builds Nib for distribution: Release build → Developer ID signature (hardened runtime, secure timestamp)
# → notarised + stapled app → signed DMG (Nib.app + Applications link) → notarised + stapled DMG → verified.
# Output: dist/Nib-<version>.dmg (dist/ is git-ignored; older builds there are removed).
#
# Sign with YOUR OWN identity. Set these in the environment, or in release.local.env (git-ignored):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"   # from `security find-identity -v -p codesigning`
#   NOTARY_PROFILE=my-notary-profile    # created once with `xcrun notarytool store-credentials my-notary-profile`
# Optional:
#   ./release.sh --publish   also creates the GitHub release vX.Y.Z, uploads the DMG and updates the Sparkle appcast
#                            (needs GH_TOKEN or GITHUB_TOKEN with repo access, and GITHUB_REPO=owner/name).
# If the screen is locked, notarytool reports "No Keychain password item found for profile": unlock and re-run.
# Contacts Apple (and GitHub with --publish); never installs anything.
set -eu
cd "$(dirname "$0")"
[ -f release.local.env ] && . ./release.local.env
PUBLISH=0; [ "${1:-}" = "--publish" ] && PUBLISH=1
fail() { echo "release: $*" >&2; exit 1; }
[ -n "${DEVELOPER_ID:-}" ] || fail "set DEVELOPER_ID (see the top of release.sh)"
[ -n "${NOTARY_PROFILE:-}" ] || fail "set NOTARY_PROFILE (see the top of release.sh)"
PROFILE=$NOTARY_PROFILE
IDENTITY=$DEVELOPER_ID
XC=${XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}   # notarytool / stapler live in Xcode
VERSION=$(sed -n 's/^VERSION=\${VERSION:-\(.*\)}$/\1/p' build.sh)
APP=build/Nib.app
DMG="dist/Nib-$VERSION.dmg"
STAGE=build/dmg-stage

xc() { DEVELOPER_DIR="$XC" xcrun "$@"; }

notarise() { # notarise FILE: submit, wait; on anything but Accepted print Apple's log and stop
  out=$(xc notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1) || true
  echo "$out" | grep -E "^  (id|status):|Processing complete" || true
  id=$(echo "$out" | awk '/^  id:/ {print $2; exit}')
  if ! echo "$out" | grep -q "status: Accepted"; then
    [ -n "$id" ] && xc notarytool log "$id" --keychain-profile "$PROFILE" || true
    fail "notarisation of $1 failed"
  fi
  echo "notarised $1 (submission $id)"
}

echo "== build Nib $VERSION (Developer ID, hardened runtime)"
SIGN_IDENTITY="$IDENTITY" HARDENED=1 ./build.sh

echo "== verify the signature"
info=$(codesign -dvv "$APP" 2>&1)
echo "$info" | grep -q "Authority=$IDENTITY" || fail "not signed with $IDENTITY"
echo "$info" | grep -q "^Timestamp=" || fail "no secure timestamp"
echo "$info" | grep -q "flags=.*runtime" || fail "hardened runtime missing"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then fail "get-task-allow present"; fi
codesign --verify --deep --strict --verbose=1 "$APP"

echo "== notarise the app"
rm -f build/app.zip
ditto -c -k --keepParent "$APP" build/app.zip
notarise build/app.zip
rm -f build/app.zip
xc stapler staple "$APP"
xc stapler validate "$APP"

echo "== DMG"
rm -rf "$STAGE"; mkdir -p "$STAGE" dist
ditto "$APP" "$STAGE/Nib.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Nib $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarise "$DMG"
xc stapler staple "$DMG"
xc stapler validate "$DMG"

echo "== Gatekeeper"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | tee build/spctl-dmg.txt
spctl -a -t execute -vv "$APP" 2>&1 | tee build/spctl-app.txt
grep -q "Notarized Developer ID" build/spctl-dmg.txt || fail "DMG is not accepted as Notarized Developer ID"
grep -q "Notarized Developer ID" build/spctl-app.txt || fail "app is not accepted as Notarized Developer ID"
hdiutil verify "$DMG" >/dev/null && echo "DMG checksum verified"
shasum -a 256 "$DMG"

for f in dist/*; do [ "$f" = "$DMG" ] && continue; echo "  removing older $f"; rm -rf -- "$f"; done
echo "Done: $DMG"
[ "$PUBLISH" = 1 ] && ./publish.sh "$VERSION"
exit 0
