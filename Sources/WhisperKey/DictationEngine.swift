import AVFoundation
import Foundation

/// Wires the pieces together and runs the toggle/hold state machine.
///   KeyMonitor (trigger) → start/stop → Recorder → Transcriber → OutputRouter
final class DictationEngine {
    enum Mode { case toggle, pushToTalk }

    var mode: Mode = .toggle
    var onStateChange: ((Bool) -> Void)?
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let keyMonitor = KeyMonitor()
    private let recorder = Recorder()
    private let router = OutputRouter()
    private var transcriber: Transcriber?
    private var config = Config()

    private var isRecording = false

    /// Apply (or hot-reload) settings. Safe to call any time; trigger/mode/
    /// output update live, while the engine choice takes effect next recording.
    func applyConfig(_ config: Config) {
        self.config = config
        mode = (config.mode == "push_to_talk") ? .pushToTalk : .toggle
        keyMonitor.triggerKeyCode = config.triggerKeyCode
        switch config.output {
        case "type":      router.strategy = .type
        case "clipboard": router.strategy = .clipboard
        default:          router.strategy = .paste
        }
        router.clipboardBehavior = (config.clipboardBehavior == "append") ? .append : .replace
    }

    private func makeTranscriber() -> Transcriber {
        // WhisperKit lands in M8; until then everything uses the Apple engine.
        let apple = AppleTranscriber()
        apple.localeIdentifier = config.localeIdentifier
        apple.addsPunctuation = config.punctuation
        if config.engine == "whisperkit" {
            NSLog("WhisperKey: engine 'whisperkit' not built yet — using Apple engine.")
        }
        return apple
    }

    func start() {
        keyMonitor.onTriggerDown = { [weak self] in
            guard let self = self else { return }
            switch self.mode {
            case .toggle:     self.toggleRecording()
            case .pushToTalk: self.beginRecording()
            }
        }
        keyMonitor.onTriggerUp = { [weak self] in
            guard let self = self, self.mode == .pushToTalk else { return }
            self.endRecording()
        }
        keyMonitor.start()
    }

    private func toggleRecording() {
        if isRecording { endRecording() } else { beginRecording() }
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        onStateChange?(true)

        let transcriber = makeTranscriber()
        self.transcriber = transcriber
        transcriber.onPartial = { [weak self] text in
            self?.onPartial?(text)
        }

        do {
            try transcriber.start()
            try recorder.start(
                onAudio: { [weak self] buffer in self?.transcriber?.append(buffer) },
                onLevel: { [weak self] rms in
                    self?.transcriber?.noteLevel(rms)
                    self?.onLevel?(rms)
                }
            )
        } catch {
            NSLog("WhisperKey: failed to start recording — %@", String(describing: error))
            abortRecording()
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        onStateChange?(false)

        recorder.stop()
        transcriber?.finish { [weak self] finalText in
            self?.router.deliver(finalText)
        }
        transcriber = nil
    }

    private func abortRecording() {
        isRecording = false
        onStateChange?(false)
        recorder.stop()
        transcriber?.finish { _ in }
        transcriber = nil
    }
}
