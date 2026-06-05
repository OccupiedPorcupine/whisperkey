# WhisperKey — global push-to-talk / toggle dictation for macOS

A menu-bar utility: press a trigger key anywhere on the Mac, speak, and the
transcribed text is either **typed at the focused cursor** or, if nothing
typeable is focused, **dropped on the clipboard** for manual paste
("rolling clipboard"). Inspired by Claude's dictation feature, but global.

Lives in its own folder, separate from `aistatus`, so the two never collide.

---

## Decisions (locked)

| Area | Decision |
|------|----------|
| **Stack** | Native **Swift** app, `LSUIElement` (menu-bar only, no Dock icon) |
| **STT engines** | **Both**, behind one `Transcriber` protocol, config-selectable: Apple `Speech.framework` (on-device) **and** local Whisper via **WhisperKit / MLX** |
| **Trigger** | Config-driven, **default = Caps Lock** (one-time `hidutil` remap → F18) |
| **Mode** | Config-driven, **default = toggle** (tap to start, tap to stop); `push_to_talk` (hold) also supported |
| **Output** | Type at focused cursor via `CGEvent`; fall back to clipboard when nothing typeable is focused |

### Open (sensible defaults chosen, easy to change)
- **Default engine:** `apple` (instant, zero setup); WhisperKit is the accuracy upgrade.
- **Bubble position:** `bottom-center` (Claude-style).

---

## Engine comparison (why support both)

| | Local Whisper (WhisperKit / MLX) | Apple Speech.framework |
|---|---|---|
| Accuracy | Higher — punctuation, jargon, proper nouns | Good everyday; weaker on jargon |
| Live partials | Extra work (chunked/streaming) | Native, trivial |
| Latency | After stop / chunked; `large-v3-turbo` fast on Apple Silicon | Near real-time |
| Model download | ~150 MB – 1.5 GB | None |
| Offline | 100% | `requiresOnDeviceRecognition = true` |
| CPU/battery | Heavier (ANE/Metal/CoreML) | Light |
| Setup | WhisperKit SwiftPM + manage models | Built in |

Both sit behind `Transcriber`; the config picks which is live. ~150 lines each.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  WhisperKey.app  (LSUIElement, menu-bar only)        │
│                                                       │
│  KeyMonitor ──(trigger)──▶ Recorder                  │
│  (CGEventTap)              (AVAudioEngine)            │
│       ▲  toggle | hold         │ 16kHz mono buffers   │
│       │                        ▼                      │
│  ConfigStore ◀─ config.json  Transcriber             │
│  (hot reload)                ├ AppleTranscriber       │
│                              └ WhisperKitTranscriber  │
│                                  │ text (+ partials)  │
│                                  ▼                    │
│  BubbleWindow ◀── partials ── OutputRouter            │
│  (NSPanel,                    ├ typeable? → type      │
│   non-activating)             └ else      → clipboard │
└─────────────────────────────────────────────────────┘
```

**Flow:**
- **Toggle mode** (default): trigger down → start capture + show bubble; trigger
  down again → stop, finalize, route output, hide bubble.
- **Push-to-talk mode**: trigger down → start; trigger up → stop + finalize.

The same `KeyMonitor` produces key down/up events; a `mode` flag decides the
state machine. With Caps Lock remapped to F18, each tap is a clean key event and
no longer toggles capitalization.

---

## Components

- **KeyMonitor** — `CGEventTap` (HID/session level) on key down/up. Drives either
  the toggle or hold state machine based on `mode`.
- **Recorder** — `AVAudioEngine` input tap → 16 kHz mono Float32 (both engines).
- **Transcriber** (protocol) — `AppleTranscriber` (`SFSpeechAudioBufferRecognitionRequest`,
  `requiresOnDeviceRecognition`, `addsPunctuation`) and `WhisperKitTranscriber`.
- **OutputRouter** — on finalize:
  1. `AXUIElementCreateSystemWide()` → `kAXFocusedUIElementAttribute`.
  2. Typeable? Role is `AXTextField`/`AXTextArea`/`AXComboBox`, or `kAXValueAttribute`
     is settable.
  3. Typeable → "type" via `CGEvent` + `keyboardSetUnicodeString` (works in
     terminals too, behaves like real typing).
  4. Not typeable → write to `NSPasteboard` (rolling clipboard; `replace` or `append`).
- **BubbleWindow** — borderless **non-activating** `NSPanel`
  (`.nonactivatingPanel`, `.floating`, `canBecomeKey = false`) so it never steals
  focus from the target field. Shows waveform + live partial transcript.
- **ConfigStore** — JSON at `~/.config/whisperkey/config.json`, hot-reloaded via a
  file watcher (same idea as aistatus's config reload).

---

## The Caps Lock catch

Caps Lock is a toggle key, so to use it cleanly (and stop it toggling
capitalization) remap it once to an unused key (F18):

```bash
hidutil property --set '{"UserKeyMapping":[
  {"HIDKeyboardModifierMappingSrc":0x700000039,
   "HIDKeyboardModifierMappingDst":0x70000006D}]}'
```

Each Caps Lock tap then fires a normal F18 down/up that the `CGEventTap` reads.
The installer applies this and a LaunchAgent re-applies it on login. Users who
prefer not to remap can set `trigger` to `fn` or a hotkey chord instead.

---

## Permissions (macOS)

- **Microphone** — `NSMicrophoneUsageDescription`
- **Speech Recognition** — `NSSpeechRecognitionUsageDescription` (Apple engine)
- **Input Monitoring** — for the `CGEventTap` to see the trigger
- **Accessibility** (`AXIsProcessTrusted`) — read focused element + post keystrokes

---

## Config file (defaults shown)

`~/.config/whisperkey/config.json`

```json
{
  "trigger": "capslock",          // capslock | fn | "ctrl+space"
  "mode": "toggle",               // toggle | push_to_talk
  "engine": "apple",              // apple | whisperkit
  "whisperModel": "large-v3-turbo",
  "language": "en",
  "clipboardBehavior": "replace", // replace | append
  "punctuation": true,
  "bubblePosition": "bottom-center"
}
```

---

## Project layout

```
whisperkey/
├── Package.swift                 # SwiftPM; deps: WhisperKit
├── PLAN.md                       # this file
├── Sources/WhisperKey/
│   ├── App.swift                 # LSUIElement, NSStatusItem
│   ├── KeyMonitor.swift          # CGEventTap + toggle/hold state machine
│   ├── Recorder.swift            # AVAudioEngine capture
│   ├── Transcriber.swift         # protocol
│   ├── AppleTranscriber.swift
│   ├── WhisperKitTranscriber.swift
│   ├── OutputRouter.swift        # type-vs-clipboard + AX focus
│   ├── BubbleWindow.swift        # non-activating NSPanel UI
│   └── ConfigStore.swift         # JSON + hot reload
├── install.sh                    # hidutil remap, LaunchAgent, perms guide
└── README.md
```

---

## Milestones (build order)

1. **Skeleton + menu bar** — `LSUIElement` app, status item, quit.
2. **KeyMonitor** — capture trigger, log down/up; sort out Input Monitoring +
   Caps Lock remap; implement toggle vs hold.
3. **Recorder + AppleTranscriber** — live transcript to console on tap-speak-tap.
4. **OutputRouter (type path)** — inject into a focused TextEdit window.
5. **OutputRouter (clipboard fallback)** + typeable detection.
6. **BubbleWindow** — non-activating overlay with live partials + waveform.
7. **ConfigStore** — externalize trigger/mode/engine/etc.
8. **WhisperKitTranscriber** — the accuracy backend.
9. **install.sh + README** — remap, LaunchAgent, permissions walkthrough.

Steps 1–4 = working end-to-end dictation; 5–9 = fallback, UI, options, packaging.
```
