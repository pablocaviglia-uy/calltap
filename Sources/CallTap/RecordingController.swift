import AppKit
import CallTapCore
import CoreAudio

/// Ties call detection, the notification prompt and the recorder together. Main thread only.
final class RecordingController: ObservableObject {
    @Published private(set) var callActive = false
    @Published private(set) var recording: CallRecording?
    @Published private(set) var isSaving = false
    @Published private(set) var lastSaved: URL?
    @Published private(set) var notice: String?
    @Published private(set) var inputDeviceName: String?
    /// A Bluetooth microphone forces the headset into hands-free mode, which degrades both
    /// directions of the call; the menu suggests the Mac's microphone instead.
    @Published private(set) var inputIsBluetooth = false

    static var recordingsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallTap Recordings", isDirectory: true)
    }

    private let monitor = CallMonitor()
    private let notifier = CallNotifier()
    private var inputTimer: Timer?

    init() {
        notifier.onRecord = { [weak self] in self?.startRecording() }
        notifier.setUp()
        monitor.onChange = { [weak self] active in self?.callChanged(active) }
        monitor.start()
        refreshInputDevice()
        inputTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshInputDevice() }
    }

    private func callChanged(_ active: Bool) {
        callActive = active
        if active {
            if recording == nil { notifier.callStarted() }
        } else {
            notifier.clearCallPrompt()
            if recording != nil { stopRecording() }
        }
    }

    func startRecording() {
        guard recording == nil, !isSaving else { return }
        let processes = CallMonitor.whatsAppProcesses()
        guard !processes.isEmpty else {
            notice = "WhatsApp is not using audio right now"
            return
        }
        notifier.clearCallPrompt()
        Task { @MainActor in
            let microphoneAllowed = await MicrophoneRecorder.requestAccess()
            do {
                let recording = try CallRecording(processes: processes, recordMicrophone: microphoneAllowed)
                self.recording = recording
                self.notice = recording.recordsMicrophone ? nil : "Microphone unavailable: recording only the other side"
            } catch {
                self.notice = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        guard let recording else { return }
        self.recording = nil
        isSaving = true
        Task { @MainActor in
            do {
                let folder = Self.recordingsFolder
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = RecordingNaming.fileName(app: "WhatsApp", start: recording.startedAt)
                let url = RecordingNaming.uniqueURL(in: folder, fileName: name) {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                try await recording.finish(to: url)
                lastSaved = url
                notifier.saved(url)
            } catch {
                notice = error.localizedDescription
                notifier.failed(error.localizedDescription)
            }
            isSaving = false
        }
    }

    func showLastRecording() {
        guard let lastSaved else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastSaved])
    }

    func openRecordingsFolder() {
        let folder = Self.recordingsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func refreshInputDevice() {
        let device = try? CoreAudioProperty.value(AudioObjectID(kAudioObjectSystemObject),
                                                  kAudioHardwarePropertyDefaultInputDevice,
                                                  initial: AudioObjectID(kAudioObjectUnknown))
        let name = device.flatMap { try? CoreAudioProperty.string($0, kAudioObjectPropertyName) } ?? nil
        if name != inputDeviceName { inputDeviceName = name }
        let transport = device.flatMap { try? CoreAudioProperty.value($0, kAudioDevicePropertyTransportType, initial: UInt32(0)) }
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        if bluetooth != inputIsBluetooth { inputIsBluetooth = bluetooth }
    }
}
