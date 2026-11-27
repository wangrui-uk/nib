#!/bin/bash
# Builds build/Nib.app. Set SIGN_IDENTITY to a codesigning identity to keep
# the Accessibility grant across rebuilds (ad-hoc signatures change every build).
set -euo pipefail
cd "$(dirname "$0")"
VERSION=${VERSION:-2.2.1}
BUILD_NUMBER=${BUILD_NUMBER:-26}

swift build -c release
BIN="$(swift build -c release --show-bin-path)/GrammarAI"

APP=build/Nib.app
rm -rf "$APP" build/GrammarAI.app   # the app was called Grammar AI before

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Nib"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sparkle (automatic updates). Nib isn't sandboxed, so Sparkle's XPC services aren't needed.
SPARKLE_FW="$(find .build/artifacts -path '*Sparkle.xcframework/macos-*/Sparkle.framework' -maxdepth 6 | head -1)"
[ -n "$SPARKLE_FW" ] || { echo "Sparkle.framework not found (run: swift package resolve)" >&2; exit 1; }
ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Nib" 2>/dev/null || true

# Update feed and EdDSA public key. Forks that publish their own builds must use their own feed and key
# (Sparkle's generate_keys prints the public key; the private key stays in your Keychain).
FEED_URL=${NIB_FEED_URL:-https://wangrui-uk.github.io/nib/appcast.xml}
ED_KEY=${NIB_ED_PUBLIC_KEY:-zj8TF1Ol2VAMRNr6aNzph603aULKWY56Hj55by0fIQw=}

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
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$ED_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
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
# Inside out: Sparkle's helpers, the framework, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
for item in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do
  [ -e "$item" ] && codesign --force --sign "${SIGN_IDENTITY:--}" $EXTRA "$item"
done
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier com.ruiwang.grammar-ai $EXTRA "$APP"
echo "Built $APP"
