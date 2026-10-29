import AudioToolbox
import CoreAudio

enum AudioDirection {
    case input
    case output

    var scope: AudioObjectPropertyScope {
        self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    var defaultDeviceSelector: AudioObjectPropertySelector {
        self == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    func symbol(for direction: AudioDirection) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeBuiltIn: return direction == .input ? "mic" : "laptopcomputer"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        default: return "waveform"
        }
    }
}

/// Listing, selecting and adjusting the system's audio devices — what Sound settings does.
enum AudioDevices {
    /// Devices that can be the default for `direction`, as Sound settings lists them.
    static func list(_ direction: AudioDirection) -> [AudioDevice] {
        let all = (try? CoreAudioProperty.objectList(CoreAudioProperty.system, kAudioHardwarePropertyDevices)) ?? []
        return all.compactMap { id in
            let streams = (try? CoreAudioProperty.objectList(id, kAudioDevicePropertyStreams, scope: direction.scope)) ?? []
            let eligible = (try? CoreAudioProperty.value(id, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                                        initial: UInt32(0), scope: direction.scope)) == 1
            guard !streams.isEmpty, eligible else { return nil }
            return describe(id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func describe(_ id: AudioObjectID) -> AudioDevice? {
        guard id != kAudioObjectUnknown else { return nil }
        let name = ((try? CoreAudioProperty.string(id, kAudioObjectPropertyName)) ?? nil) ?? "Audio device"
        let transport = (try? CoreAudioProperty.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
        return AudioDevice(id: id, name: name, transport: transport)
    }

    static func defaultDevice(_ direction: AudioDirection) -> AudioDevice? {
        let id = (try? CoreAudioProperty.value(CoreAudioProperty.system, direction.defaultDeviceSelector,
                                              initial: AudioObjectID(kAudioObjectUnknown))) ?? kAudioObjectUnknown
        return describe(id)
    }

    static func setDefault(_ id: AudioObjectID, for direction: AudioDirection) throws {
        var address = CoreAudioProperty.address(direction.defaultDeviceSelector)
        var value = id
        let status = AudioObjectSetPropertyData(CoreAudioProperty.system, &address, 0, nil,
                                                UInt32(MemoryLayout<AudioObjectID>.size), &value)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Switching the audio device") }
    }

    // MARK: Volume — the "virtual main volume", which also covers devices with per-channel controls only.

    private static func volumeAddress(_ direction: AudioDirection) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: direction.scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// 0…1, or nil when the device has no adjustable volume.
    static func volume(of id: AudioObjectID, _ direction: AudioDirection) -> Float? {
        var address = volumeAddress(direction)
        guard AudioHardwareServiceHasProperty(id, &address) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioHardwareServiceIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioHardwareServiceGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setVolume(of id: AudioObjectID, _ direction: AudioDirection, to volume: Float) {
        var address = volumeAddress(direction)
        var value = Float32(min(max(volume, 0), 1))
        AudioHardwareServiceSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    // MARK: Mute

    /// Whether the device is muted, or nil when it has no mute control.
    static func isMuted(_ id: AudioObjectID, _ direction: AudioDirection) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: direction.scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value == 1
    }

    static func setMuted(_ id: AudioObjectID, _ direction: AudioDirection, _ muted: Bool) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: direction.scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

/// Publishes the current devices and levels for the panel, refreshed every second while the app
/// runs so changes made elsewhere (Sound settings, keyboard volume keys) show up.
final class AudioDevicesController: ObservableObject {
    struct Side: Equatable {
        var devices: [AudioDevice] = []
        var selected: AudioDevice?
        var volume: Float?
        var muted: Bool?
    }

    @Published private(set) var output = Side()
    @Published private(set) var input = Side()
    @Published private(set) var error: String?
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func side(_ direction: AudioDirection) -> Side {
        direction == .input ? input : output
    }

    func refresh() {
        for direction in [AudioDirection.output, .input] {
            let selected = AudioDevices.defaultDevice(direction)
            let side = Side(devices: AudioDevices.list(direction),
                            selected: selected,
                            volume: selected.flatMap { AudioDevices.volume(of: $0.id, direction) },
                            muted: selected.flatMap { AudioDevices.isMuted($0.id, direction) })
            if direction == .input {
                if side != input { input = side }
            } else if side != output {
                output = side
            }
        }
    }

    func select(_ id: AudioObjectID, for direction: AudioDirection) {
        do {
            try AudioDevices.setDefault(id, for: direction)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func setVolume(_ volume: Float, for direction: AudioDirection) {
        guard let device = side(direction).selected else { return }
        AudioDevices.setVolume(of: device.id, direction, to: volume)
        if direction == .input { input.volume = volume } else { output.volume = volume }
    }

    func toggleMute(for direction: AudioDirection) {
        guard let device = side(direction).selected, let muted = side(direction).muted else { return }
        AudioDevices.setMuted(device.id, direction, !muted)
        refresh()
    }
}
