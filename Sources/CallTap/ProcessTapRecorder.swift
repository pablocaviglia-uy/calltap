import AVFoundation
import CoreAudio

/// Records what a set of processes play, through a private Core Audio process tap inside a
/// private aggregate device. Needs the "System Audio Recording" permission; without it the tap
/// delivers silence rather than an error.
final class ProcessTapRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "calltap.process-tap", qos: .userInitiated)
    /// Written on `queue`; read only after `stop()`.
    private(set) var firstBufferAt: Date?

    func start(processes: [AudioObjectID], writingTo url: URL) throws {
        do {
            try setUp(processes: processes, url: url)
        } catch {
            stop()
            throw error
        }
    }

    private func setUp(processes: [AudioObjectID], url: URL) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "CallTap"
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Creating the audio tap") }

        var streamFormat = try CoreAudioProperty.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &streamFormat) else {
            throw CoreAudioError(status: -1, operation: "Reading the tap format")
        }

        // The aggregate needs a clock; the current output device is the one WhatsApp plays to.
        let output = try CoreAudioProperty.value(AudioObjectID(kAudioObjectSystemObject),
                                                 kAudioHardwarePropertyDefaultOutputDevice,
                                                 initial: AudioObjectID(kAudioObjectUnknown))
        guard let outputUID = try CoreAudioProperty.string(output, kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(status: -1, operation: "Reading the output device")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                              kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Creating the capture device") }

        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        self.file = file
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self, let file = self.file,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            try? file.write(from: buffer)
        }
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Starting the capture") }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Starting the capture") }
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // Wait for any in-flight buffer, then close the file.
        queue.sync { file = nil }
    }
}
