#!/usr/bin/env bash
# Notarizes and staples a DMG so Gatekeeper opens it without warnings.
# Requires the app to be signed with a "Developer ID Application" identity (paid Apple Developer Program).
#
# Either store credentials once:
#   xcrun notarytool store-credentials rasternest --apple-id you@example.com --team-id TEAMID
#   NOTARY_PROFILE=rasternest scripts/notarize.sh build/RasterNest-0.1.0.dmg
# or (CI) set APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD (an app-specific password).
set -euo pipefail

DMG="${1:?usage: notarize.sh path/to/file.dmg}"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
else
  xcrun notarytool submit "$DMG" \
    --apple-id "${APPLE_ID:?set APPLE_ID or NOTARY_PROFILE}" \
    --team-id "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}" \
    --password "${APPLE_APP_PASSWORD:?set APPLE_APP_PASSWORD}" \
    --wait
fi

xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG" || true
echo "✔ Notarized $DMG"
