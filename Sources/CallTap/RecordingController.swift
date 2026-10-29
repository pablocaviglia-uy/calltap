import AppKit
import CallTapCore
import CoreAudio

/// Ties call detection, the notification prompt, the recorder and transcription together.
/// Main thread only.
final class RecordingController: ObservableObject {
    @Published private(set) var activeCall: CallApp?
    /// The microphone the call app is capturing from, which can differ from the Mac's input:
    /// Teams and Zoom keep their own device choice.
    @Published private(set) var callMicrophone: MicrophoneSelector.Device?
    @Published private(set) var playingApps: [AudioAppGroup] = []
    @Published private(set) var recording: Recording?
    /// "Saving recording…" / "Transcribing…" while a finished recording is processed.
    @Published private(set) var activity: String?
    @Published private(set) var lastSaved: URL?
    @Published private(set) var lastTranscript: URL?
    @Published private(set) var notice: String?

    /// For "everything" and single-app recordings; calls always include your voice.
    @Published var includeMicrophone: Bool {
        didSet { UserDefaults.standard.set(includeMicrophone, forKey: "includeMicrophone") }
    }
    @Published var transcription: TranscriptionLanguage {
        didSet { UserDefaults.standard.set(transcription.rawValue, forKey: "transcription") }
    }

    static var recordingsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallTap Recordings", isDirectory: true)
    }

    private let notifier = CallNotifier()
    private var activeCallProcesses: [AudioObjectID] = []
    /// Processes whose microphone a single-app recording follows.
    private var voiceSourceProcesses: [AudioObjectID] = []
    private var timer: Timer?

    init() {
        includeMicrophone = UserDefaults.standard.object(forKey: "includeMicrophone") as? Bool ?? true
        let stored = UserDefaults.standard.string(forKey: "transcription").flatMap(TranscriptionLanguage.init(rawValue:))
        transcription = stored ?? (TranscriptionLanguage.isSupported ? .spanish : .off)
        notifier.onRecord = { [weak self] in self?.recordCall() }
        notifier.setUp()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        recoverAbandonedRecordings()
    }

    // MARK: Recovery

    /// Rebuilds recordings a previous run never finished, before this run starts one of its own.
    private func recoverAbandonedRecordings() {
        let abandoned = RecordingRecovery.abandoned()
        guard !abandoned.isEmpty else { return }
        let language = transcription
        Task { @MainActor in
            for item in abandoned {
                guard !item.tracks.isEmpty else {
                    try? FileManager.default.removeItem(at: item.folder)
                    continue
                }
                activity = "Recovering an interrupted recording…"
                do {
                    let url = try nextRecordingURL(title: item.manifest.recoveredTitle, start: item.manifest.startedAt)
                    try await Recording.mix(item.tracks, to: url)
                    lastSaved = url
                    notifier.fileReady(title: "Recovered an interrupted recording", url: url)
                    if language != .off, #available(macOS 26, *) {
                        activity = "Transcribing…"
                        await transcribe(item.tracks, language: language, recordingURL: url)
                    }
                    try? FileManager.default.removeItem(at: item.folder)
                } catch {
                    // The tracks stay where they are for the next attempt.
                    notice = "Could not recover an interrupted recording: \(error.localizedDescription)"
                }
            }
            activity = nil
        }
    }

    private func nextRecordingURL(title: String, start: Date) throws -> URL {
        let folder = Self.recordingsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = RecordingNaming.fileName(title: title, start: start)
        return RecordingNaming.uniqueURL(in: folder, fileName: name) { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Polling

    private func poll() {
        let catalog = AudioCatalog.current()
        let call = catalog.activeCall
        activeCallProcesses = call?.processes ?? []
        if call?.app != activeCall { callChanged(to: call?.app) }
        let microphone = AudioCatalog.inputDevices(of: activeCallProcesses).first.flatMap(MicrophoneSelector.describe)
        if microphone != callMicrophone { callMicrophone = microphone }
        let apps = catalog.playingApps
        if apps != playingApps { playingApps = apps }
        followMicrophone()
    }

    /// Re-applies the microphone rule every poll, so a recording follows the call app (or the
    /// user) to another microphone, or recovers when its microphone disappears.
    private func followMicrophone() {
        guard let recording, recording.recordsVoice else { return }
        let processes: [AudioObjectID]
        if case .call = recording.source { processes = activeCallProcesses } else { processes = voiceSourceProcesses }
        let wanted = MicrophoneSelector.choose(preferringDevicesOf: processes)
        guard wanted?.id != recording.microphone?.id else { return }
        objectWillChange.send()
        recording.follow(wanted)
    }

    private func callChanged(to call: CallApp?) {
        activeCall = call
        if let call {
            if recording == nil { notifier.callStarted(appName: call.name) }
        } else {
            notifier.clearCallPrompt()
        }
        // The call a recording belongs to has ended.
        if let recording, case .call(let app) = recording.source, app != call { stop() }
    }

    // MARK: Starting

    func recordCall() {
        guard let call = activeCall else {
            notice = "No call in progress"
            return
        }
        start(.call(call), target: .processes(activeCallProcesses),
              microphoneFrom: activeCallProcesses, wantsMicrophone: true)
    }

    func recordEverything() {
        let own = CoreAudioProperty.processObject(for: getpid()).map { [$0] } ?? []
        start(.everything, target: .everything(excluding: own), microphoneFrom: [], wantsMicrophone: includeMicrophone)
    }

    func record(_ app: AudioAppGroup) {
        start(.app(app), target: .processes(app.processes), microphoneFrom: app.processes, wantsMicrophone: includeMicrophone)
    }

    private func start(_ source: RecordingSource, target: ProcessTapRecorder.Target,
                       microphoneFrom processes: [AudioObjectID], wantsMicrophone: Bool) {
        guard recording == nil, activity == nil else { return }
        notifier.clearCallPrompt()
        notice = nil
        Task { @MainActor in
            var recordsVoice = false
            if wantsMicrophone {
                recordsVoice = await MicrophoneRecorder.requestAccess()
                if !recordsVoice { notice = "Microphone access denied: recording without your voice" }
            }
            do {
                voiceSourceProcesses = processes
                let recording = try Recording(source: source, target: target,
                                              microphone: recordsVoice ? MicrophoneSelector.choose(preferringDevicesOf: processes) : nil,
                                              recordsVoice: recordsVoice)
                self.recording = recording
                if recordsVoice, recording.microphone == nil {
                    notice = "No microphone yet: your voice starts when one is available"
                }
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    // MARK: Finishing

    func stop() {
        guard let recording else { return }
        self.recording = nil
        activity = "Saving recording…"
        let language = transcription
        Task { @MainActor in
            do {
                let url = try nextRecordingURL(title: recording.source.title, start: recording.startedAt)
                let tracks = try await recording.finish(to: url)
                lastSaved = url
                notifier.fileReady(title: "Recording saved", url: url)
                if language != .off, #available(macOS 26, *) {
                    activity = "Transcribing…"
                    await transcribe(tracks, language: language, recordingURL: url)
                }
                recording.discardTracks()
            } catch {
                notice = error.localizedDescription
                notifier.failed("Recording failed", error.localizedDescription)
            }
            activity = nil
        }
    }

    @available(macOS 26, *)
    @MainActor
    private func transcribe(_ tracks: [Recording.Track], language: TranscriptionLanguage, recordingURL: URL) async {
        do {
            let segments = try await Transcriber.transcribe(tracks, language: language)
            let title = recordingURL.deletingPathExtension().lastPathComponent
            let text = Transcript.render(Transcript.merge(segments), title: title)
            let url = recordingURL.deletingPathExtension().appendingPathExtension("txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastTranscript = url
            notifier.fileReady(title: "Transcript ready", url: url)
        } catch {
            notice = "Transcription failed: \(error.localizedDescription)"
            notifier.failed("Transcription failed", error.localizedDescription)
        }
    }

    // MARK: Files

    func showLastRecording() {
        guard let lastSaved else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastSaved])
    }

    func openLastTranscript() {
        guard let lastTranscript else { return }
        NSWorkspace.shared.open(lastTranscript)
    }

    func openRecordingsFolder() {
        let folder = Self.recordingsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
