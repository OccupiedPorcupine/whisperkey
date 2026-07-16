import AppKit
import CoreGraphics

/// Watches the global keyboard for the trigger key via a CGEventTap and emits
/// down/up/tap callbacks, plus an optional chord callback. The DictationEngine
/// turns those into start/stop.
///
/// Default trigger is F18 (virtual keycode 79), which is what Caps Lock fires
/// after the one-time hidutil remap. We swallow the trigger so it never leaks
/// into the focused app.
///
/// Chord support: when a key in `chordKeyCodes` is pressed *while the trigger is
/// held*, we emit `onChord(keyCode)` and swallow that key. This lets gestures
/// like "Caps Lock + M" (meeting hand-off) and "Caps Lock + S" (speak selection)
/// hang off the same key WhisperKey already owns. Because the trigger is
/// swallowed here, no other process can see it independently — so chords must be
/// detected in this tap.
///
/// Escape support: while `interceptEscape` is true (a dictation or TTS playback
/// is active), a plain Esc press is swallowed and emitted as `onEscape` — the
/// universal "cancel" affordance.
final class KeyMonitor {
    /// Fired on trigger keyDown (push-to-talk begins here).
    var onTriggerDown: (() -> Void)?
    /// Fired on trigger keyUp (push-to-talk ends here).
    var onTriggerUp: (() -> Void)?
    /// Fired on a *clean* trigger tap — keyUp with no chord key pressed during the
    /// hold. Toggle mode acts here so a chord can pre-empt it.
    var onTap: (() -> Void)?
    /// Fired when a chord key is pressed while the trigger is held, with the
    /// chord key's keycode so the listener can dispatch per-gesture.
    var onChord: ((CGKeyCode) -> Void)?
    /// Fired when Esc is pressed while `interceptEscape` is true.
    var onEscape: (() -> Void)?

    /// F18. (Caps Lock → F18 via hidutil; see scripts/remap-capslock.sh.)
    var triggerKeyCode: CGKeyCode = 79
    /// Chord companion keys (Caps Lock + <key>). Keycode 0 entries are ignored.
    var chordKeyCodes: Set<CGKeyCode> = [46]
    /// When true, a bare Esc press is swallowed and fires `onEscape`.
    var interceptEscape = false

    private let escapeKeyCode: CGKeyCode = 53

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var triggerDown = false
    private var chordFiredDuringHold = false
    private var swallowedChordKeys = Set<CGKeyCode>()

    func start() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            NSLog("WhisperKey: could not create event tap. Grant Input Monitoring + Accessibility in System Settings, then relaunch.")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("WhisperKey: event tap active (trigger keycode %d, chords %@).",
              Int(triggerKeyCode), chordKeyCodes.map(String.init).joined(separator: ","))
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables the tap if our callback is too slow or on certain
        // input events. Re-enable and pass the event through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // --- Escape (cancel) --------------------------------------------------
        if keyCode == escapeKeyCode && interceptEscape {
            // Only a bare Esc (no modifiers) counts, so shortcuts like ⌥Esc pass.
            let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            if modifiers.isEmpty {
                if type == .keyDown {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if !isRepeat { DispatchQueue.main.async { self.onEscape?() } }
                }
                // Swallow both edges so the frontmost app never sees the cancel.
                return nil
            }
        }

        // --- Chord keys (e.g. M, S) -------------------------------------------
        // (Membership alone decides: 0 is the letter A, a perfectly valid chord.)
        if chordKeyCodes.contains(keyCode) {
            if type == .keyDown && triggerDown {
                // Chord! Fire it once per hold and swallow the key so no stray
                // character leaks into the focused app.
                chordFiredDuringHold = true
                swallowedChordKeys.insert(keyCode)
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat { DispatchQueue.main.async { self.onChord?(keyCode) } }
                return nil
            }
            if type == .keyUp && swallowedChordKeys.contains(keyCode) {
                // Swallow the matching keyUp so the down/up pair stays balanced.
                swallowedChordKeys.remove(keyCode)
                return nil
            }
            // Otherwise it's an ordinary keypress — pass it through.
            return Unmanaged.passUnretained(event)
        }

        // --- Trigger key (F18) ----------------------------------------------
        guard keyCode == triggerKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        // Ignore auto-repeat so a held key doesn't fire repeated downs.
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if type == .keyDown {
            if !isRepeat {
                triggerDown = true
                chordFiredDuringHold = false
                DispatchQueue.main.async { self.onTriggerDown?() }
            }
        } else if type == .keyUp {
            triggerDown = false
            let wasCleanTap = !chordFiredDuringHold
            DispatchQueue.main.async {
                self.onTriggerUp?()
                if wasCleanTap { self.onTap?() }
            }
        }

        // Swallow the trigger so it doesn't reach the focused app.
        return nil
    }
}
