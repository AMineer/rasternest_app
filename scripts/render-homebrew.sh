#!/usr/bin/env bash
# Renders the Homebrew cask + formula from release artifacts in a directory.
#   scripts/render-homebrew.sh <owner/repo> <artifacts-dir> <out-dir>
# Writes <out-dir>/Casks/rasternest.rb and <out-dir>/Formula/rnest.rb
set -euo pipefail

REPO="${1:?owner/repo}"
ART="${2:?artifacts dir}"
OUT="${3:?output dir}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

sha() {
  local f="$ART/$1"
  [[ -f "$f" ]] || { echo "missing:$1"; return; }
  (shasum -a 256 "$f" 2>/dev/null || sha256sum "$f") | awk '{print $1}'
}

render() {
  sed -e "s|{{VERSION}}|$VERSION|g" \
      -e "s|{{REPO}}|$REPO|g" \
      -e "s|{{SHA_DMG}}|$(sha "RasterNest-$VERSION.dmg")|g" \
      -e "s|{{SHA_MACOS}}|$(sha "rnest-$VERSION-macos-universal.tar.gz")|g" \
      -e "s|{{SHA_LINUX_X86_64}}|$(sha "rnest-$VERSION-linux-x86_64.tar.gz")|g" \
      -e "s|{{SHA_LINUX_AARCH64}}|$(sha "rnest-$VERSION-linux-aarch64.tar.gz")|g" \
      "$1"
}

mkdir -p "$OUT/Casks" "$OUT/Formula"
render "$ROOT/packaging/homebrew/rasternest.rb.tmpl" > "$OUT/Casks/rasternest.rb"
render "$ROOT/packaging/homebrew/rnest.rb.tmpl" > "$OUT/Formula/rnest.rb"
echo "✔ Rendered Homebrew files into $OUT"
