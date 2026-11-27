#!/bin/bash
# Builds build/Nib.app. Set SIGN_IDENTITY to a codesigning identity to keep
# the Accessibility grant across rebuilds (ad-hoc signatures change every build).
set -euo pipefail
cd "$(dirname "$0")"
VERSION=${VERSION:-2.0.20}
BUILD_NUMBER=${BUILD_NUMBER:-23}

swift build -c release
BIN="$(swift build -c release --show-bin-path)/GrammarAI"

APP=build/Nib.app
rm -rf "$APP" build/GrammarAI.app   # the app was called Grammar AI before

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nib"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Nib</string>
  <key>CFBundleDisplayName</key><string>Nib</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.ruiwang.grammar-ai</string>
  <key>CFBundleExecutable</key><string>Nib</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Nib sends copy and paste keystrokes to the app you are writing in.</string>
</dict>
</plist>
PLIST

if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Apple Development/ {print $2; exit}')"
fi
# HARDENED=1 (release.sh): hardened runtime + secure timestamp, as notarisation requires. No entitlements needed:
# no sandbox, and posting keystrokes is covered by the Accessibility permission, not an entitlement.
EXTRA=""
[ "${HARDENED:-0}" = 1 ] && EXTRA="--options runtime --timestamp"
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier com.ruiwang.grammar-ai $EXTRA "$APP"
echo "Built $APP"
