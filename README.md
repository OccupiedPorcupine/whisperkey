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
- 🧠 **Three STT engines, all on-device** — Apple Speech (instant, zero setup), **WhisperKit** CoreML Whisper, or **NVIDIA Parakeet** on the Neural Engine (FluidAudio). Swap from the menu, the config, or by clicking the badge on the bubble.
- ✨ **On-device AI polish** — an optional local LLM pass (Apple Foundation Models) fixes punctuation, casing, and filler words. Nothing leaves the Mac.
- 🔊 **Text-to-speech** — press **Caps Lock + S** and WhisperKey reads the selected text aloud (perfect for listening to AI replies). Apple system voices or a **local neural voice** (PocketTTS, CoreML). Press again — or Esc — to stop.
- ♾️ **Unlimited length** — an accumulating-pool transcriber banks every pause and rotates recognizers forever, so dictations of any number of words survive intact (batch engines chunk long audio; the LLM polish automatically steps aside past its context limit rather than truncating).
- 📝 **Live transcription streaming** — from the menu bar, stream speech in real time into a **new Obsidian note** (auto-created in your vault, opens in Obsidian as it fills in) or **typed into whatever textbox has focus**. Stop with the menu, a trigger tap, or Esc.
- 🗂️ **Obsidian dictation archive** — optionally save *every* finished dictation as its own vault note, with an **AI-generated title**, YAML frontmatter (time, source app, `#dictation` tag), and a wikilink to the day's daily note. Toggle from the menu; filename template is configurable.
- 🫧 **Notch overlay** — while dictating, the MacBook notch appears to **expand sideways** into a black slab showing a live waveform and the session timer; it contracts back when you stop. Floating frosted-pill positions are still available, all color-coded by state and **Esc-cancellable**. Never steals focus.
- 🕘 **Dictation history** — recent transcripts in the menu bar; click to re-copy, ⌥-click to hear them read aloud. Stored locally.
- ⚠️ **Config linting** — bad values (unknown engine, missing vault, broken filename template) surface as a menu-bar warning item instead of failing silently.
- 📚 **Custom dictionary** — teach it names, jargon, and product terms; they bias both the recognizer and the AI polish pass.
- ⚙️ **Hot-reload config** — JSON at `~/.config/whisperkey/config.json`; no restart.
- 🚀 **Background service** — auto-starts at login as a LaunchAgent; just a menu-bar mic icon.
- 🔒 **Private** — everything runs on-device; nothing is sent to the cloud.

## Why not Wispr Flow?

| | WhisperKey | Wispr Flow |
|---|---|---|
| Speech-to-text | 3 engines, **100% on-device** | Cloud |
| AI cleanup | On-device LLM (Apple Intelligence) | Cloud |
| Text-to-speech | ✅ system + local neural voice | ❌ |
| Custom dictionary | ✅ (`dictionary` in config) | ✅ |
| History | ✅ local only | ✅ (their servers, unless Privacy Mode) |
| Live waveform overlay | ✅ non-activating, esc-cancellable | ✅ |
| Price | Free, MIT | Subscription |

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

The default `apple` engine is on-device, instant, and needs no download. Two
local AI models are available as accuracy upgrades — pick them from the
menu-bar **Dictation Engine** menu, by clicking the engine badge on the bubble,
or via `"engine"` in the config (hot-reloads):

- `whisperkit` — OpenAI Whisper as CoreML. Model set by `"whisperModel"`; the
  name must match a folder suffix in the `argmaxinc/whisperkit-coreml` repo
  (e.g. `large-v3-v20240930_626MB` — the quantized large-v3-turbo — or
  `base`, `small`); downloads once from Hugging Face.
- `parakeet` — NVIDIA Parakeet TDT 0.6B on the Apple Neural Engine via
  FluidAudio; very fast and accurate for long-form English (v2) with a
  multilingual variant (v3) picked automatically from `"language"`.

Both are batch engines: the bubble shows "Transcribing…" after you stop rather
than live partials.

## Text-to-speech (listen to AI replies)

Select any text — an AI answer, an article, a diff summary — and press
**Caps Lock + S**. WhisperKey grabs the selection (Accessibility API, with a
polite clipboard fallback for Electron apps) and reads it aloud. Press the
chord again, or **Esc**, to stop.

Two voices, mirroring the STT side:

- `"ttsEngine": "apple"` — system voices, instant, every language.
  Pick a specific voice with `"ttsVoice"` (an `AVSpeechSynthesisVoice`
  identifier) and speed with `"ttsRate"` (0…1).
- `"ttsEngine": "neural"` — a local neural voice (PocketTTS via FluidAudio,
  CoreML, fully on-device). Downloads once, then works offline. Falls back to
  the Apple voice if synthesis fails.

## Live transcription (Obsidian / any textbox)

Two menu-bar items stream speech continuously instead of pasting once at the end:

- **Live Transcribe → Obsidian Note** creates `Live Transcript <date>.md` in your
  vault (folder set by `"obsidianFolder"`), opens it in Obsidian, and appends
  each sentence as you pause. The vault is auto-detected from Obsidian's own
  registry; override with `"obsidianVaultPath"` if you use several vaults.
- **Live Transcribe → Focused Textbox** types each finalized sentence directly
  into whatever field your cursor is in — meeting notes into any app.

The overlay turns **green** in live mode; committed sentences flow to the target
at every natural pause. Stop from the menu, with a trigger tap, or Esc. Live
mode always uses the streaming Apple engine and runs indefinitely.

## Obsidian dictation archive

Separate from live streaming: flip **Log Dictations → Obsidian** in the menu and
every finished dictation is *also* saved as its own note in your vault (the text
still pastes at your cursor as usual). Each note gets:

- a filename from `"obsidianNoteNameFormat"` — `DateFormatter` patterns plus a
  `{title}` placeholder filled by the on-device LLM (falls back to the opening
  words), e.g. `yyMMddHHmm - {title}` → `2607171432 - Email The Landlord.md`
- YAML frontmatter: creation time, `source: WhisperKey`, the app you dictated
  into, and a `dictation` tag
- a `[[YYYY-MM-DD]]` wikilink so the archive shows up in daily-note backlinks
  and the graph

Notes land in `"obsidianLogFolder"`. Archiving runs after delivery, so it never
delays the paste; failures log rather than interrupt.

## The notch overlay

With `"bubblePosition": "notch"` (the default) the dictation UI lives in the
MacBook notch: on trigger, a black slab **expands horizontally out of the
notch** — staying exactly notch-height, never dropping below the menu bar — with
a live waveform on the left and the session timer on the right. Stopping
contracts it back in. The notch is measured from the screen itself
(`safeAreaInsets` + auxiliary top areas), and on notchless/external displays it
degrades to a compact top-center slab. Prefer the classic look? Set
`"bubblePosition"` to `bottom-center` or `top-center` for the frosted pill with
live transcript + engine badge.

## Config

Created on first launch at `~/.config/whisperkey/config.json`; edits hot-reload
(no restart). Unknown/missing keys fall back to defaults.

```json
{
  "trigger": "capslock",          // capslock | f17 | f18 | f19 | <keycode#>
  "mode": "toggle",               // toggle | push_to_talk
  "engine": "apple",              // apple | whisperkit | parakeet
  "whisperModel": "large-v3-v20240930_626MB",
  "language": "en",               // en, en-US, fr-FR, …
  "output": "paste",              // paste | type | clipboard
  "clipboardBehavior": "replace", // replace | append (output=clipboard)
  "punctuation": true,
  "polish": true,                 // on-device LLM cleanup (macOS 26+; no-op otherwise)
  "bubblePosition": "notch",      // notch | top-center | bottom-center
  "showBubble": true,
  "chordKey": "m",                // Caps Lock + M → meeting hand-off; "" disables
  "speakChordKey": "s",           // Caps Lock + S → speak selection; "" disables
  "ttsEngine": "apple",           // apple | neural (local PocketTTS model)
  "ttsVoice": "",                 // Apple voice identifier ("" = system default)
  "ttsRate": 0.5,                 // Apple voice speed, 0…1
  "dictionary": [],               // custom vocabulary, e.g. ["WhisperKey", "Parakeet"]
  "historyLimit": 25,             // recent transcripts in the menu; 0 disables
  "obsidianVaultPath": "",        // "" = auto-detect the most recent open vault
  "obsidianFolder": "WhisperKey Live", // vault subfolder for live notes; "" = root
  "obsidianLogging": false,       // archive every dictation as its own vault note
  "obsidianLogFolder": "WhisperKey Dictations", // vault subfolder for the archive
  "obsidianNoteNameFormat": "yyMMddHHmm - {title}" // note filename template
}
```

Invalid values don't break anything — they fall back to defaults and show up
under a **⚠️ Config issue** item in the menu bar.

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

Unit tests cover the pure logic (config decoding, keycodes, note templating,
validation). The default Command Line Tools toolchain lacks XCTest, so point
`swift test` at a full Xcode:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
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
