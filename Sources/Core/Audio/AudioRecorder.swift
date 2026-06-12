import AVFoundation
import Foundation

/// Microphone capture (ARCHITECTURE.md §4.1): AVAudioEngine input tap, converted
/// on the fly to 16 kHz mono Float32 and accumulated in memory. Dictation
/// utterances are seconds to minutes, so no disk spill is needed (~3.8 MB/min).
final class AudioRecorder {
    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var levelContinuation: AsyncStream<Float>.Continuation?

    private(set) var isRecording = false

    /// RMS levels per buffer — drives the recording HUD level meter and doubles
    /// as the visual confirmation that the hotkey registered.
    private(set) lazy var levelStream: AsyncStream<Float> = AsyncStream { continuation in
        self.levelContinuation = continuation
    }

    func start() throws {
        guard !isRecording else { return }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.formatUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Copy of the samples captured so far without stopping — feeds the live
    /// transcript preview. `lastSeconds` bounds the copy so preview inference
    /// stays cheap on long utterances.
    func snapshot(lastSeconds: Double? = nil) -> TranscribableAudio {
        lock.lock()
        defer { lock.unlock() }
        guard let lastSeconds else { return samples }
        let maxCount = Int(lastSeconds * Self.targetSampleRate)
        return samples.count > maxCount ? Array(samples.suffix(maxCount)) : samples
    }

    /// Stops capture and returns the full utterance as 16 kHz mono PCM.
    func stop() -> TranscribableAudio {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        levelContinuation?.yield(0)

        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples.removeAll(keepingCapacity: false)
        return result
    }

    /// Runs on the audio thread: resample/downmix this buffer and append.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return
        }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData else { return }

        let frames = Int(out.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: frames))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
        levelContinuation?.yield(Self.rms(of: chunk))
    }

    /// Also used by the session's silence guard (ARCHITECTURE.md §3) to skip
    /// transcription of near-silent captures, where Whisper hallucinates.
    static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    enum RecorderError: Error { case formatUnavailable }
}
