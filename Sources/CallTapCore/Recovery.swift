import Foundation

/// Written next to a recording's temporary tracks when it starts, so a recording cut short by a
/// crash or a forced quit can be put back together on the next launch.
public struct RecordingManifest: Codable, Equatable, Sendable {
    public static let fileName = "recording.json"

    public let title: String
    public let startedAt: Date
    /// Transcript label for the app-audio track.
    public let otherSideLabel: String

    public init(title: String, startedAt: Date, otherSideLabel: String) {
        self.title = title
        self.startedAt = startedAt
        self.otherSideLabel = otherSideLabel
    }

    public var recoveredTitle: String { "\(title) (recovered)" }

    /// For work folders from before manifests existed: dated by the folder.
    public static func fallback(createdAt: Date) -> RecordingManifest {
        RecordingManifest(title: "Recording", startedAt: createdAt, otherSideLabel: "Audio")
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> RecordingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingManifest.self, from: data)
    }
}

public enum Recovery {
    /// Prefix of every recording's temporary work folder.
    public static let workFolderPrefix = "CallTap-"

    /// A work folder is abandoned once nothing has been written to it for `quietFor` seconds:
    /// a live recording appends to its tracks continuously.
    public static func isAbandoned(lastWrite: Date, now: Date, quietFor: TimeInterval = 30) -> Bool {
        now.timeIntervalSince(lastWrite) > quietFor
    }
}
