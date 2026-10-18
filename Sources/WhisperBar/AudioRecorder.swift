import AVFoundation

enum RecorderError: LocalizedError {
    case couldNotStart
    var errorDescription: String? { "Couldn’t start recording." }
}

/// Records 16 kHz mono 16-bit WAV, the format whisper wants, and reports input level.
@MainActor
final class AudioRecorder {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("whisperbar.wav")
    var onTick: (@MainActor (_ level: CGFloat, _ elapsed: TimeInterval) -> Void)?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt = Date()

    var isRecording: Bool { recorder?.isRecording == true }

    func start() throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let r = try AVAudioRecorder(url: fileURL, settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw RecorderError.couldNotStart }
        recorder = r
        startedAt = Date()

        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stops and keeps the file. Returns the recorded length in seconds.
    @discardableResult
    func stop() -> TimeInterval {
        timer?.invalidate(); timer = nil
        let elapsed = Date().timeIntervalSince(startedAt)
        recorder?.stop(); recorder = nil
        return elapsed
    }

    /// Stops and throws the audio away.
    func cancel() {
        stop()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func tick() {
        guard let r = recorder, r.isRecording else { return }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)                 // roughly -160 … 0 dB
        onTick?(CGFloat(max(0, (db + 50) / 50)), Date().timeIntervalSince(startedAt))
    }
}
