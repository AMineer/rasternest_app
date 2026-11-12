#!/usr/bin/env bash
# Builds build/RasterNest.app (menu-bar app + bundled `rnest` CLI) and signs it.
#
# Env:
#   CONFIG=release|debug      (default release)
#   UNIVERSAL=1               build arm64 + x86_64
#   SIGN_IDENTITY="..."       codesign identity; default: first "Developer ID Application",
#                             then "Apple Development", else ad-hoc ("-").
#   BUILD_NUMBER=N            CFBundleVersion (default: git commit count)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="RasterNest"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
CONFIG="${CONFIG:-release}"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

pick_identity() {
  local ids
  ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  for kind in "Developer ID Application" "Apple Development"; do
    local hash
    hash="$(echo "$ids" | grep "\"$kind" | head -1 | awk '{print $2}')"
    if [[ -n "$hash" ]]; then echo "$hash"; return; fi
  done
  echo "-"
}
SIGN_IDENTITY="${SIGN_IDENTITY:-$(pick_identity)}"

echo "▸ Building $APP_NAME $VERSION ($BUILD_NUMBER) [$CONFIG${UNIVERSAL:+, universal=$UNIVERSAL}]"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product RasterNestApp
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product rnest
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/RasterNestApp" "$APP/Contents/MacOS/$APP_NAME"
# Sparkle (auto-updates) lives in Contents/Frameworks.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
cp "$BIN_DIR/rnest" "$APP/Contents/Helpers/rnest"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $VERSION" \
  -c "Set :CFBundleVersion $BUILD_NUMBER" \
  "$APP/Contents/Info.plist"

echo "▸ Signing with: $SIGN_IDENTITY"
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_FLAGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Helpers/rnest"
# Sign Sparkle's nested code innermost-first (required for notarization).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for xpc in "$SPARKLE"/XPCServices/*.xpc; do
  [[ -e "$xpc" ]] && codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$xpc"
done
codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Autoupdate"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Updater.app"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_FLAGS[@]}" --entitlements Resources/RasterNest.entitlements "$APP"
codesign --verify --strict --deep "$APP"

echo "✔ $APP"
