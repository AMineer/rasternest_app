#!/usr/bin/env bash
# Copies the Windows sources to the Windows dev machine (ssh host alias "rnwin", or $RN_WIN_HOST)
# and optionally runs a command there from the windows/ folder:
#   scripts/win-sync.sh                       # sync only
#   scripts/win-sync.sh dotnet test           # sync, then run tests
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${RN_WIN_HOST:-rnwin}"
DEST="${RN_WIN_DIR:-C:/dev/rasternest}"
cd "$ROOT"
TMP="$(mktemp -t rn-win-sync).tar"
COPYFILE_DISABLE=1 tar --exclude 'bin' --exclude 'obj' --exclude '.vs' --exclude 'AppPackages' -cf "$TMP" VERSION windows Tests/Fixtures
scp -q "$TMP" "$HOST:$DEST.tar"
rm -f "$TMP"
ssh "$HOST" "New-Item -ItemType Directory -Force '$DEST' | Out-Null; tar -xf '$DEST.tar' -C '$DEST'; Remove-Item '$DEST.tar'"
if [ $# -gt 0 ]; then
  ssh "$HOST" "Set-Location '$DEST/windows'; $*"
fi
