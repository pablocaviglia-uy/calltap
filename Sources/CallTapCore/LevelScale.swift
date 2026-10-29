import Foundation

/// Meter scale and ballistics for the level bars.
public enum LevelScale {
    /// Bottom of the meter. Quieter than this reads as silence.
    public static let floorDB: Float = -60

    /// Position on the bar (0…1) for a linear peak amplitude, on a dB scale from `floorDB` to 0 dBFS.
    public static func position(peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(peak)
        return min(max((db - floorDB) / -floorDB, 0), 1)
    }

    /// The next displayed value: rises at once, falls by at most `fall` per tick, so short peaks
    /// stay visible.
    public static func next(displayed: Float, incoming: Float, fall: Float = 0.04) -> Float {
        max(incoming, displayed - fall)
    }
}
