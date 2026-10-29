import XCTest
@testable import CallTapCore

final class TranscriptTests: XCTestCase {
    func testTracksInterleaveByTime() {
        let me = [TranscriptSegment(speaker: "Me", start: 0.5, end: 2, text: "Hola, ¿cómo andás?"),
                  TranscriptSegment(speaker: "Me", start: 6, end: 7, text: "Buenísimo.")]
        let them = [TranscriptSegment(speaker: "Them", start: 2.4, end: 5, text: "Bien, ¿y vos?")]
        XCTAssertEqual(Transcript.merge([me, them]).map(\.speaker), ["Me", "Them", "Me"])
    }

    func testCloseSegmentsOfTheSameSpeakerJoin() {
        let me = [TranscriptSegment(speaker: "Me", start: 0, end: 2, text: "Te llamaba"),
                  TranscriptSegment(speaker: "Me", start: 2.8, end: 4, text: "por lo de mañana.")]
        let merged = Transcript.merge([me])
        XCTAssertEqual(merged, [TranscriptSegment(speaker: "Me", start: 0, end: 4, text: "Te llamaba por lo de mañana.")])
    }

    func testDistantSegmentsStaySeparateAndEmptyOnesDrop() {
        let me = [TranscriptSegment(speaker: "Me", start: 0, end: 1, text: "Uno."),
                  TranscriptSegment(speaker: "Me", start: 1.2, end: 1.3, text: "  "),
                  TranscriptSegment(speaker: "Me", start: 10, end: 11, text: "Dos.")]
        XCTAssertEqual(Transcript.merge([me]).map(\.text), ["Uno.", "Dos."])
    }

    func testRender() {
        let text = Transcript.render([TranscriptSegment(speaker: "Me", start: 83.9, end: 85, text: "Dale.")],
                                     title: "WhatsApp call 2026-10-29 12.31")
        XCTAssertEqual(text, "WhatsApp call 2026-10-29 12.31\n\n[01:23] Me: Dale.\n")
    }

    func testTimestampsPastTheHour() {
        XCTAssertEqual(Transcript.timestamp(3723), "1:02:03")
        XCTAssertEqual(Transcript.timestamp(0), "00:00")
    }
}
