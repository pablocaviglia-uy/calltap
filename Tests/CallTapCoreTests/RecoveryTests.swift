import XCTest
@testable import CallTapCore

final class RecoveryTests: XCTestCase {
    func testManifestRoundTrips() throws {
        let manifest = RecordingManifest(title: "WhatsApp call", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                         otherSideLabel: "Them")
        XCTAssertEqual(try RecordingManifest.decode(manifest.encoded()), manifest)
    }

    func testRecoveredRecordingsAreLabelled() {
        let manifest = RecordingManifest(title: "Teams call", startedAt: Date(), otherSideLabel: "Them")
        XCTAssertEqual(manifest.recoveredTitle, "Teams call (recovered)")
        XCTAssertEqual(RecordingManifest.fallback(createdAt: Date()).recoveredTitle, "Recording (recovered)")
    }

    func testOnlyQuietFoldersCountAsAbandoned() {
        let now = Date()
        XCTAssertFalse(Recovery.isAbandoned(lastWrite: now.addingTimeInterval(-2), now: now))  // still recording
        XCTAssertTrue(Recovery.isAbandoned(lastWrite: now.addingTimeInterval(-60), now: now))
    }
}
