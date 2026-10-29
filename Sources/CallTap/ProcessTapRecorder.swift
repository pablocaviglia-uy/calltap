import AVFoundation
import CoreAudio

/// Writes a process tap to a file.
final class ProcessTapRecorder {
    typealias Target = ProcessTap.Target

    private let tap = ProcessTap(label: "calltap.record-tap")
    private var file: AVAudioFile?
    /// Set on the first buffer; read only after `stop()`.
    private(set) var firstBufferAt: Date?

    func start(_ target: Target, writingTo url: URL) throws {
        try tap.start(target) { [weak self] buffer in
            guard let self else { return }
            if self.file == nil {
                self.file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                             commonFormat: buffer.format.commonFormat,
                                             interleaved: buffer.format.isInterleaved)
                self.firstBufferAt = Date()
            }
            try? self.file?.write(from: buffer)
        }
    }

    func stop() {
        tap.stop()
        file = nil
    }
}
