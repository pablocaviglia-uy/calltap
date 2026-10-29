import CallTapCore
import Foundation

/// Finds recordings cut short — the app crashed, was force-quit or replaced mid-recording — and
/// rebuilds each into a normal .m4a from the tracks it left behind.
enum RecordingRecovery {
    struct Abandoned {
        let folder: URL
        let manifest: RecordingManifest
        let tracks: [Recording.Track]
    }

    /// Work folders nobody has written to for a while. Run at launch: this process has not
    /// started a recording yet, and a live one elsewhere keeps writing, so it is never picked.
    static func abandoned(now: Date = Date()) -> [Abandoned] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        let entries = (try? fileManager.contentsOfDirectory(at: fileManager.temporaryDirectory,
                                                           includingPropertiesForKeys: keys)) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix(Recovery.workFolderPrefix) }.compactMap { folder in
            let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            let lastWrite = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max() ?? .distantPast
            guard Recovery.isAbandoned(lastWrite: lastWrite, now: now) else { return nil }

            let manifest = (try? Data(contentsOf: folder.appendingPathComponent(RecordingManifest.fileName)))
                .flatMap { try? RecordingManifest.decode($0) }
                ?? RecordingManifest.fallback(createdAt: (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now)
            // The two sides start within milliseconds of each other; their exact offsets were only
            // in memory, so the rebuild aligns both at zero.
            let tracks = [(Recording.appTrackName, manifest.otherSideLabel), (Recording.microphoneTrackName, "Me")]
                .compactMap { name, speaker -> Recording.Track? in
                    let url = folder.appendingPathComponent(name)
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return size > 4096 ? Recording.Track(url: url, offset: 0, speaker: speaker) : nil
                }
            return Abandoned(folder: folder, manifest: manifest, tracks: tracks)
        }
    }
}
