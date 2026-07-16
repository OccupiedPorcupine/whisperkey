import AppKit
import AVFoundation
import Foundation

/// Wires the pieces together and runs the toggle/hold state machine.
///   KeyMonitor (trigger) → start/stop → Recorder → Transcriber → OutputRouter
final class DictationEngine {
    enum Mode { case toggle, pushToTalk }
    /// Pipeline stage, for state-aware UI (bubble accent/placeholder).
    enum Phase { case listening, transcribing, polishing }

    var mode: Mode = .toggle
    var onStateChange: ((Bool) -> Void)?
    var onPhase: ((Phase) -> Void)?
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Fired on the main queue once the transcript has been delivered (or the
    /// session aborted). Drives bubble teardown — kept separate from
    /// `onStateChange` so the bubble can stay up during finalize + polish.
    var onFinished: (() -> Void)?
    /// Fired with the final text right after it is routed — feeds history.
    var onDelivered: ((String) -> Void)?
    /// Fired on the "speak selection" chord (Caps Lock + S) — the TTS side.
    var onSpeakRequest: (() -> Void)?
    /// Live-transcription lifecycle: (active, description) — description names
    /// the target (the note, or "focused app") for menu/UI labels.
    var onLiveStateChange: ((Bool, String?) -> Void)?
    /// Fired when Esc is pressed while nothing is being recorded here but
    /// `externalEscapeInterest` is set (e.g. TTS playback is active).
    var onExternalEscape: (() -> Void)?

    /// Set by the app while something outside this engine (TTS) wants Esc.
    var externalEscapeInterest = false {
        didSet { syncEscapeIntercept() }
    }

    private let keyMonitor = KeyMonitor()
    private let recorder = Recorder()
    private let router = OutputRouter()
    private var transcriber: Transcriber?
    private var config = Config()

    private var meetingChordCode: CGKeyCode?
    private var speakChordCode: CGKeyCode?

    private var isRecording = false {
        didSet { syncEscapeIntercept() }
    }

    // MARK: Live transcription (streaming into a note or the focused textbox)

    enum LiveTarget { case obsidian, typing }

    private var liveTarget: LiveTarget? {
        didSet { syncEscapeIntercept() }
    }
    private var liveWriter: LiveNoteWriter?
    /// Characters of the committed transcript already streamed to the target.
    private var liveDelivered = 0
    /// True while the final flush is in flight, so a double stop can't wedge.
    private var liveFinishing = false

    var isLive: Bool { liveTarget != nil }

    /// High-water-mark backup of the current session's transcript. Grows as
    /// segments are banked and is mirrored to the clipboard, so a recognizer
    /// reset can never lose earlier words.
    private var transcriptBackup = ""

    /// Apply (or hot-reload) settings. Safe to call any time; trigger/mode/
    /// output update live, while the engine choice takes effect next recording.
    func applyConfig(_ config: Config) {
        self.config = config
        mode = (config.mode == "push_to_talk") ? .pushToTalk : .toggle
        keyMonitor.triggerKeyCode = config.triggerKeyCode
        meetingChordCode = config.chordKeyCode
        speakChordCode = config.speakChordKeyCode
        keyMonitor.chordKeyCodes = Set([meetingChordCode, speakChordCode].compactMap { $0 })
        switch config.output {
        case "type":      router.strategy = .type
        case "clipboard": router.strategy = .clipboard
        default:          router.strategy = .paste
        }
        router.clipboardBehavior = (config.clipboardBehavior == "append") ? .append : .replace
    }

    private func makeTranscriber() -> Transcriber {
        let resolved = EngineCatalog.resolved(config.engine)
        if resolved != config.engine {
            NSLog("WhisperKey: engine '%@' not available yet — using '%@'.", config.engine, resolved)
        }
        if resolved == "whisperkit" {
            let wk = WhisperKitTranscriber()
            wk.modelName = config.whisperModel
            wk.language = config.language
            return wk
        }
        if resolved == "parakeet" {
            let pk = ParakeetTranscriber()
            pk.language = config.language
            return pk
        }
        let apple = AppleTranscriber()
        apple.localeIdentifier = config.localeIdentifier
        apple.addsPunctuation = config.punctuation
        apple.contextualStrings = config.dictionary
        return apple
    }

    func start() {
        // Push-to-talk drives off the raw down/up edges...
        keyMonitor.onTriggerDown = { [weak self] in
            guard let self = self, self.mode == .pushToTalk else { return }
            self.beginRecording()
        }
        keyMonitor.onTriggerUp = { [weak self] in
            guard let self = self, self.mode == .pushToTalk else { return }
            self.endRecording()
        }
        // ...while toggle acts on a clean tap (keyUp with no chord), so the
        // "Caps Lock + M" chord can pre-empt a dictation toggle.
        keyMonitor.onTap = { [weak self] in
            guard let self = self, self.mode == .toggle else { return }
            self.toggleRecording()
        }
        // Chord dispatch: Caps Lock + M → Oracle meeting hand-off;
        //                 Caps Lock + S → speak the current selection (TTS).
        keyMonitor.onChord = { [weak self] keyCode in
            guard let self = self else { return }
            if keyCode == self.meetingChordCode {
                MeetingSignal.postToggle()
            } else if keyCode == self.speakChordCode {
                self.onSpeakRequest?()
            }
        }
        // Esc cancels: a live stream stops (keeping its text), an in-flight
        // recording is discarded, otherwise the interest belongs to someone
        // external (TTS playback).
        keyMonitor.onEscape = { [weak self] in
            guard let self = self else { return }
            if self.isLive {
                self.stopLiveTranscription()
            } else if self.isRecording {
                self.cancelRecording()
            } else {
                self.onExternalEscape?()
            }
        }
        keyMonitor.start()
    }

    private func syncEscapeIntercept() {
        keyMonitor.interceptEscape = isRecording || isLive || externalEscapeInterest
    }

    /// Esc while dictating: stop capture and throw the transcript away.
    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        onStateChange?(false)
        recorder.stop()
        transcriber?.finish { _ in }   // discard
        transcriber = nil
        NSLog("WhisperKey: dictation cancelled (esc).")
        onFinished?()
    }

    // MARK: Live transcription

    /// Start streaming speech into `target` until stopped (menu, trigger tap,
    /// or Esc). Always uses the Apple engine — it's the only one that emits
    /// committed segments mid-session, which is what streaming needs. Each
    /// pause-finalized segment is delivered incrementally (delta only), so the
    /// note/textbox grows sentence by sentence while the bubble shows the
    /// in-flight words live. Unbounded: the accumulating-pool transcriber
    /// rotates recognizers forever.
    func startLiveTranscription(to target: LiveTarget) {
        guard !isLive else { return }
        if isRecording { cancelRecording() }

        var writer: LiveNoteWriter?
        if target == .obsidian {
            do {
                writer = try LiveNoteWriter(vaultPath: config.obsidianVaultPath,
                                            folder: config.obsidianFolder)
            } catch {
                NSLog("WhisperKey: could not start live note — %@", String(describing: error))
                onPartial?("No Obsidian vault found — set obsidianVaultPath in config")
                return
            }
        }

        let apple = AppleTranscriber()
        apple.localeIdentifier = config.localeIdentifier
        apple.addsPunctuation = config.punctuation
        apple.contextualStrings = config.dictionary
        apple.onPartial = { [weak self] text in self?.onPartial?(text) }
        apple.onCommit = { [weak self] committed in self?.deliverLiveDelta(committed) }

        // Assign before starting the recorder: the tap callback reads
        // `self.transcriber` on the audio thread, so a late assignment would
        // silently drop the first buffers (the opening words of the session).
        transcriber = apple
        do {
            try apple.start()
            try recorder.start(
                onAudio: { [weak self] buffer in self?.transcriber?.append(buffer) },
                onLevel: { [weak self] rms in
                    self?.transcriber?.noteLevel(rms)
                    self?.onLevel?(rms)
                }
            )
        } catch {
            NSLog("WhisperKey: failed to start live transcription — %@", String(describing: error))
            transcriber = nil
            if let writer {
                // Don't leave a stray header-only note in the vault.
                writer.close()
                try? FileManager.default.removeItem(at: writer.fileURL)
            }
            return
        }

        liveWriter = writer
        liveDelivered = 0
        liveTarget = target
        onStateChange?(true)
        onLiveStateChange?(true, writer?.displayName ?? "focused app")
        writer?.openInObsidian()
        NSLog("WhisperKey: live transcription started → %@.",
              target == .obsidian ? "Obsidian note" : "focused app")
    }

    /// Stop the live stream, flushing the final in-flight words to the target.
    func stopLiveTranscription() {
        guard isLive, !liveFinishing else { return }
        liveFinishing = true
        onStateChange?(false)
        recorder.stop()
        let finishing = transcriber
        transcriber = nil
        finishing?.finish { [weak self] finalText in
            guard let self = self else { return }
            self.deliverLiveDelta(finalText)
            let full = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !full.isEmpty { self.onDelivered?(full) }   // → history
            self.liveWriter?.close()
            self.liveWriter = nil
            self.liveTarget = nil
            self.liveFinishing = false
            self.onLiveStateChange?(false, nil)
            self.onFinished?()
            NSLog("WhisperKey: live transcription stopped (%d chars streamed).", self.liveDelivered)
        }
    }

    /// Commits carry the full transcript-so-far; stream only what's new.
    private func deliverLiveDelta(_ committed: String) {
        guard committed.count > liveDelivered else { return }
        let delta = String(committed.dropFirst(liveDelivered))
        liveDelivered = committed.count
        switch liveTarget {
        case .obsidian: liveWriter?.append(delta)
        case .typing:   router.typeLive(delta)
        case nil:       break
        }
    }

    private func toggleRecording() {
        // The trigger doubles as the live-mode stop button.
        if isLive { stopLiveTranscription(); return }
        if isRecording { endRecording() } else { beginRecording() }
    }

    private func beginRecording() {
        if isLive { stopLiveTranscription(); return }
        guard !isRecording else { return }
        isRecording = true
        onStateChange?(true)
        onPhase?(.listening)
        transcriptBackup = ""

        // Warm the on-device LLM now so the polish pass is snappy when we stop.
        if config.polish { TranscriptPolisher.prewarm() }

        let transcriber = makeTranscriber()
        self.transcriber = transcriber
        transcriber.onPartial = { [weak self] text in
            self?.onPartial?(text)
        }
        transcriber.onCommit = { [weak self] committed in
            self?.noteBackup(committed)
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
        onPhase?(.transcribing)

        recorder.stop()
        transcriber?.finish { [weak self] finalText in
            guard let self = self else { return }
            // Guard against a mid-session reset truncating the result: deliver
            // whichever is more complete, the recognizer's final or the backup.
            let best = finalText.count >= self.transcriptBackup.count ? finalText : self.transcriptBackup
            self.deliver(best)
        }
        transcriber = nil
    }

    /// Final delivery, optionally via the on-device LLM cleanup pass. Always ends
    /// by signalling `onFinished` so the UI tears down exactly once.
    private func deliver(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onFinished?(); return }

        guard config.polish, TranscriptPolisher.isAvailable else {
            router.deliver(trimmed)
            onDelivered?(trimmed)
            archiveToObsidian(trimmed)
            onFinished?()
            return
        }

        onPhase?(.polishing)
        onPartial?("Polishing…")
        let vocabulary = config.dictionary
        Task {
            let polished = await TranscriptPolisher.polish(trimmed, vocabulary: vocabulary)
            await MainActor.run {
                self.router.deliver(polished)
                self.onDelivered?(polished)
                self.archiveToObsidian(polished)
                self.onFinished?()
            }
        }
    }

    /// When Obsidian logging is enabled, save the finalized transcript as its own
    /// vault note with an AI-generated title. Runs after delivery so it never
    /// delays getting text into the focused app; failures are logged, not fatal.
    private func archiveToObsidian(_ text: String) {
        guard config.obsidianLogging else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Capture the destination app now, on the main thread: we're not
        // activating (LSUIElement), so the frontmost app is still the one the
        // text was just delivered into. Recorded in the note for backlinking.
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let cfg = config
        Task {
            let title = await TranscriptPolisher.title(for: trimmed)
            do {
                _ = try ObsidianVault.writeDictationNote(
                    text: trimmed, title: title, appName: appName,
                    vaultPath: cfg.obsidianVaultPath,
                    folder: cfg.obsidianLogFolder,
                    nameFormat: cfg.obsidianNoteNameFormat)
            } catch {
                NSLog("WhisperKey: could not archive dictation to Obsidian — %@", String(describing: error))
            }
        }
    }

    /// Persist a banked transcript to the clipboard, but only when it's longer
    /// than what we've already saved this session — so the backup never shrinks
    /// even if the recognizer hands us a shorter string after a reset.
    private func noteBackup(_ text: String) {
        guard text.count > transcriptBackup.count else { return }
        transcriptBackup = text
        router.backup(text)
    }

    private func abortRecording() {
        isRecording = false
        onStateChange?(false)
        onFinished?()
        recorder.stop()
        transcriber?.finish { _ in }
        transcriber = nil
    }
}
