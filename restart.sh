#!/usr/bin/env bash
# Rebuild and relaunch WhisperKey: kill the running copy, recompile + re-sign
# the bundle, then start it fresh. Run after editing any source file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

pkill -f "MacOS/WhisperKey" 2>/dev/null || true
sleep 0.5
"$ROOT/make-app.sh" "${1:-debug}"
open "$ROOT/WhisperKey.app"
echo "Relaunched. Look for the mic icon in the menu bar."
