import AVFoundation

/// Speech-to-text backend. Both Apple Speech and (later) WhisperKit conform,
/// so the engine never cares which is live.
protocol Transcriber: AnyObject {
    /// Live, in-progress transcript (best guess so far). Called on the main queue.
    var onPartial: ((String) -> Void)? { get set }

    /// Begin a fresh transcription session.
    func start() throws

    /// Feed one chunk of 16 kHz mono Float32 audio.
    func append(_ buffer: AVAudioPCMBuffer)

    /// Report the current audio level (RMS, 0…1). Used for pause detection.
    func noteLevel(_ rms: Float)

    /// Stop, finalize, and deliver the complete transcript on the main queue.
    func finish(_ completion: @escaping (String) -> Void)
}
