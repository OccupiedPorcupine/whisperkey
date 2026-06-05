#!/usr/bin/env bash
# WhisperKey installer:
#   1. ensure a stable code-signing identity
#   2. build the release app and install it to /Applications
#   3. remap Caps Lock -> F18 (now, and at every login via a LaunchAgent)
#   4. auto-start WhisperKey at login (LaunchAgent; restarts on crash, not on
#      a clean Quit)
#   5. print the one-time permission walkthrough
#
# Re-runnable: updates an existing install in place. Undo with ./uninstall.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$ROOT/WhisperKey.app"
APP_DST="/Applications/WhisperKey.app"
BIN="$APP_DST/Contents/MacOS/WhisperKey"
LA_DIR="$HOME/Library/LaunchAgents"
APP_LABEL="com.munyau.whisperkey"
REMAP_LABEL="com.munyau.whisperkey.remap"
REMAP_JSON='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}'

echo "==> 1/5  code-signing identity"
"$ROOT/scripts/make-cert.sh"

echo "==> 2/5  build release app"
"$ROOT/make-app.sh" release

echo "==> 3/5  install to /Applications"
pkill -f "MacOS/WhisperKey" 2>/dev/null || true
sleep 0.5
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

mkdir -p "$LA_DIR"

echo "==> 4/5  Caps Lock -> F18 (now + at login)"
/usr/bin/hidutil property --set "$REMAP_JSON" >/dev/null
cat > "$LA_DIR/$REMAP_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$REMAP_LABEL</string>
    <key>RunAtLoad</key><true/>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/hidutil</string>
        <string>property</string>
        <string>--set</string>
        <string>$REMAP_JSON</string>
    </array>
</dict>
</plist>
EOF

echo "==> 5/5  auto-start at login"
cat > "$LA_DIR/$APP_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$APP_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$BIN</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/WhisperKey.log</string>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/WhisperKey.log</string>
</dict>
</plist>
EOF

# (re)load both agents
for label in "$REMAP_LABEL" "$APP_LABEL"; do
    launchctl unload "$LA_DIR/$label.plist" 2>/dev/null || true
    launchctl load -w "$LA_DIR/$label.plist"
done

cat <<'NOTE'

==> Installed.

WhisperKey is now running and will start automatically at login.
Look for the microphone icon in the menu bar (top-right).

ONE-TIME PERMISSIONS — grant these in System Settings → Privacy & Security:
  • Microphone           (prompts automatically)
  • Speech Recognition   (prompts automatically)
  • Accessibility        → add /Applications/WhisperKey.app
  • Input Monitoring     → add /Applications/WhisperKey.app
After granting, the menu-bar Quit + relaunch (or log out/in) once.

Logs:  ~/Library/Logs/WhisperKey.log
Undo:  ./uninstall.sh
NOTE
