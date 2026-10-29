import CoreAudio
import Foundation

/// Watches WhatsApp's audio processes. A call is in progress while WhatsApp is capturing input;
/// that also covers recording a voice message, which is indistinguishable from outside.
final class CallMonitor {
    static let whatsAppBundleID = "net.whatsapp.WhatsApp"

    private(set) var isCallActive = false
    var onChange: ((Bool) -> Void)?
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    /// Core Audio process objects belonging to WhatsApp (main app and its helpers).
    static func whatsAppProcesses() -> [AudioObjectID] {
        let all = (try? CoreAudioProperty.objectList(AudioObjectID(kAudioObjectSystemObject),
                                                    kAudioHardwarePropertyProcessObjectList)) ?? []
        return all.filter { process in
            let bundleID = (try? CoreAudioProperty.string(process, kAudioProcessPropertyBundleID)) ?? nil
            return bundleID?.hasPrefix(whatsAppBundleID) == true
        }
    }

    private func poll() {
        let active = Self.whatsAppProcesses().contains { process in
            (try? CoreAudioProperty.value(process, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) == 1
        }
        guard active != isCallActive else { return }
        isCallActive = active
        onChange?(active)
    }
}
