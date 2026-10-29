import AVFoundation
import CallTapCore
import Speech

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case off
    case spanish
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .spanish: return "Spanish"
        case .english: return "English"
        }
    }

    /// The locale asked for; the transcriber maps it to the closest one it has a model for
    /// (Rioplatense Spanish lands on es-US).
    var requestedLocale: Locale? {
        switch self {
        case .off: return nil
        case .spanish: return Locale(identifier: "es-UY")
        case .english: return Locale(identifier: "en-US")
        }
    }

    static var isSupported: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }
}

/// On-device transcription with SpeechTranscriber: audio never leaves the Mac. The language model
/// downloads once, the first time a language is used.
@available(macOS 26, *)
enum Transcriber {
    enum TranscriberError: LocalizedError {
        case unsupportedLanguage
        var errorDescription: String? { "This Mac has no on-device speech model for that language" }
    }

    static func transcribe(_ tracks: [Recording.Track], language: TranscriptionLanguage) async throws -> [[TranscriptSegment]] {
        guard let requested = language.requestedLocale,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriberError.unsupportedLanguage
        }
        var result: [[TranscriptSegment]] = []
        for track in tracks {
            result.append(try await transcribe(track, locale: locale))
        }
        return result
    }

    private static func transcribe(_ track: Recording.Track, locale: Locale) async throws -> [TranscriptSegment] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await download.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: track.url)
        let collector = Task {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                segments.append(TranscriptSegment(speaker: track.speaker,
                                                  start: track.offset + result.range.start.seconds,
                                                  end: track.offset + result.range.end.seconds,
                                                  text: text))
            }
            return segments
        }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        let segments = try await collector.value
        _ = analyzer
        return segments
    }
}
