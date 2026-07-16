import AVFoundation
import Foundation
import Speech

/// Apple Speech.framework backend (on-device when supported).
///
/// Design: a growing **accumulated** transcript plus the current in-flight
/// **partial**. Whenever a segment finalizes — the recognizer ends an utterance
/// at a natural pause, or we force it near the ~1-minute request ceiling — we
/// fold the partial into `accumulated` and immediately start a fresh recognizer.
/// That lets you talk indefinitely across any number of pauses without ever
/// losing earlier words (the way Claude's dictation behaves).
///
/// All mutable state is serialized on `q`; callbacks to the app go to main.
final class AppleTranscriber: Transcriber {
    var onPartial: ((String) -> Void)?
    var onCommit: ((String) -> Void)?

    var localeIdentifier = "en-US"
    var addsPunctuation = true
    /// Custom dictionary: names/jargon the recognizer should bias toward.
    var contextualStrings: [String] = []

    private lazy var recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var accumulated = ""   // finalized utterances this session
    private var partial = ""       // current in-flight segment
    private var running = false
    private var finishCompletion: ((String) -> Void)?

    /// Identifies the live segment. Each rotation bumps it; callbacks from a
    /// previous (now-dead) recognition task carry a stale id and are ignored, so
    /// a late result/error can't clobber the new segment's in-flight words.
    private var generation = 0

    private var segmentStart = Date()
    private var silenceStart: Date?
    private let silenceThreshold: Float = 0.012
    private let pauseDuration: TimeInterval = 0.6   // silence that counts as a sentence break
    private let minSegment: TimeInterval = 1.0      // don't finalize ultra-short blips
    private let hardCap: TimeInterval = 55          // forced rotate for no-pause monologues (< Apple's ~60s)

    private let q = DispatchQueue(label: "whisperkey.apple-transcriber")

    func start() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "WhisperKey", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable"])
        }
        q.sync {
            accumulated = ""
            partial = ""
            finishCompletion = nil
            running = true
            beginSegment()
        }
    }

    // On q. Starts a fresh recognition request/task.
    private func beginSegment() {
        guard running, let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = addsPunctuation
        if !contextualStrings.isEmpty { req.contextualStrings = contextualStrings }
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        partial = ""
        segmentStart = Date()
        silenceStart = nil

        generation &+= 1
        let gen = generation
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.q.async { self?.handle(result: result, error: error, gen: gen) }
        }
    }

    // On q.
    private func handle(result: SFSpeechRecognitionResult?, error: Error?, gen: Int) {
        // Drop callbacks from a rotated-out task — they belong to a dead segment.
        guard gen == generation else { return }
        if let result {
            partial = result.bestTranscription.formattedString
            emit()
            if result.isFinal { rollSegment() }
        } else if error != nil {
            // Task ended (after endAudio, the time limit, or an error).
            rollSegment()
        }
    }

    // On q. Commit the partial, then either continue or deliver the final.
    private func rollSegment() {
        commitPartial()
        if running {
            beginSegment()
        } else {
            deliverFinal()
        }
    }

    // On q.
    private func commitPartial() {
        let p = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty {
            accumulated = accumulated.isEmpty ? p : accumulated + " " + p
        }
        partial = ""
        request = nil
        task?.cancel()   // stop the rotated-out task from emitting stale callbacks
        task = nil
        // Checkpoint the banked transcript while still recording, so it's safely
        // backed up before we start a fresh segment (the final roll at finish is
        // delivered separately).
        if running, !accumulated.isEmpty {
            let acc = accumulated
            DispatchQueue.main.async { self.onCommit?(acc) }
        }
    }

    private func emit() {
        let text = combinedText()
        DispatchQueue.main.async { self.onPartial?(text) }
    }

    private func combinedText() -> String {
        if accumulated.isEmpty { return partial }
        if partial.isEmpty { return accumulated }
        return accumulated + " " + partial
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        q.async { self.request?.append(buffer) }
    }

    func noteLevel(_ rms: Float) {
        q.async {
            guard self.running, self.request != nil else { return }
            let now = Date()
            if rms < self.silenceThreshold {
                if self.silenceStart == nil { self.silenceStart = now }
            } else {
                self.silenceStart = nil
            }
            let elapsed = now.timeIntervalSince(self.segmentStart)
            let inPause = self.silenceStart.map { now.timeIntervalSince($0) > self.pauseDuration } ?? false
            let hasWords = !self.partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            // Finalize at every genuine sentence pause (banking the words), or
            // force a rotation for a long no-pause monologue.
            if (inPause && hasWords && elapsed > self.minSegment) || elapsed > self.hardCap {
                self.segmentStart = now            // debounce until the new segment begins
                self.silenceStart = nil
                self.request?.endAudio()           // → isFinal → rollSegment() → commit + restart
            }
        }
    }

    func finish(_ completion: @escaping (String) -> Void) {
        q.async {
            self.running = false
            self.finishCompletion = completion
            if self.request != nil {
                self.request?.endAudio()           // wait for the final → deliverFinal()
                self.q.asyncAfter(deadline: .now() + 0.8) { self.deliverFinal() } // fallback
            } else {
                self.deliverFinal()
            }
        }
    }

    // On q. Delivers exactly once (guarded by finishCompletion).
    private func deliverFinal() {
        guard let completion = finishCompletion else { return }
        finishCompletion = nil
        let text = combinedText().trimmingCharacters(in: .whitespacesAndNewlines)
        task = nil
        request = nil
        accumulated = ""
        partial = ""
        DispatchQueue.main.async { completion(text) }
    }
}
