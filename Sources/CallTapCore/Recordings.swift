import Foundation

public enum RecordingNaming {
    /// "WhatsApp call 2026-10-29 12.31.m4a" — dots in the time because Finder shows colons as slashes.
    public static func fileName(title: String, start: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        let stamp = String(format: "%04d-%02d-%02d %02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        return "\(title) \(stamp).m4a"
    }

    /// `name` in `folder`, or "name 2", "name 3"… when taken. Never overwrites a recording.
    public static func uniqueURL(in folder: URL, fileName: String, exists: (URL) -> Bool) -> URL {
        let first = folder.appendingPathComponent(fileName)
        guard exists(first) else { return first }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}

/// Keeps a track on the wall clock when its source pauses — switching microphones mid-recording
/// leaves a gap that must become silence, or the voice drifts ahead of the other side.
public enum GapFill {
    /// Silent frames to write before a buffer that ends `elapsed` seconds after the track started
    /// and lasts `bufferDuration`, given `written` frames so far. Gaps shorter than `tolerance`
    /// are ordinary delivery jitter and are ignored.
    public static func silentFrames(elapsed: TimeInterval, bufferDuration: TimeInterval, written: Int64,
                                    sampleRate: Double, tolerance: TimeInterval = 0.2) -> Int64 {
        let expected = Int64(((elapsed - bufferDuration) * sampleRate).rounded())
        let missing = expected - written
        return Double(missing) > tolerance * sampleRate ? missing : 0
    }
}

public enum TrackAlignment {
    /// Where each track starts relative to the earliest one. Each side is captured by a separate
    /// device that starts a few milliseconds apart; a track that never received audio (nil)
    /// stays nil and is left out of the mix.
    public static func offsets(_ starts: [Date?]) -> [TimeInterval?] {
        guard let earliest = starts.compactMap({ $0 }).min() else { return starts.map { _ in nil } }
        return starts.map { $0.map { $0.timeIntervalSince(earliest) } }
    }
}
