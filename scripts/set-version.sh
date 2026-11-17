#!/usr/bin/env bash
# Sets the version everywhere: scripts/set-version.sh 0.2.0
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
V="${1:?usage: set-version.sh X.Y.Z}"
echo "$V" > VERSION
sed -i.bak -E "s/(public static let version = \")[^\"]+(\")/\1$V\2/" Sources/RasterNestCore/Naming.swift
rm -f Sources/RasterNestCore/Naming.swift.bak
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" Resources/Info.plist 2>/dev/null \
  || sed -i -E "/CFBundleShortVersionString/{n;s/<string>[^<]*</<string>$V</}" Resources/Info.plist
# Windows: MSIX versions have four parts. (-i.bak works with both BSD and GNU sed.)
sed -i.bak -E "/<Identity/,/\/>/ s/(Version=\")[0-9.]+(\")/\1$V.0\2/" windows/src/RasterNest.App/Package.appxmanifest
rm -f windows/src/RasterNest.App/Package.appxmanifest.bak
echo "Version set to $V"
