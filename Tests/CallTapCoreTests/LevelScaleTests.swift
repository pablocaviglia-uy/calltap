import XCTest
@testable import CallTapCore

final class LevelScaleTests: XCTestCase {
    func testFullScaleFillsTheBar() {
        XCTAssertEqual(LevelScale.position(peak: 1), 1)
        XCTAssertEqual(LevelScale.position(peak: 2), 1)  // clipped input stays at the top
    }

    func testSilenceAndTheFloorAreEmpty() {
        XCTAssertEqual(LevelScale.position(peak: 0), 0)
        XCTAssertEqual(LevelScale.position(peak: 0.001), 0, accuracy: 1e-5)  // -60 dBFS
    }

    func testScaleIsInDecibels() {
        XCTAssertEqual(LevelScale.position(peak: 0.1), 2.0 / 3.0, accuracy: 1e-5)  // -20 dBFS
        XCTAssertEqual(LevelScale.position(peak: 0.5), 1 - 6.0206 / 60, accuracy: 1e-4)  // -6 dBFS
    }

    func testBarRisesAtOnceAndFallsSlowly() {
        XCTAssertEqual(LevelScale.next(displayed: 0.2, incoming: 0.9), 0.9)
        XCTAssertEqual(LevelScale.next(displayed: 0.9, incoming: 0, fall: 0.04), 0.86, accuracy: 1e-6)
        XCTAssertEqual(LevelScale.next(displayed: 0.01, incoming: 0, fall: 0.04), 0)
    }
}
