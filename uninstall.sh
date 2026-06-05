#!/usr/bin/env bash
# Reverse install.sh: stop & unload the LaunchAgents, remove the app, and undo
# the Caps Lock remap. Leaves your config (~/.config/whisperkey) and the
# code-signing certificate in place.
set -euo pipefail

LA_DIR="$HOME/Library/LaunchAgents"
APP_LABEL="com.munyau.whisperkey"
REMAP_LABEL="com.munyau.whisperkey.remap"

echo "==> unloading LaunchAgents"
for label in "$APP_LABEL" "$REMAP_LABEL"; do
    launchctl unload "$LA_DIR/$label.plist" 2>/dev/null || true
    rm -f "$LA_DIR/$label.plist"
done

echo "==> stopping app"
pkill -f "MacOS/WhisperKey" 2>/dev/null || true

echo "==> removing /Applications/WhisperKey.app"
rm -rf "/Applications/WhisperKey.app"

echo "==> restoring Caps Lock"
/usr/bin/hidutil property --set '{"UserKeyMapping":[]}' >/dev/null

cat <<'NOTE'

==> Uninstalled.

Left in place (remove manually if you want):
  • config:       ~/.config/whisperkey/
  • signing cert: "WhisperKey Self-Signed" in Keychain Access
  • permissions:  the WhisperKey entries under Privacy & Security

NOTE
