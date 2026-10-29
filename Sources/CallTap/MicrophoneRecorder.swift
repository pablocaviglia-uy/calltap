import AVFoundation

/// Records the Mac's current default input — your side of the call.
final class MicrophoneRecorder {
    enum MicrophoneError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone available" }
    }

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var started: Date?

    var firstBufferAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(writingTo url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneError.noInput }
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if self.started == nil { self.started = Date() }
            try? self.file?.write(from: buffer)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        file = nil
        lock.unlock()
    }
}
