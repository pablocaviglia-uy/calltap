/// A Core Audio process object, as seen by the HAL.
public struct AudioProcessInfo: Equatable, Sendable {
    public let objectID: UInt32
    public let bundleID: String
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(objectID: UInt32, bundleID: String, isRunningInput: Bool, isRunningOutput: Bool) {
        self.objectID = objectID
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

/// A regular app the user sees in the Dock.
public struct RunningApp: Equatable, Sendable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// An app with every audio process it owns, helpers included (Chrome plays from
/// `com.google.Chrome.helper`, Teams from `com.microsoft.teams2.modulehost`).
public struct AudioAppGroup: Equatable, Hashable, Sendable {
    public let bundleID: String
    public let name: String
    public let processes: [UInt32]
}

public enum AudioApps {
    /// The app a process belongs to: the longest app bundle ID equal to the process's or a
    /// dotted prefix of it. System daemons own no app and return nil.
    public static func owner(of bundleID: String, among apps: [RunningApp]) -> RunningApp? {
        apps.filter { bundleID == $0.bundleID || bundleID.hasPrefix($0.bundleID + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }
    }

    /// Apps playing audio right now, sorted by name, without `excluded` bundle IDs.
    public static func playing(processes: [AudioProcessInfo], apps: [RunningApp], excluded: Set<String>) -> [AudioAppGroup] {
        var groups: [String: (app: RunningApp, processes: [UInt32], playing: Bool)] = [:]
        for process in processes {
            guard let app = owner(of: process.bundleID, among: apps), !excluded.contains(app.bundleID) else { continue }
            var entry = groups[app.bundleID] ?? (app, [], false)
            entry.processes.append(process.objectID)
            entry.playing = entry.playing || process.isRunningOutput
            groups[app.bundleID] = entry
        }
        return groups.values.filter(\.playing)
            .map { AudioAppGroup(bundleID: $0.app.bundleID, name: $0.app.name, processes: $0.processes) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Call apps CallTap watches. A call is in progress while one of the app's processes captures input.
public struct CallApp: Equatable, Hashable, Sendable {
    public let name: String
    public let bundlePrefixes: [String]

    public func owns(_ bundleID: String) -> Bool {
        bundlePrefixes.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") || bundleID.hasPrefix($0) }
    }

    public static let whatsApp = CallApp(name: "WhatsApp", bundlePrefixes: ["net.whatsapp.WhatsApp"])
    /// FaceTime's audio runs in `avconferenced`, which also carries iPhone calls answered on the Mac.
    public static let faceTime = CallApp(name: "FaceTime", bundlePrefixes: ["com.apple.FaceTime", "com.apple.avconferenced"])
    public static let zoom = CallApp(name: "Zoom", bundlePrefixes: ["us.zoom.xos"])
    public static let teams = CallApp(name: "Teams", bundlePrefixes: ["com.microsoft.teams2", "com.microsoft.teams"])

    public static let all: [CallApp] = [.whatsApp, .faceTime, .zoom, .teams]

    /// The first app with a process capturing input, and all of that app's process objects.
    public static func activeCall(in processes: [AudioProcessInfo]) -> (app: CallApp, processes: [UInt32])? {
        for app in all {
            let owned = processes.filter { app.owns($0.bundleID) }
            if owned.contains(where: \.isRunningInput) { return (app, owned.map(\.objectID)) }
        }
        return nil
    }
}
