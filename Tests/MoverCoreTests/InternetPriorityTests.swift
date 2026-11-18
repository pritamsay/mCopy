import XCTest
@testable import MoverCore

final class InternetPriorityTests: XCTestCase {
    let header = ",interface,bytes_in,bytes_out,"

    func testParserDropsInitialTotalsAndDoesNotDoubleCountProcessSummaries() throws {
        var parser = WiFiTrafficParser()
        _ = parser.consume(header)
        _ = parser.consume("tcp4 192.168.1.2:5000<->192.168.1.3:445,en0,999999,999999,")
        XCTAssertNil(parser.consume(header))
        _ = parser.consume("kernel_task.0,,999999,999999,")
        _ = parser.consume("tcp4 192.168.1.2:5000<->192.168.1.3:445,en0,1000,2000,")
        _ = parser.consume("tcp4 192.168.1.2:5001<->203.0.113.1:443,en0,4000,5000,")
        _ = parser.consume("udp4 192.168.1.2:5002<->203.0.113.2:443,en0,300,400,")
        let result = try XCTUnwrap(parser.consume(header))
        XCTAssertEqual(result.nasBytes, 3000)
        XCTAssertEqual(result.otherBytes, 9700)
        XCTAssertTrue(result.hasNASConnection)
    }

    func testParserSupportsReorderedColumnsIPv6AndMalformedRows() throws {
        var parser = WiFiTrafficParser()
        let reordered = ",bytes_out,interface,bytes_in,"
        _ = parser.consume(reordered)
        _ = parser.consume(reordered)
        _ = parser.consume("broken")
        _ = parser.consume("tcp6 [fe80::1]:5000<->[fe80::2]:445,25,en0,75,")
        _ = parser.consume("tcp6 [fe80::1]:5001<->[2001:db8::2]:443,40,en0,60,")
        let result = try XCTUnwrap(parser.consume(reordered))
        XCTAssertEqual(result.nasBytes, 100)
        XCTAssertEqual(result.otherBytes, 100)
    }

    func testFiniteSnapshotReturnsItsLastDeltaAtEndOfFile() throws {
        var parser = WiFiTrafficParser()
        _ = parser.consume(header)
        _ = parser.consume("tcp4 192.168.1.2:5000<->192.168.1.3:445,en0,999999,999999,")
        XCTAssertNil(parser.consume(header))
        _ = parser.consume("tcp4 192.168.1.2:5000<->192.168.1.3:445,en0,100,200,")
        XCTAssertEqual(try XCTUnwrap(parser.finish()).nasBytes, 300)
        XCTAssertNil(parser.finish())
        var cumulativeOnly = WiFiTrafficParser()
        _ = cumulativeOnly.consume(header)
        XCTAssertNil(cumulativeOnly.finish())
    }

    func testIdleIsUnrestrictedAndIncreasingInternetTrafficReducesNASBudget() {
        var policy = InternetPriority()
        let idle = policy.update(WiFiTraffic(nasBytes: 20_000_000, otherBytes: 0, hasNASConnection: true), seconds: 1, at: 0)
        XCTAssertEqual(idle.limitMB, 0)
        let light = policy.update(WiFiTraffic(nasBytes: 15_000_000, otherBytes: 1_000_000, hasNASConnection: true), seconds: 1, at: 1)
        let busy = policy.update(WiFiTraffic(nasBytes: 5_000_000, otherBytes: 8_000_000, hasNASConnection: true), seconds: 1, at: 2)
        XCTAssertTrue(light.internetActive)
        XCTAssertGreaterThan(light.limitMB, busy.limitMB)
        XCTAssertGreaterThan(busy.limitMB, 0)
        let quiet = policy.update(WiFiTraffic(nasBytes: 5_000_000, otherBytes: 0, hasNASConnection: true), seconds: 1, at: 6)
        XCTAssertEqual(quiet.limitMB, 0)
        XCTAssertFalse(quiet.internetActive)
    }

    func testBudgetLearnsObservedCapacityInsteadOfUsingAFixedSpeed() {
        var slow = InternetPriority()
        var fast = InternetPriority()
        _ = slow.update(WiFiTraffic(nasBytes: 5_000_000, otherBytes: 0, hasNASConnection: true), seconds: 1, at: 0)
        _ = fast.update(WiFiTraffic(nasBytes: 50_000_000, otherBytes: 0, hasNASConnection: true), seconds: 1, at: 0)
        let demand = WiFiTraffic(nasBytes: 0, otherBytes: 1_000_000, hasNASConnection: true)
        XCTAssertGreaterThan(fast.update(demand, seconds: 1, at: 1).limitMB, slow.update(demand, seconds: 1, at: 1).limitMB)
    }

    func testWiredOrLocalTransfersDoNotReceiveAWiFiBudget() {
        var policy = InternetPriority()
        let result = policy.update(WiFiTraffic(nasBytes: 0, otherBytes: 20_000_000, hasNASConnection: false), seconds: 1, at: 1)
        XCTAssertEqual(result.limitMB, 0)
    }

    func testInternetAlreadyActiveAtStartupDoesNotLockNASToBackgroundTrafficSpeed() {
        var policy = InternetPriority()
        let waiting = policy.update(WiFiTraffic(nasBytes: 0, otherBytes: 100_000, hasNASConnection: true), seconds: 1, at: 0)
        XCTAssertEqual(waiting.limitMB, 0)
        let first = policy.update(WiFiTraffic(nasBytes: 20_000_000, otherBytes: 100_000, hasNASConnection: true), seconds: 1, at: 1)
        XCTAssertEqual(first.limitMB, 0)
        let learned = policy.update(WiFiTraffic(nasBytes: 20_000_000, otherBytes: 100_000, hasNASConnection: true), seconds: 1, at: 2)
        XCTAssertGreaterThan(learned.limitMB, 10)
    }

    func testSmallBackgroundTrafficDoesNotKeepSlowingNAS() {
        var policy = InternetPriority()
        for time in 0..<8 {
            let result = policy.update(WiFiTraffic(nasBytes: 20_000_000, otherBytes: 20_000, hasNASConnection: true), seconds: 1, at: Double(time))
            XCTAssertEqual(result.limitMB, 0)
        }
    }

    func testNASMetadataAtStartupIsNotMistakenForBulkTransferCapacity() {
        var policy = InternetPriority()
        for time in 0..<4 {
            let result = policy.update(WiFiTraffic(nasBytes: 300, otherBytes: 100_000, hasNASConnection: true), seconds: 1, at: Double(time))
            XCTAssertEqual(result.limitMB, 0)
        }
        _ = policy.update(WiFiTraffic(nasBytes: 20_000_000, otherBytes: 100_000, hasNASConnection: true), seconds: 1, at: 4)
        let learned = policy.update(WiFiTraffic(nasBytes: 20_000_000, otherBytes: 100_000, hasNASConnection: true), seconds: 1, at: 5)
        XCTAssertGreaterThan(learned.limitMB, 10)
    }

    func testLowRateSpendsSmallAmountsContinuouslyInsteadOfWaitingForWholeChunk() {
        let budget = NetworkBandwidth()
        budget.setLimitMB(0.001, at: 0)
        XCTAssertLessThanOrEqual(budget.take(65_536, at: 0).wait, 0.05)
        XCTAssertEqual(budget.take(65_536, at: 0.05).bytes, 50)
        XCTAssertEqual(budget.take(65_536, at: 0.1).bytes, 50)
        XCTAssertEqual(budget.take(65_536, at: 0.15).bytes, 49, accuracy: 1)
    }

    func testCopyAndVerificationShareTheSameTokens() {
        let budget = NetworkBandwidth()
        budget.setLimitMB(1, at: 0)
        XCTAssertEqual(budget.take(65_536, at: 0).bytes, 0)
        XCTAssertEqual(budget.take(65_536, at: 0.07).bytes, 65_536)
        XCTAssertEqual(budget.take(65_536, at: 0.07).bytes, 0)
    }

    func testRateChangesPreserveEarnedTokensAndDisablingReleasesWaits() {
        let budget = NetworkBandwidth()
        budget.setLimitMB(1, at: 0)
        budget.setLimitMB(0.5, at: 0.03)
        XCTAssertEqual(budget.take(65_536, at: 0.102).bytes, 65_536)
        budget.setLimitMB(0, at: 0.103)
        XCTAssertEqual(budget.take(1_048_576, at: 0.103).bytes, 1_048_576)
    }

    func testBandwidthWaitIsCancelledPromptly() {
        let engine = TransferEngine(journal: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        engine.networkLimitMB = 0.0001
        let finished = expectation(description: "Network wait stopped")
        DispatchQueue.global().async {
            do {
                try engine.paceNetwork(bytes: 65_536, network: true)
                XCTFail("Expected cancellation while waiting for network bandwidth")
            } catch {
                guard case TransferError.stopped = error else {
                    XCTFail("Unexpected error: \(error)")
                    finished.fulfill()
                    return
                }
            }
            finished.fulfill()
        }
        engine.pause()
        wait(for: [finished], timeout: 1)
    }
}
