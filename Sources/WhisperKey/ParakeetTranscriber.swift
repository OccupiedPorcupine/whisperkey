import AVFoundation
import Foundation
import FluidAudio

/// Parakeet (NVIDIA Parakeet TDT 0.6B) backend via FluidAudio — fully on-device
/// CoreML inference on the Apple Neural Engine. No network calls once the model
/// is downloaded; nothing about the audio leaves the Mac.
///
/// Like WhisperKit this is a *batch* engine: it collects 16 kHz mono Float32
/// samples during the session (the format the Recorder already emits) and runs a
/// single transcription on `finish()`. No live partials. The model is downloaded
/// from Hugging Face on first use (~0.6 GB) and cached; the loaded manager is
/// reused across sessions.
final class ParakeetTranscriber: Transcriber {
    var onPartial: ((String) -> Void)?
    var onCommit: ((String) -> Void)?   // batch engine: no mid-session checkpoints

    var language = "en"

    private var samples = [Float]()
    private let q = DispatchQueue(label: "whisperkey.parakeet")

    /// Memoized, shared across sessions. Re-created only if the language family
    /// (English vs. multilingual) changes, since that picks a different model.
    private static var managerTask: Task<AsrManager, Error>?
    private static var managerEnglish: Bool?

    private var wantsEnglish: Bool { language.lowercased().hasPrefix("en") }

    private static func loadManager(english: Bool) -> Task<AsrManager, Error> {
        if let task = managerTask, managerEnglish == english { return task }
        let task = Task { () -> AsrManager in
            // v2 = English-only (better long-form recall); v3 = multilingual.
            let models = try await AsrModels.downloadAndLoad(version: english ? .v2 : .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            NSLog("WhisperKey: Parakeet ready — FluidAudio CoreML on the Neural Engine, %@ model, fully on-device.",
                  english ? "v2 (English)" : "v3 (multilingual)")
            return manager
        }
        managerTask = task
        managerEnglish = english
        return task
    }

    func start() throws {
        q.sync {
            samples.removeAll(keepingCapacity: true)
            samples.reserveCapacity(16_000 * 60)   // a minute up front — avoids mid-session reallocs
        }
        DispatchQueue.main.async { self.onPartial?("Listening… (Parakeet)") }
        // Warm up the model so it's ready by the time the user stops talking.
        let english = wantsEnglish
        Task { _ = try? await Self.loadManager(english: english).value }
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
        DispatchQueue.main.async { self.onPartial?("Transcribing… (Parakeet)") }

        let english = wantsEnglish
        Task {
            do {
                let manager = try await Self.loadManager(english: english).value
                var decoderState = try TdtDecoderState()
                let result = try await manager.transcribe(audio, decoderState: &decoderState)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let seconds = Double(audio.count) / 16_000.0
                NSLog("WhisperKey: Parakeet transcribed %.1fs of audio on-device → %d chars (confidence %.2f).",
                      seconds, text.count, Double(result.confidence))
                await MainActor.run { completion(text) }
            } catch {
                NSLog("WhisperKey: Parakeet transcribe failed — %@", String(describing: error))
                await MainActor.run { completion("") }
            }
        }
    }
}
