import Foundation

/// P5 stub: system-audio capture for meeting recording (ARCHITECTURE.md §4.2).
///
/// Planned implementation — Core Audio process taps (macOS 14.4+), following the
/// AudioCap reference (https://github.com/insidegui/AudioCap):
///  1. Build a `CATapDescription` (system-wide or per-process, e.g. mono mixdown
///     of all processes excluding our own).
///  2. `AudioHardwareCreateProcessTap(tapDescription, &tapID)` — first call
///     triggers the "record system audio" TCC prompt
///     (`NSAudioCaptureUsageDescription` in Resources/Info.plist).
///  3. Create an aggregate device that includes the tap's UUID
///     (`kAudioAggregateDeviceTapListKey`), then install an IO proc on it.
///  4. Convert callback buffers to 16 kHz mono and append to a CAF file on disk
///     (meetings are long; unlike dictation this must not accumulate in memory).
///
/// Meeting mode records this *and* `AudioRecorder` simultaneously as two tracks,
/// transcribes them separately, and interleaves segments by timestamp to get
/// "Me" / "Others" speaker labels without a diarization model.
///
/// Documented fallback if the tap API regresses in a future OS: ScreenCaptureKit
/// audio-only capture (costs the Screen Recording permission).
final class SystemAudioTap {
    enum TapError: Error { case unimplemented }

    func start() throws {
        throw TapError.unimplemented
    }

    func stop() -> URL? {
        nil // will return the recorded CAF file URL
    }
}
