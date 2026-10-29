import AVFoundation
import CoreAudio

/// Delivers what a set of processes play — or everything the Mac plays — through a private Core
/// Audio process tap inside a private aggregate device. Shared by the recorder and the level
/// meter. Needs the "System Audio Recording" permission; without it the tap delivers silence
/// rather than an error.
final class ProcessTap {
    enum Target {
        case processes([AudioObjectID])
        /// All system output except the given processes.
        case everything(excluding: [AudioObjectID])

        var tapDescription: CATapDescription {
            switch self {
            case .processes(let ids): return CATapDescription(stereoMixdownOfProcesses: ids)
            case .everything(let excluded): return CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// `handler` runs on a private serial queue, never after `stop()` returns.
    func start(_ target: Target, handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        do {
            try setUp(target, handler: handler)
        } catch {
            stop()
            throw error
        }
    }

    private func setUp(_ target: Target, handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let description = target.tapDescription
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "CallTap"
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Creating the audio tap") }

        var streamFormat = try CoreAudioProperty.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())

        // The aggregate needs a clock device, and the tap is delivered at that device's rate. A
        // Bluetooth headset is a bad clock: it drops from 44.1/48 kHz to 16 kHz as soon as any
        // app opens its microphone. The built-in output keeps a steady rate whatever the
        // headset does; the tap still captures the app's audio wherever it plays.
        guard let clock = Self.clockDevice(),
              let clockUID = try CoreAudioProperty.string(clock, kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(status: -1, operation: "Finding a clock device")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                              kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Creating the capture device") }

        // The tap format names the tap's channels; the rate is whatever the aggregate runs at.
        // Labelling buffers with the tap's own rate is what made recordings play 3× too fast
        // when the clock was a headset in hands-free mode.
        streamFormat.mSampleRate = try CoreAudioProperty.value(aggregateID, kAudioDevicePropertyNominalSampleRate,
                                                               initial: Float64(0))
        guard streamFormat.mSampleRate > 0, let format = AVAudioFormat(streamDescription: &streamFormat) else {
            throw CoreAudioError(status: -1, operation: "Reading the capture format")
        }
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            handler(buffer)
        }
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Starting the capture") }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Starting the capture") }
    }

    /// The built-in output when there is one, else the default output.
    private static func clockDevice() -> AudioObjectID? {
        let devices = (try? CoreAudioProperty.objectList(CoreAudioProperty.system, kAudioHardwarePropertyDevices)) ?? []
        let builtIn = devices.first { id in
            let transport = try? CoreAudioProperty.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))
            let outputs = (try? CoreAudioProperty.objectList(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)) ?? []
            return transport == kAudioDeviceTransportTypeBuiltIn && !outputs.isEmpty
        }
        if let builtIn { return builtIn }
        let fallback = try? CoreAudioProperty.value(CoreAudioProperty.system, kAudioHardwarePropertyDefaultOutputDevice,
                                                    initial: AudioObjectID(kAudioObjectUnknown))
        return fallback == kAudioObjectUnknown ? nil : fallback
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
        queue.sync {}  // let any in-flight buffer finish
    }
}

/// Delivers one input device's first stream straight from the HAL. Shared by the microphone
/// recorder and the level meter.
///
/// Not AVAudioEngine: its input node first binds to the system default input and only then
/// switches device, and when that default is a Bluetooth headset the brief open is enough to
/// drop the headset into the hands-free profile.
final class InputCapture {
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// `handler` runs on a private serial queue, never after `stop()` returns.
    func start(device: AudioObjectID, handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.device = device
        format = nil
        var status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, device, queue) { [weak self] _, input, _, _, _ in
            guard let self, let buffer = self.buffer(from: input) else { return }
            handler(buffer)
        }
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Opening the microphone") }
        status = AudioDeviceStart(device, ioProcID)
        guard status == noErr else {
            stop()
            throw CoreAudioError(status: status, operation: "Starting the microphone")
        }
    }

    /// The format is read on the first buffer: a Bluetooth input only settles its sample rate
    /// once it is running. Only the first stream is used; built-in and headset microphones have one.
    private func buffer(from input: UnsafePointer<AudioBufferList>) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first else { return nil }
        if format == nil {
            guard let stream = (try? CoreAudioProperty.objectList(device, kAudioDevicePropertyStreams,
                                                                   scope: kAudioObjectPropertyScopeInput))?.first,
                  var description = try? CoreAudioProperty.value(stream, kAudioStreamPropertyVirtualFormat,
                                                                 initial: AudioStreamBasicDescription()) else { return nil }
            format = AVAudioFormat(streamDescription: &description)
        }
        guard let format else { return nil }
        var single = AudioBufferList(mNumberBuffers: 1, mBuffers: first)
        // bufferListNoCopy only wraps the memory; copy so the buffer outlives this callback's list.
        guard let wrapped = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &single, deallocator: nil),
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wrapped.frameLength) else { return nil }
        copy.frameLength = wrapped.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: wrapped.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let src = from.mData, let dst = to.mData else { continue }
            memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(device, ioProcID)
            AudioDeviceDestroyIOProcID(device, ioProcID)
        }
        ioProcID = nil
        queue.sync {}  // let any in-flight buffer finish
    }
}
