#!/usr/bin/env bash
# Writes build/appcast.xml (the Sparkle update feed) for a notarized, stapled DMG.
#   scripts/make-appcast.sh build/RasterNest-0.4.0.dmg [owner/repo]
#
# Signing key: SPARKLE_ED_PRIVATE_KEY (CI secret) if set, otherwise the login-keychain
# key for account "rasternest" (created with Sparkle's generate_keys).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DMG="${1:?usage: make-appcast.sh path/to/RasterNest-x.y.z.dmg [owner/repo]}"
REPO="${2:-${GITHUB_REPOSITORY:-AMineer/rasternest_app}}"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/RasterNest.app/Contents/Info.plist)"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' build/RasterNest.app/Contents/Info.plist)"

SIGN_UPDATE="$(find .build/artifacts -path '*Sparkle/bin/sign_update' -type f | head -1)"
[[ -x "$SIGN_UPDATE" ]] || { echo "sign_update not found; run 'swift package resolve' first." >&2; exit 1; }

if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  KEYFILE="$(mktemp)"
  trap 'rm -f "$KEYFILE"' EXIT
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$KEYFILE"
  ATTRS="$("$SIGN_UPDATE" --ed-key-file "$KEYFILE" "$DMG")"
else
  ATTRS="$("$SIGN_UPDATE" --account rasternest "$DMG")"
fi

URL="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$DMG")"
NOTES="https://github.com/$REPO/releases/tag/v$VERSION"
mkdir -p build
cat > build/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>RasterNest</title>
    <link>https://rasternest.app</link>
    <description>RasterNest updates</description>
    <language>en</language>
    <item>
      <title>RasterNest $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$NOTES</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<h2>RasterNest $VERSION</h2><p>See <a href="$NOTES">what's new in this release</a>.</p>]]></description>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <enclosure url="$URL" $ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
echo "✔ build/appcast.xml ($VERSION, build $BUILD)"
