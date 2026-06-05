import AVFoundation

/// Captures microphone audio and emits 16 kHz mono Float32 buffers, plus a
/// per-buffer RMS level used for pause detection.
///
/// The input node's hardware format is usually 44.1/48 kHz, so we install the
/// tap at that native format and down-convert with an AVAudioConverter.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func start(onAudio: @escaping (AVAudioPCMBuffer) -> Void,
               onLevel: @escaping (Float) -> Void) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "WhisperKey", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"])
        }
        self.converter = converter

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: self.targetFormat,
                                                   frameCapacity: capacity) else { return }

            var consumed = false
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, outBuffer.frameLength > 0 else { return }
            onLevel(self.rms(outBuffer))
            onAudio(outBuffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        converter = nil
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        return (sum / Float(count)).squareRoot()
    }
}
