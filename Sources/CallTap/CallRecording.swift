import AVFoundation
import CallTapCore
import CoreAudio

/// One recording: the other side from WhatsApp's own audio, your side from the microphone,
/// each to a temporary file, mixed into a single .m4a when it finishes.
final class CallRecording {
    let startedAt = Date()
    let recordsMicrophone: Bool

    private let workDirectory: URL
    private let remote = ProcessTapRecorder()
    private let microphone = MicrophoneRecorder()
    private var remoteURL: URL { workDirectory.appendingPathComponent("remote.caf") }
    private var microphoneURL: URL { workDirectory.appendingPathComponent("microphone.caf") }

    init(processes: [AudioObjectID], recordMicrophone: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CallTap-\(UUID().uuidString)")
        workDirectory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try remote.start(processes: processes, writingTo: directory.appendingPathComponent("remote.caf"))
        var microphoneStarted = false
        if recordMicrophone {
            do {
                try microphone.start(writingTo: directory.appendingPathComponent("microphone.caf"))
                microphoneStarted = true
            } catch {
                microphoneStarted = false
            }
        }
        recordsMicrophone = microphoneStarted
    }

    /// Stops both sides and writes the mix to `destination`. If mixing fails, the raw tracks are
    /// moved next to it so nothing recorded is lost.
    func finish(to destination: URL) async throws {
        remote.stop()
        microphone.stop()

        let sources = [(remoteURL, remote.firstBufferAt), (microphoneURL, microphone.firstBufferAt)]
        let offsets = TrackAlignment.offsets(sources.map(\.1))
        do {
            try await Self.mix(zip(sources.map(\.0), offsets).compactMap { url, offset in offset.map { (url, $0) } },
                               to: destination)
            try? FileManager.default.removeItem(at: workDirectory)
        } catch {
            let base = destination.deletingPathExtension().lastPathComponent
            for (url, suffix) in [(remoteURL, "other side"), (microphoneURL, "microphone")]
            where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.moveItem(
                    at: url,
                    to: destination.deletingLastPathComponent().appendingPathComponent("\(base) (\(suffix)).caf"))
            }
            throw error
        }
    }

    private static func mix(_ tracks: [(URL, TimeInterval)], to destination: URL) async throws {
        let composition = AVMutableComposition()
        for (url, offset) in tracks {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            guard duration > .zero,
                  let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source,
                                      at: CMTime(seconds: offset, preferredTimescale: 48_000))
        }
        guard !composition.tracks.isEmpty else { throw CoreAudioError(status: -1, operation: "Recording (no audio was captured)") }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CoreAudioError(status: -1, operation: "Preparing the export")
        }
        if #available(macOS 15, *) {
            try await export.export(to: destination, as: .m4a)
        } else {
            export.outputURL = destination
            export.outputFileType = .m4a
            await export.export()
            if let error = export.error { throw error }
        }
    }
}
