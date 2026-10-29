import AppKit
import CallTapCore
import CoreAudio

/// A snapshot of who is using audio: every Core Audio process object with its bundle ID and
/// whether it is capturing or playing, plus the regular apps they belong to.
struct AudioCatalog {
    let processes: [AudioProcessInfo]
    let apps: [RunningApp]

    static func current() -> AudioCatalog {
        let objects = (try? CoreAudioProperty.objectList(CoreAudioProperty.system, kAudioHardwarePropertyProcessObjectList)) ?? []
        let processes = objects.compactMap { object -> AudioProcessInfo? in
            guard let bundleID = (try? CoreAudioProperty.string(object, kAudioProcessPropertyBundleID)) ?? nil,
                  !bundleID.isEmpty else { return nil }
            let input = (try? CoreAudioProperty.value(object, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) == 1
            let output = (try? CoreAudioProperty.value(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) == 1
            return AudioProcessInfo(objectID: object, bundleID: bundleID, isRunningInput: input, isRunningOutput: output)
        }
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
            guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier else { return nil }
            return RunningApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
        return AudioCatalog(processes: processes, apps: apps)
    }

    var activeCall: (app: CallApp, processes: [AudioObjectID])? {
        CallApp.activeCall(in: processes)
    }

    var playingApps: [AudioAppGroup] {
        AudioApps.playing(processes: processes, apps: apps, excluded: [Bundle.main.bundleIdentifier ?? ""])
    }

    /// Input devices the given processes are capturing from right now.
    static func inputDevices(of processes: [AudioObjectID]) -> [AudioObjectID] {
        processes.flatMap { process in
            (try? CoreAudioProperty.objectList(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)) ?? []
        }
    }
}
