import XCTest
@testable import CallTapCore

final class RecordingsTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testFileNameUsesTitleDateAndFinderSafeTime() {
        let start = utc.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 9, minute: 5))!
        XCTAssertEqual(RecordingNaming.fileName(title: "WhatsApp call", start: start, calendar: utc),
                       "WhatsApp call 2026-10-29 09.05.m4a")
    }

    func testUniqueURLNeverReusesAName() {
        let folder = URL(fileURLWithPath: "/tmp/rec")
        let taken: Set<String> = ["WhatsApp call 2026-10-29 09.05.m4a", "WhatsApp call 2026-10-29 09.05 2.m4a"]
        let url = RecordingNaming.uniqueURL(in: folder, fileName: "WhatsApp call 2026-10-29 09.05.m4a") {
            taken.contains($0.lastPathComponent)
        }
        XCTAssertEqual(url.lastPathComponent, "WhatsApp call 2026-10-29 09.05 3.m4a")
    }

    func testUniqueURLKeepsTheNameWhenFree() {
        let url = RecordingNaming.uniqueURL(in: URL(fileURLWithPath: "/tmp/rec"), fileName: "a.m4a") { _ in false }
        XCTAssertEqual(url.lastPathComponent, "a.m4a")
    }

    func testOffsetsAreRelativeToTheEarliestTrack() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let offsets = TrackAlignment.offsets([t0.addingTimeInterval(0.04), t0])
        XCTAssertEqual(offsets[0]!, 0.04, accuracy: 1e-6)
        XCTAssertEqual(offsets[1], 0)
    }

    func testNoGapWhileBuffersArriveOnTime() {
        // 2 s in, a 10 ms buffer arrives and 1.99 s worth has been written.
        XCTAssertEqual(GapFill.silentFrames(elapsed: 2.0, bufferDuration: 0.01, written: 95_520, sampleRate: 48_000), 0)
        // The first buffer of a track never needs padding.
        XCTAssertEqual(GapFill.silentFrames(elapsed: 0, bufferDuration: 0.01, written: 0, sampleRate: 48_000), 0)
    }

    func testJitterBelowToleranceIsIgnored() {
        XCTAssertEqual(GapFill.silentFrames(elapsed: 2.0, bufferDuration: 0.01, written: 95_520 - 4_800, sampleRate: 48_000), 0)
    }

    func testAtASwitchEvenAShortGapIsPadded() {
        // 0.1 s missing: below the jitter tolerance, but a microphone switch pads it exactly.
        XCTAssertEqual(GapFill.silentFrames(elapsed: 1.11, bufferDuration: 0.01, written: 48_000, sampleRate: 48_000), 0)
        XCTAssertEqual(GapFill.silentFrames(elapsed: 1.11, bufferDuration: 0.01, written: 48_000, sampleRate: 48_000,
                                            tolerance: 0), 4_800)
    }

    func testSwitchingMicrophonesBecomesSilence() {
        // 1 s written, then the new microphone's first buffer ends 1.6 s in: 0.59 s are missing.
        XCTAssertEqual(GapFill.silentFrames(elapsed: 1.6, bufferDuration: 0.01, written: 48_000, sampleRate: 48_000), 28_320)
    }

    func testTrackWithoutAudioStaysOutOfTheMix() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(TrackAlignment.offsets([t0, nil]), [0, nil])
        XCTAssertEqual(TrackAlignment.offsets([nil, nil]), [nil, nil])
    }
}
