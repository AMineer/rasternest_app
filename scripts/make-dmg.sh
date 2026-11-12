#!/usr/bin/env bash
# Packages build/RasterNest.app into build/RasterNest-<version>.dmg (drag-to-Applications layout).
# Run scripts/build-app.sh first. Signs the DMG when SIGN_IDENTITY is a real identity.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="build/RasterNest.app"
DMG="build/RasterNest-$VERSION.dmg"
[[ -d "$APP" ]] || { echo "Missing $APP. Run scripts/build-app.sh first." >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "RasterNest $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [[ -n "${SIGN_IDENTITY:-}" && "${SIGN_IDENTITY}" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

shasum -a 256 "$DMG"
echo "✔ $DMG"
