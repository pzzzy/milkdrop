#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/MilkDrop.app"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
# Avoid racing an open bundle while replacing its 1,700+ preset resources.
pkill -x MilkDropMac 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x MilkDropMac >/dev/null || break; sleep 0.2; done
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MilkDropMac" "$APP/Contents/MacOS/MilkDropMac"
test -x "$APP/Contents/MacOS/MilkDropMac"
cmp -s "$BIN_DIR/MilkDropMac" "$APP/Contents/MacOS/MilkDropMac"
if [[ -d favorite_presets_2021_01_03 ]]; then
  cp -R favorite_presets_2021_01_03 "$APP/Contents/Resources/Presets"
else
  echo "No preset collection included; the app will use its built-in fallback visualization."
fi
cp THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
/usr/libexec/PlistBuddy -c 'Clear dict' "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.lukeschneider.milkdropmac' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string MilkDrop' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string MilkDrop' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string MilkDropMac' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.1.0' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 15.0' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSApplicationCategoryType string public.app-category.entertainment' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSSupportsAutomaticGraphicsSwitching bool true' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSAudioCaptureUsageDescription string MilkDrop analyzes system output audio to drive music-reactive visualizations.' "$APP/Contents/Info.plist"
if [[ -n "${MILKDROP_SIGNING_IDENTITY:-}" ]] && security find-identity -v -p codesigning | grep -Fq "$MILKDROP_SIGNING_IDENTITY"; then
  codesign --force --deep --options runtime --sign "$MILKDROP_SIGNING_IDENTITY" "$APP"
else
  echo "Signing ad hoc; set MILKDROP_SIGNING_IDENTITY to use an installed signing identity." >&2
  codesign --force --deep --sign - "$APP"
fi
plutil -lint "$APP/Contents/Info.plist"
echo "$APP"
