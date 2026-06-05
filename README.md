# WhisperKey

**Global push-to-talk / toggle dictation for macOS.** Tap a key anywhere, speak,
and your words are pasted at the cursor — in any app. Menu-bar only, no Dock
icon, runs in the background, starts at login.

Press **Caps Lock**, talk, press again — the transcription drops in where your
cursor is (or onto the clipboard if nothing's focused). On-device by default,
with an optional local Whisper engine for higher accuracy.

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![language](https://img.shields.io/badge/Swift-5-orange)
![license](https://img.shields.io/badge/license-MIT-green)

## Features

- 🎙️ **Global trigger** — Caps Lock (remapped to F18) works in every app; `toggle` or `push_to_talk`.
- ⌨️ **Pastes anywhere** — synthesized ⌘V, so it works where fake-typing fails (Claude Code, Electron apps, terminals). Falls back to clipboard when no field is focused, and restores your previous clipboard.
- 🧠 **Two engines** — Apple on-device Speech (instant, zero setup) or local **WhisperKit** CoreML Whisper (higher accuracy). Swap via config.
- ♾️ **Long-form safe** — an accumulating-pool transcriber banks every pause, so nothing is lost during long dictation.
- 🫧 **Live overlay** — a non-activating bubble shows the transcript + mic level without ever stealing focus.
- ⚙️ **Hot-reload config** — JSON at `~/.config/whisperkey/config.json`; no restart.
- 🚀 **Background service** — auto-starts at login as a LaunchAgent; just a menu-bar mic icon.
- 🔒 **Private** — everything runs on-device; nothing is sent to the cloud.

## How it works

`KeyMonitor` (a `CGEventTap` on F18) drives a `Recorder` (`AVAudioEngine` → 16 kHz
mono), which feeds a `Transcriber` (Apple `Speech` or WhisperKit). The result goes
to an `OutputRouter` that pastes it at the focused element (via the Accessibility
API) or to the clipboard. A non-activating `NSPanel` shows the live transcript.
See [PLAN.md](PLAN.md) for the full design.

## Requirements

- **macOS 14+** (Apple Silicon recommended)
- **Xcode Command Line Tools** to build (`xcode-select --install`) — no full Xcode needed

## Engines

The default `apple` engine is on-device, instant, and needs no download. To use
local Whisper, set `"engine": "whisperkit"` in the config (hot-reloads). On the
next dictation the CoreML model downloads from Hugging Face once and is cached;
it's a batch engine, so the bubble shows "Transcribing…" after you stop rather
than live partials. Choose the model with `"whisperModel"` (e.g. `large-v3-turbo`,
`base`, `small`).

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

## License

MIT — see [LICENSE](LICENSE).
