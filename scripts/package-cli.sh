#!/usr/bin/env bash
# Builds a standalone `rnest` tarball for the current OS/arch, used by the Homebrew formula.
#   macOS → build/rnest-<version>-macos-universal.tar.gz
#   Linux → build/rnest-<version>-linux-<arch>.tar.gz   (Swift stdlib statically linked)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d '[:space:]' < VERSION)"
mkdir -p build

case "$(uname -s)" in
  Darwin)
    swift build -c release --product rnest --arch arm64 --arch x86_64
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/rnest"
    if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
      codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$BIN"
    fi
    NAME="rnest-$VERSION-macos-universal"
    ;;
  Linux)
    swift build -c release --product rnest --static-swift-stdlib
    BIN="$(swift build -c release --show-bin-path)/rnest"
    NAME="rnest-$VERSION-linux-$(uname -m)"
    ;;
  *) echo "Unsupported OS" >&2; exit 1 ;;
esac

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$NAME"
cp "$BIN" "$STAGE/$NAME/rnest"
cp LICENSE README.md "$STAGE/$NAME/"
tar -C "$STAGE" -czf "build/$NAME.tar.gz" "$NAME"
shasum -a 256 "build/$NAME.tar.gz" 2>/dev/null || sha256sum "build/$NAME.tar.gz"
echo "✔ build/$NAME.tar.gz"
