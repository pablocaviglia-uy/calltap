import CoreAudio

/// Picks the microphone for "your side" without ever being the one that degrades a call.
///
/// Opening a Bluetooth headset's microphone forces it into the hands-free profile, which drops
/// audio quality in both directions. So: record the microphone the call app is already using;
/// otherwise the default input, unless it is a Bluetooth one nobody is using yet, in which case
/// the Mac's built-in microphone.
enum MicrophoneSelector {
    struct Device: Equatable {
        let id: AudioObjectID
        let name: String
        let isBluetooth: Bool
    }

    static func choose(preferringDevicesOf processes: [AudioObjectID]) -> Device? {
        if let inUse = AudioCatalog.inputDevices(of: processes).first.flatMap(describe) {
            return inUse
        }
        if let current = defaultInput() {
            if !current.isBluetooth || isRunningSomewhere(current.id) { return current }
        }
        return builtInMicrophone()
    }

    static func defaultInput() -> Device? {
        let id = (try? CoreAudioProperty.value(CoreAudioProperty.system, kAudioHardwarePropertyDefaultInputDevice,
                                              initial: AudioObjectID(kAudioObjectUnknown))) ?? kAudioObjectUnknown
        return describe(id)
    }

    static func describe(_ id: AudioObjectID) -> Device? {
        guard id != kAudioObjectUnknown else { return nil }
        let name = ((try? CoreAudioProperty.string(id, kAudioObjectPropertyName)) ?? nil) ?? "Microphone"
        let transport = try? CoreAudioProperty.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        return Device(id: id, name: name, isBluetooth: bluetooth)
    }

    static func isRunningSomewhere(_ id: AudioObjectID) -> Bool {
        (try? CoreAudioProperty.value(id, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0))) == 1
    }

    private static func builtInMicrophone() -> Device? {
        let devices = (try? CoreAudioProperty.objectList(CoreAudioProperty.system, kAudioHardwarePropertyDevices)) ?? []
        let builtIn = devices.first { id in
            let transport = try? CoreAudioProperty.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))
            let inputs = (try? CoreAudioProperty.objectList(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)) ?? []
            return transport == kAudioDeviceTransportTypeBuiltIn && !inputs.isEmpty
        }
        return builtIn.flatMap(describe)
    }
}
