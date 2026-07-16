import AppKit
import ApplicationServices
import AVFoundation
import FluidAudio

/// Text-to-speech: reads the currently selected text aloud — the counterpart to
/// dictation when working with an AI (dictate the prompt, listen to the reply).
///
/// Two engines, config-selectable like the STT side:
///  - `apple`  — AVSpeechSynthesizer. Instant, every system voice, any language.
///  - `neural` — PocketTTS via FluidAudio: a local neural voice running fully
///               on-device (CoreML). Model downloads once from Hugging Face and
///               is cached; audio never leaves the Mac. Falls back to the Apple
///               voice if synthesis fails.
///
/// Triggered by the "Caps Lock + S" chord (or the menu item); triggering again
/// while active — or pressing Esc — stops playback.
final class Speaker: NSObject {
    enum Phase { case idle, preparing, speaking }

    /// Fired on the main queue with the new phase and the text being spoken
    /// (empty when idle). Drives the bubble's "speaking" state.
    var onPhaseChange: ((Phase, String) -> Void)?

    var engine = "apple"        // apple | neural
    var voice = ""              // Apple: AVSpeechSynthesisVoice identifier; neural: PocketTTS voice name
    var rate: Double = 0.5      // Apple engine only; 0…1, 0.5 ≈ natural

    private(set) var phase: Phase = .idle
    var isActive: Bool { phase != .idle }

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var neuralJob: Task<Void, Never>?

    /// Neural synthesis is capped so a whole-document selection can't queue
    /// minutes of model inference before the first sound comes out.
    private let neuralCharacterCap = 4000

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Chord / menu entry point: speak the current selection, or stop if
    /// already speaking (the chord doubles as its own stop button).
    func toggleSpeakSelection() {
        if isActive {
            stop()
            return
        }
        SelectionReader.fetch { [weak self] text in
            guard let self else { return }
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                NSLog("WhisperKey: speak — no selected text found.")
                return
            }
            self.speak(trimmed)
        }
    }

    func speak(_ text: String) {
        stop()
        if engine == "neural" {
            speakNeural(text)
        } else {
            speakApple(text)
        }
    }

    func stop() {
        neuralJob?.cancel()
        neuralJob = nil
        player?.stop()
        player = nil
        synth.stopSpeaking(at: .immediate)
        setPhase(.idle, "")
    }

    // MARK: Apple engine

    private func speakApple(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        if !voice.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voice) {
            utterance.voice = v
        }
        utterance.rate = Float(min(max(rate, 0), 1))
        setPhase(.speaking, text)
        synth.speak(utterance)
    }

    // MARK: Neural engine (PocketTTS, fully on-device)

    /// Memoized across utterances — model load/download happens once.
    private static var pocketTask: Task<PocketTtsManager, Error>?

    private static func loadPocket() -> Task<PocketTtsManager, Error> {
        if let task = pocketTask { return task }
        let task = Task { () -> PocketTtsManager in
            let manager = PocketTtsManager()
            try await manager.initialize()
            NSLog("WhisperKey: PocketTTS ready — local neural voice, fully on-device.")
            return manager
        }
        pocketTask = task
        return task
    }

    /// Warm the neural model so the first spoken reply doesn't wait for a load.
    static func prewarmNeural() {
        _ = loadPocket()
    }

    private func speakNeural(_ text: String) {
        let capped = String(text.prefix(neuralCharacterCap))
        setPhase(.preparing, capped)
        let chosenVoice = voice
        neuralJob = Task { [weak self] in
            do {
                let manager = try await Self.loadPocket().value
                let wav = try await manager.synthesize(
                    text: capped,
                    voice: chosenVoice.isEmpty ? nil : chosenVoice
                )
                try Task.checkCancellation()
                await MainActor.run { self?.play(wav, text: capped) }
            } catch is CancellationError {
                // stop() already reset the phase.
            } catch {
                NSLog("WhisperKey: neural TTS failed — falling back to Apple voice. %@",
                      String(describing: error))
                await MainActor.run {
                    guard let self, self.phase == .preparing else { return }
                    self.speakApple(capped)
                }
            }
        }
    }

    private func play(_ wav: Data, text: String) {
        guard phase == .preparing else { return }   // cancelled while synthesizing
        do {
            let p = try AVAudioPlayer(data: wav)
            p.delegate = self
            player = p
            setPhase(.speaking, text)
            p.play()
        } catch {
            NSLog("WhisperKey: could not play synthesized audio — %@", String(describing: error))
            setPhase(.idle, "")
        }
    }

    private func setPhase(_ new: Phase, _ text: String) {
        guard new != phase || new == .idle else { return }
        let changed = new != phase
        phase = new
        if changed { onPhaseChange?(new, text) }
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        setPhase(.idle, "")
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        setPhase(.idle, "")
    }
}

extension Speaker: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        setPhase(.idle, "")
    }
}

/// Reads the user's current text selection without disturbing it.
///
/// Fast path: the Accessibility API's `kAXSelectedTextAttribute` on the focused
/// element. Fallback (Electron apps, terminals, web views that don't expose AX
/// selections): synthesize ⌘C, read the clipboard, then put the user's previous
/// clipboard back — the same "borrow the clipboard politely" trick the paste
/// path uses.
enum SelectionReader {
    static func fetch(_ completion: @escaping (String?) -> Void) {
        if let s = axSelectedText(), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completion(s)
            return
        }
        guard AXIsProcessTrusted() else {
            completion(nil)
            return
        }
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        let before = pb.changeCount
        postCommandC()
        // ⌘C is async in the target app; give it a beat to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            var copied: String?
            if pb.changeCount != before {
                copied = pb.string(forType: .string)
                // Restore the user's clipboard so borrowing it is invisible.
                pb.clearContents()
                if let previous { pb.setString(previous, forType: .string) }
            }
            completion(copied)
        }
    }

    private static func axSelectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 8 // 'c'
        if let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cgSessionEventTap)
        }
    }
}
