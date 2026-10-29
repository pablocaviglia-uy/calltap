import AVFoundation
import CallTapCore
import CoreAudio

/// Writes your side to one file, following the microphone if it changes mid-recording.
///
/// Every device is converted to one fixed format, since a headset microphone runs at 16 kHz and
/// the Mac's at 48 kHz, and the moment of a switch is filled with silence so the track stays in
/// step with the other side.
final class MicrophoneRecorder {
    static let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                          channels: 1, interleaved: false)!

    private var capture: InputCapture?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var startedAt: Date?
    private var framesWritten: Int64 = 0
    /// Set when the microphone changes: the next buffer pads the whole gap, however short.
    /// Otherwise only gaps above the jitter tolerance are padded, so slow drift between the
    /// device clock and the wall clock never turns into clicks.
    private var switched = false
    private let lock = NSLock()
    private(set) var device: AudioObjectID?

    var firstBufferAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return startedAt
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Creates the file; capture starts with `use(_:)`.
    func prepare(writingTo url: URL) throws {
        let format = Self.fileFormat
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    /// Records from `device`, replacing the current one without starting a new file.
    func use(_ device: AudioObjectID) throws {
        guard device != self.device else { return }
        capture?.stop()
        capture = nil
        self.device = nil
        lock.lock()
        switched = startedAt != nil
        lock.unlock()
        let capture = InputCapture(label: "calltap.record-microphone")
        try capture.start(device: device) { [weak self] buffer in self?.append(buffer) }
        self.capture = capture
        self.device = device
    }

    func stop() {
        capture?.stop()
        capture = nil
        device = nil
        lock.lock()
        file = nil
        lock.unlock()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let file, let converted = convert(buffer) else { return }
        let now = Date()
        if startedAt == nil { startedAt = now }
        let rate = Self.fileFormat.sampleRate
        let silence = GapFill.silentFrames(elapsed: now.timeIntervalSince(startedAt!),
                                           bufferDuration: Double(buffer.frameLength) / buffer.format.sampleRate,
                                           written: framesWritten, sampleRate: rate,
                                           tolerance: switched ? 0 : 0.2)
        switched = false
        if silence > 0 { writeSilence(frames: silence, to: file) }
        do {
            try file.write(from: converted)
            framesWritten += Int64(converted.frameLength)
        } catch {
            return
        }
    }

    private func writeSilence(frames: Int64, to file: AVAudioFile) {
        let chunk = AVAudioFrameCount(Self.fileFormat.sampleRate / 2)
        guard let zeros = AVAudioPCMBuffer(pcmFormat: Self.fileFormat, frameCapacity: chunk) else { return }
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(Int64(chunk), remaining))
            zeros.frameLength = count
            memset(zeros.floatChannelData![0], 0, Int(count) * MemoryLayout<Float>.size)
            guard (try? file.write(from: zeros)) != nil else { return }
            framesWritten += Int64(count)
            remaining -= Int64(count)
        }
    }

    /// Converts to `fileFormat`; a new converter is made whenever the incoming format changes,
    /// which is what a microphone switch looks like from here.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = Self.fileFormat
        if buffer.format == target { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
