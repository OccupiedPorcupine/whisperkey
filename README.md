# WhisperKey

Global push-to-talk / toggle dictation for macOS. Tap a trigger key anywhere,
speak, and the text is typed at your cursor (or dropped on the clipboard if no
text field is focused). Menu-bar only, no Dock icon.

See [PLAN.md](PLAN.md) for the full design.

## Status

All milestones (1–9) implemented:

- **Menu bar app** — `mic` icon, turns red while listening, Quit item.
- **KeyMonitor** — `CGEventTap` on F18 (Caps Lock after remap), toggle + hold.
- **Recorder** — `AVAudioEngine` → 16 kHz mono Float32, with RMS levels.
- **AppleTranscriber** — on-device Speech, punctuation, pause-based segment
  rotation to dodge the ~1-minute request limit.
- **OutputRouter** — `paste` (⌘V, universal — works in Claude Code/Electron/
  terminals), `type` (per-char), or `clipboard`. Restores prior clipboard.
- **BubbleWindow** — non-activating overlay with live transcript + level dot.
- **ConfigStore** — hot-reloaded JSON at `~/.config/whisperkey/config.json`.
- **WhisperKitTranscriber** — optional CoreML Whisper backend (batch, VAD-chunked).
- **Installer** — `install.sh` / `uninstall.sh` with auto-start + remap LaunchAgents.

### Using the WhisperKit engine
Set `"engine": "whisperkit"` in the config (hot-reloads). On the next dictation
the model downloads from Hugging Face on first use (cached afterward). It's a
batch engine, so the bubble shows "Transcribing…" after you stop rather than live
partials. Pick the model with `"whisperModel"` (e.g. `large-v3-turbo`, `base`,
`small`). The Apple engine remains the default (instant, zero download).

## Config

Created on first launch at `~/.config/whisperkey/config.json`; edits hot-reload
(no restart). Unknown/missing keys fall back to defaults.

```json
{
  "trigger": "capslock",          // capslock | f17 | f18 | f19 | <keycode#>
  "mode": "toggle",               // toggle | push_to_talk
  "engine": "apple",              // apple | whisperkit (M8)
  "language": "en",               // en, en-US, fr-FR, …
  "output": "paste",              // paste | type | clipboard
  "clipboardBehavior": "replace", // replace | append (output=clipboard)
  "punctuation": true,
  "bubblePosition": "bottom-center", // bottom-center | top-center
  "showBubble": true
}
```

## Build & run

```bash
./make-app.sh            # builds .build + assembles WhisperKey.app (ad-hoc signed)
./scripts/remap-capslock.sh   # one-time: Caps Lock -> F18 trigger
open WhisperKey.app
```

A `mic` icon appears in the menu bar. On first launch, grant the prompts:

1. **Microphone** and **Speech Recognition** — pop up automatically.
2. **Input Monitoring** and **Accessibility** — add `WhisperKey.app` manually
   in **System Settings → Privacy & Security** (needed for the key trigger and
   for typing into other apps). Relaunch after granting.

Then: focus any text field, **tap Caps Lock**, speak, **tap Caps Lock** again.
The text is typed where your cursor is.

> Tip: run from a terminal (`./WhisperKey.app/Contents/MacOS/WhisperKey`) to see
> live partial transcripts and permission status in the logs.

## Notes

- Ad-hoc signing means permissions may reset across rebuilds. A stable signing
  certificate (Xcode "Sign to Run Locally") fixes that once available.
- Default trigger is F18; change `triggerKeyCode` in `KeyMonitor.swift` until the
  config file (M7) lands.
