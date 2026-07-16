import AppKit
import ApplicationServices

/// Delivers the final transcript into the focused app.
///
/// Strategy (`paste` by default) decides *how* the text gets in:
///  - `.paste`  — set clipboard + synthesize ⌘V. Works almost everywhere,
///                including Electron apps, terminals, and TUIs (Claude Code).
///                Saves and restores the previous clipboard.
///  - `.type`   — per-character synthesized Unicode key events. Cleaner (never
///                touches the clipboard) but fails in many non-native apps.
///
/// If Accessibility isn't granted we can neither paste nor type, so we leave the
/// text on the clipboard for a manual paste ("rolling clipboard").
final class OutputRouter {
    enum Strategy { case paste, type, clipboard }
    enum ClipboardBehavior { case replace, append }

    /// Default to paste for maximum app compatibility.
    var strategy: Strategy = .paste
    var clipboardBehavior: ClipboardBehavior = .replace

    func deliver(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Clipboard mode never needs Accessibility.
        if strategy == .clipboard {
            copyToClipboard(trimmed)
            NSLog("WhisperKey: copied to clipboard (%@).", clipboardBehavior == .append ? "append" : "replace")
            return
        }

        guard AXIsProcessTrusted() else {
            copyToClipboard(trimmed)
            NSLog("WhisperKey: Accessibility not trusted — left text on clipboard for manual paste.")
            return
        }

        switch strategy {
        case .paste:
            // Always paste — AX focus detection is unreliable in Electron apps,
            // terminals, and TUIs (Claude Code), so we can't gate ⌘V on it
            // without breaking those. We only use focus detection to decide
            // whether to restore the previous clipboard: if we're confident a
            // field was focused, the paste landed and we restore politely. If
            // not (no field, or an undetectable one), we leave the transcript
            // on the clipboard so it's never lost.
            pasteText(trimmed, restorePrevious: isTypeableElementFocused())
        case .type:
            if isTypeableElementFocused() {
                typeText(trimmed)
            } else {
                copyToClipboard(trimmed)
                NSLog("WhisperKey: no typeable field focused — copied to clipboard.")
            }
        case .clipboard:
            break // handled above
        }
    }

    /// Write a running backup of the in-progress transcript to the clipboard so
    /// spoken text is never lost if the recognizer resets mid-session. Pure
    /// clipboard write — no paste, no restore. Intentionally overrides whatever
    /// was on the clipboard (the user opted into this as a safety net).
    func backup(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(trimmed, forType: .string)
    }

    // MARK: Focus detection

    /// Editable roles we treat as "type here". Broad on purpose.
    private let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    private func isTypeableElementFocused() -> Bool {
        guard AXIsProcessTrusted() else {
            NSLog("WhisperKey: Accessibility NOT trusted — cannot detect focus or type. Falling back to clipboard.")
            return false
        }

        guard let element = focusedElement() else {
            NSLog("WhisperKey: no focused UI element found — clipboard fallback.")
            return false
        }

        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "?"

        // 1) Known editable role.
        if editableRoles.contains(role) {
            NSLog("WhisperKey: focus role=%@ (editable role) → type.", role)
            return true
        }
        // 2) Has a text selection range — strong signal of a text control,
        //    present even when the value isn't reported settable (NSTextView,
        //    many web inputs, code editors).
        if hasAttribute(element, kAXSelectedTextRangeAttribute as CFString) {
            NSLog("WhisperKey: focus role=%@ (has selected-text-range) → type.", role)
            return true
        }
        // 3) Value is writable.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            NSLog("WhisperKey: focus role=%@ (settable value) → type.", role)
            return true
        }

        NSLog("WhisperKey: focus role=%@ not editable → clipboard fallback.", role)
        return false
    }

    /// Try the system-wide focused element; if that's empty, fall back to the
    /// focused application's focused element.
    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        if let el = elementAttribute(system, kAXFocusedUIElementAttribute as CFString) {
            return el
        }
        if let app = elementAttribute(system, kAXFocusedApplicationAttribute as CFString),
           let el = elementAttribute(app, kAXFocusedUIElementAttribute as CFString) {
            return el
        }
        return nil
    }

    // MARK: AX helpers

    private func elementAttribute(_ element: AXUIElement, _ attr: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func stringAttribute(_ element: AXUIElement, _ attr: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success else { return nil }
        return value as? String
    }

    private func hasAttribute(_ element: AXUIElement, _ attr: CFString) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attr, &value) == .success
    }

    /// Live-streaming path: type a freshly committed segment straight into
    /// whatever has focus, with no clipboard involvement (a per-segment ⌘V
    /// would thrash the user's clipboard many times a minute). No focus
    /// gating either — in live mode the user has deliberately parked the
    /// cursor in the target box.
    func typeLive(_ delta: String) {
        guard !delta.isEmpty, AXIsProcessTrusted() else { return }
        typeText(delta)
    }

    // MARK: Output paths

    private func typeText(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let chunkSize = 20
        var chunk = [UInt16]()
        chunk.reserveCapacity(chunkSize + 4)

        func flush() {
            guard !chunk.isEmpty else { return }
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down.post(tap: .cgSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                up.post(tap: .cgSessionEventTap)
            }
            chunk.removeAll(keepingCapacity: true)
        }

        // Chunk on Character boundaries: splitting a surrogate pair (emoji) or a
        // combining sequence across events would post half a code point and the
        // target app would render garbage.
        for character in text {
            let units = Array(String(character).utf16)
            if chunk.count + units.count > chunkSize { flush() }
            chunk.append(contentsOf: units)
        }
        flush()
    }

    /// Universal insertion: stash text on the clipboard, synthesize ⌘V, then
    /// (optionally) restore the user's previous clipboard string.
    ///
    /// `restorePrevious` should only be true when we're confident the paste
    /// landed in a focused field. When false we leave the transcript on the
    /// clipboard so it survives for a manual paste.
    private func pasteText(_ text: String, restorePrevious: Bool) {
        let pasteboard = NSPasteboard.general
        let previous = restorePrevious ? pasteboard.string(forType: .string) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()
        NSLog("WhisperKey: delivered via paste (⌘V), restore=%@.", restorePrevious ? "yes" : "no")

        // Paste is async; wait a beat before restoring the old clipboard so the
        // target app reads our text first.
        if let previous = previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(previous, forType: .string)
            }
        }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'
        if let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cgSessionEventTap)
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        var toWrite = text
        if clipboardBehavior == .append,
           let previous = pasteboard.string(forType: .string), !previous.isEmpty {
            toWrite = previous + "\n" + text
        }
        pasteboard.clearContents()
        pasteboard.setString(toWrite, forType: .string)
    }
}
