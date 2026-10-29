import AVFoundation
import CallTapCore
import CoreAudio

/// What a recording captures.
enum RecordingSource: Equatable {
    case call(CallApp)
    case app(AudioAppGroup)
    case everything

    /// Used in the file name.
    var title: String {
        switch self {
        case .call(let app): return "\(app.name) call"
        case .app(let group): return group.name
        case .everything: return "Everything"
        }
    }

    /// Speaker label for the captured app audio in the transcript.
    var otherSideLabel: String {
        switch self {
        case .call: return "Them"
        case .app(let group): return group.name
        case .everything: return "Audio"
        }
    }
}

/// One recording: the app audio through a process tap and, optionally, a microphone, each to a
/// temporary track, mixed into a single .m4a when it finishes.
final class Recording {
    struct Track {
        let url: URL
        let offset: TimeInterval
        let speaker: String
    }

    let source: RecordingSource
    let startedAt = Date()
    /// Whether your voice is part of this recording.
    let recordsVoice: Bool
    /// The microphone currently recorded; it can change mid-recording.
    private(set) var microphone: MicrophoneSelector.Device?

    private let workDirectory: URL
    private let tap = ProcessTapRecorder()
    private let mic = MicrophoneRecorder()
    static let appTrackName = "app.caf"
    static let microphoneTrackName = "microphone.caf"
    private var tapURL: URL { workDirectory.appendingPathComponent(Self.appTrackName) }
    private var micURL: URL { workDirectory.appendingPathComponent(Self.microphoneTrackName) }

    init(source: RecordingSource, target: ProcessTapRecorder.Target, microphone: MicrophoneSelector.Device?,
         recordsVoice: Bool) throws {
        self.source = source
        self.recordsVoice = recordsVoice
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Recovery.workFolderPrefix)\(UUID().uuidString)")
        workDirectory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Lets the next launch rebuild this recording if the app dies before it finishes.
        let manifest = RecordingManifest(title: source.title, startedAt: startedAt, otherSideLabel: source.otherSideLabel)
        try manifest.encoded().write(to: directory.appendingPathComponent(RecordingManifest.fileName))
        try tap.start(target, writingTo: directory.appendingPathComponent(Self.appTrackName))
        if recordsVoice {
            try mic.prepare(writingTo: directory.appendingPathComponent(Self.microphoneTrackName))
            follow(microphone)
        }
    }

    /// Moves your side to `device` without starting a new file. A device that fails to open is
    /// retried on the next call.
    func follow(_ device: MicrophoneSelector.Device?) {
        guard recordsVoice, let device, device.id != microphone?.id else { return }
        do {
            try mic.use(device.id)
            microphone = device
        } catch {
            microphone = nil
        }
    }

    /// Stops capturing and writes the mix to `destination`. Returns the separate tracks, still on
    /// disk for transcription; call `discardTracks()` when done. If mixing fails, the raw tracks
    /// are moved next to `destination` so nothing recorded is lost.
    func finish(to destination: URL) async throws -> [Track] {
        tap.stop()
        mic.stop()

        let candidates = [(tapURL, tap.firstBufferAt, source.otherSideLabel), (micURL, mic.firstBufferAt, "Me")]
        let offsets = TrackAlignment.offsets(candidates.map(\.1))
        let tracks = zip(candidates, offsets).compactMap { candidate, offset in
            offset.map { Track(url: candidate.0, offset: $0, speaker: candidate.2) }
        }
        do {
            try await Self.mix(tracks, to: destination)
            return tracks
        } catch {
            let base = destination.deletingPathExtension().lastPathComponent
            for track in tracks {
                try? FileManager.default.moveItem(
                    at: track.url,
                    to: destination.deletingLastPathComponent().appendingPathComponent("\(base) (\(track.speaker)).caf"))
            }
            discardTracks()
            throw error
        }
    }

    func discardTracks() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// Mixes tracks into one .m4a. Also used to rebuild recordings cut short (`RecordingRecovery`).
    static func mix(_ tracks: [Track], to destination: URL) async throws {
        let composition = AVMutableComposition()
        for track in tracks {
            let asset = AVURLAsset(url: track.url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            guard duration > .zero,
                  let composed = composition.addMutableTrack(withMediaType: .audio,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try composed.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source,
                                         at: CMTime(seconds: track.offset, preferredTimescale: 48_000))
        }
        guard !composition.tracks.isEmpty else {
            throw CoreAudioError(status: -1, operation: "Recording (no audio was captured)")
        }
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
