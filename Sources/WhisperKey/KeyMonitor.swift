import AppKit
import CoreGraphics

/// Watches the global keyboard for the trigger key via a CGEventTap and emits
/// down/up callbacks. The DictationEngine turns those into start/stop.
///
/// Default trigger is F18 (virtual keycode 79), which is what Caps Lock fires
/// after the one-time hidutil remap. We swallow the trigger so it never leaks
/// into the focused app.
final class KeyMonitor {
    var onTriggerDown: (() -> Void)?
    var onTriggerUp: (() -> Void)?

    /// F18. (Caps Lock → F18 via hidutil; see scripts/remap-capslock.sh.)
    var triggerKeyCode: CGKeyCode = 79

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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
        NSLog("WhisperKey: event tap active (trigger keycode %d).", Int(triggerKeyCode))
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables the tap if our callback is too slow or on certain
        // input events. Re-enable and pass the event through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == triggerKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        // Ignore auto-repeat so a held key doesn't fire repeated downs.
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if type == .keyDown {
            if !isRepeat { DispatchQueue.main.async { self.onTriggerDown?() } }
        } else if type == .keyUp {
            DispatchQueue.main.async { self.onTriggerUp?() }
        }

        // Swallow the trigger so it doesn't reach the focused app.
        return nil
    }
}
