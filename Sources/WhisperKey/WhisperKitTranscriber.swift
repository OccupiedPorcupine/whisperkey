import AVFoundation
import Foundation
import WhisperKit

/// WhisperKit (CoreML Whisper) backend — the accuracy upgrade.
///
/// Unlike Apple's streaming recognizer, WhisperKit transcribes a whole buffer at
/// once, so this collects 16 kHz mono samples during the session and runs one
/// transcription on `finish()`. The (large) CoreML model is downloaded from
/// Hugging Face on first use and cached; we kick that load off at `start()` so it
/// overlaps with the user speaking. The loaded pipeline is reused across
/// sessions.
///
/// Live partials aren't provided here (Whisper is batch); the bubble shows a
/// status string instead. VAD chunking handles arbitrarily long recordings.
final class WhisperKitTranscriber: Transcriber {
    var onPartial: ((String) -> Void)?

    var modelName = "large-v3-turbo"
    var language = "en"

    private var samples = [Float]()
    private let q = DispatchQueue(label: "whisperkey.whisperkit")

    /// Memoized, shared across sessions: first access triggers the model load,
    /// later accesses await the same task.
    private static var pipeTask: Task<WhisperKit, Error>?

    private static func loadPipe(model: String) -> Task<WhisperKit, Error> {
        if let task = pipeTask { return task }
        let task = Task { () -> WhisperKit in
            let config = WhisperKitConfig(model: model)
            return try await WhisperKit(config)
        }
        pipeTask = task
        return task
    }

    func start() throws {
        q.sync { samples.removeAll(keepingCapacity: true) }
        DispatchQueue.main.async { self.onPartial?("Listening… (Whisper)") }
        // Warm up the model so it's ready by the time the user stops talking.
        Task { _ = try? await Self.loadPipe(model: modelName).value }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
        q.async { self.samples.append(contentsOf: chunk) }
    }

    func noteLevel(_ rms: Float) { /* batch engine: pause detection not needed */ }

    func finish(_ completion: @escaping (String) -> Void) {
        let audio = q.sync { samples }
        guard !audio.isEmpty else {
            DispatchQueue.main.async { completion("") }
            return
        }
        DispatchQueue.main.async { self.onPartial?("Transcribing…") }

        let model = modelName
        let lang = String(language.split(separator: "-").first ?? "en")

        Task {
            do {
                let pipe = try await Self.loadPipe(model: model).value
                var options = DecodingOptions()
                options.language = lang
                options.chunkingStrategy = .vad   // handle long recordings
                let results = try await pipe.transcribe(audioArray: audio, decodeOptions: options)
                let text = results.map { $0.text }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run { completion(text) }
            } catch {
                NSLog("WhisperKey: WhisperKit transcribe failed — %@", String(describing: error))
                await MainActor.run { completion("") }
            }
        }
    }
}
