#!/usr/bin/env bash
# Build the SwiftPM binary and assemble it into a proper WhisperKey.app bundle
# (Info.plist + ad-hoc code signature) so macOS grants mic/speech permissions
# and treats it as a menu-bar-only app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-debug}"   # debug | release
APP="$ROOT/WhisperKey.app"

echo "==> swift build (-c $CONFIG)"
swift build -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/WhisperKey"
[ -x "$BIN" ] || { echo "build product not found at $BIN"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WhisperKey"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

CERT_NAME="WhisperKey Self-Signed"
# Resolve the identity's SHA-1 hash and sign by hash — unambiguous even if more
# than one cert shares the name, and stable across rebuilds.
CERT_HASH="$(security find-identity -p codesigning 2>/dev/null | grep "$CERT_NAME" | head -1 | awk '{print $2}')"
if [ -n "$CERT_HASH" ]; then
    echo "==> signing with stable identity ($CERT_NAME, $CERT_HASH)"
    codesign --force --sign "$CERT_HASH" "$APP"
else
    echo "==> ad-hoc signing (run ./scripts/make-cert.sh once for permissions that persist across rebuilds)"
    codesign --force --sign - "$APP"
fi

echo "==> done: $APP"
echo "Run it with:  open \"$APP\"   (or)   \"$APP/Contents/MacOS/WhisperKey\""
