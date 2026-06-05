#!/usr/bin/env bash
# Remap Caps Lock -> F18 so WhisperKey can use it as a clean trigger key
# (and so it stops toggling capitalization). This lasts until reboot; the
# LaunchAgent installed by install.sh re-applies it at login.
#
# Undo with:  hidutil property --set '{"UserKeyMapping":[]}'
set -euo pipefail

hidutil property --set '{"UserKeyMapping":[
  {"HIDKeyboardModifierMappingSrc":0x700000039,
   "HIDKeyboardModifierMappingDst":0x70000006D}]}' >/dev/null

echo "Caps Lock is now remapped to F18. Tap Caps Lock to trigger WhisperKey."
