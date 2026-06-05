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
  "engine": "apple",              // apple | whisperkit
  "language": "en",               // en, en-US, fr-FR, …
  "output": "paste",              // paste | type | clipboard
  "clipboardBehavior": "replace", // replace | append (output=clipboard)
  "punctuation": true,
  "bubblePosition": "bottom-center", // bottom-center | top-center
  "showBubble": true
}
```

## Install (recommended)

```bash
git clone https://github.com/OccupiedPorcupine/whisperkey.git
cd whisperkey
./install.sh
```

`install.sh` creates a stable self-signed signing identity, builds the release
app into `/Applications`, remaps Caps Lock → F18 (now and at every login), and
registers a LaunchAgent so WhisperKey **auto-starts at login and runs in the
background**.

On first launch grant four permissions (once):

1. **Microphone** and **Speech Recognition** — prompt automatically.
2. **Input Monitoring** and **Accessibility** — add `/Applications/WhisperKey.app`
   under **System Settings → Privacy & Security** (needed to read the trigger and
   to paste into other apps). Quit + relaunch (or log out/in) after granting.

Then: focus any text field, **tap Caps Lock**, speak, **tap Caps Lock** again —
the text is pasted at your cursor. Remove everything with `./uninstall.sh`.

## Running as a background service

WhisperKey runs as a **user LaunchAgent** — a true background process owned by
`launchd` (parent PID 1, no controlling terminal). It survives closing every
terminal, persists across logout, and relaunches at login. It is *not* tied to a
shell; the only time a terminal is involved is the one-time `./install.sh` build.

> It's a **LaunchAgent** (runs inside your logged-in GUI session) rather than a
> system-wide **LaunchDaemon** (runs at boot, pre-login, headless). A dictation
> tool *must* be an agent: it needs your GUI session to reach the mic, post
> keystrokes, and show the menu-bar icon — a pre-login daemon couldn't.

| Action | Command |
|---|---|
| Check if running | `pgrep -lf MacOS/WhisperKey` (or look for the 🎤 menu-bar icon) |
| Stop | `launchctl unload ~/Library/LaunchAgents/com.munyau.whisperkey.plist` |
| Start | `launchctl load ~/Library/LaunchAgents/com.munyau.whisperkey.plist` |
| Restart | `pkill -f MacOS/WhisperKey` (the agent relaunches it) |
| Logs | `tail -f ~/Library/Logs/WhisperKey.log` |
| Quit this session | menu-bar icon → Quit (stays quit; a crash auto-restarts) |

## Development

```bash
# fast local loop (unload the login agent first so it doesn't fight restart.sh):
launchctl unload ~/Library/LaunchAgents/com.munyau.whisperkey.plist
./restart.sh        # kill + rebuild + relaunch the local copy
# push changes into the installed /Applications copy:
./install.sh
```

## Notes

- Signing uses a **stable self-signed identity** (`scripts/make-cert.sh`), so the
  Accessibility/Input-Monitoring grants persist across rebuilds and survive
  moving the app to `/Applications` (the TCC rule is identity-based, not path- or
  hash-based). It is not notarized, so Gatekeeper may ask you to right-click →
  Open the first time if launched from Finder.
- Trigger, mode, engine, output, language, and bubble options are all set in
  `~/.config/whisperkey/config.json` (hot-reloaded — no restart).
