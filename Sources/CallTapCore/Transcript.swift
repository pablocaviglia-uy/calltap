import Foundation

/// A stretch of speech from one track, with times relative to the start of the recording.
public struct TranscriptSegment: Equatable, Sendable {
    public let speaker: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(speaker: String, start: TimeInterval, end: TimeInterval, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum Transcript {
    /// Interleaves the tracks by time and joins consecutive segments of the same speaker that are
    /// at most `joinGap` seconds apart, so a sentence split by the recognizer reads as one line.
    public static func merge(_ tracks: [[TranscriptSegment]], joinGap: TimeInterval = 1.5) -> [TranscriptSegment] {
        let sorted = tracks.flatMap { $0 }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        var merged: [TranscriptSegment] = []
        for segment in sorted {
            if var last = merged.last, last.speaker == segment.speaker, segment.start - last.end <= joinGap {
                last.text += " " + segment.text.trimmingCharacters(in: .whitespaces)
                last.end = max(last.end, segment.end)
                merged[merged.count - 1] = last
            } else {
                var copy = segment
                copy.text = segment.text.trimmingCharacters(in: .whitespaces)
                merged.append(copy)
            }
        }
        return merged
    }

    public static func render(_ segments: [TranscriptSegment], title: String) -> String {
        let lines = segments.map { "[\(timestamp($0.start))] \($0.speaker): \($0.text)" }
        return ([title, ""] + lines).joined(separator: "\n") + "\n"
    }

    /// "01:23", or "1:02:03" past the hour.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
