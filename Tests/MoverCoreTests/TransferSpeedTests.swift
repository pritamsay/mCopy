import XCTest
@testable import MoverCore

final class TransferSpeedTests: XCTestCase {
    func testSpeedUsesWrittenBytesAndDropsToZeroAfterAStall() {
        var meter = TransferSpeed()
        XCTAssertEqual(meter.sample(bytes: 0, at: 0), 0)
        XCTAssertEqual(meter.sample(bytes: 1_000_000, at: 1), 1_000_000)
        XCTAssertEqual(meter.sample(bytes: 2_000_000, at: 2), 1_000_000)
        XCTAssertEqual(meter.sample(bytes: 2_000_000, at: 4), 0)
    }

    func testResetAvoidsCountingPausedTimeOrOldBytesOnResume() {
        var meter = TransferSpeed()
        _ = meter.sample(bytes: 0, at: 0)
        _ = meter.sample(bytes: 1_000_000, at: 1)
        meter.reset()
        XCTAssertEqual(meter.sample(bytes: 1_000_000, at: 100), 0)
        XCTAssertEqual(meter.sample(bytes: 2_000_000, at: 101), 1_000_000)
    }

    func testNewEngineCounterAndClockResetDoNotCreateNegativeSpeed() {
        var meter = TransferSpeed()
        _ = meter.sample(bytes: 5_000_000, at: 10)
        XCTAssertEqual(meter.sample(bytes: 0, at: 11), 0)
        XCTAssertEqual(meter.sample(bytes: 1_000_000, at: 12), 1_000_000)
        XCTAssertEqual(meter.sample(bytes: 2_000_000, at: 1), 0)
    }
}
