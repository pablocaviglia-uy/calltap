import XCTest
@testable import CallTapCore

final class RecordingsTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testFileNameUsesDateAndFinderSafeTime() {
        let start = utc.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 9, minute: 5))!
        XCTAssertEqual(RecordingNaming.fileName(app: "WhatsApp", start: start, calendar: utc), "WhatsApp call 2026-10-29 09.05.m4a")
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

    func testTrackWithoutAudioStaysOutOfTheMix() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(TrackAlignment.offsets([t0, nil]), [0, nil])
        XCTAssertEqual(TrackAlignment.offsets([nil, nil]), [nil, nil])
    }
}
