import XCTest
@testable import MoverCore

final class UninstallRecoveryTests: XCTestCase {
    let files = FileManager.default
    var root: URL!
    var support: URL!
    var source: URL!
    var destination: URL!
    var journal: URL!

    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent("mcopy-uninstall-" + UUID().uuidString)
        support = root.appendingPathComponent("Application Support")
        source = root.appendingPathComponent("original.bin")
        destination = root.appendingPathComponent("destination")
        journal = support.appendingPathComponent("mCopy/Requests/Jobs/" + UUID().uuidString + ".json")
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(repeating: 61, count: 2 * 1_048_576).write(to: source)
    }

    override func tearDownWithError() throws { try files.removeItem(at: root) }

    func testUninstallRemovesOwnedPartialButRetainsOriginal() throws {
        let engine = TransferEngine(journal: journal)
        engine.afterChunk = { throw TransferError.stopped }
        let job = try engine.prepare(sources: [source], destination: destination, move: true, limitMB: 0)
        XCTAssertThrowsError(try engine.run(job))
        XCTAssertFalse(try files.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).isEmpty)
        try UninstallRecovery.prepare(applicationSupport: support)
        XCTAssertTrue(files.fileExists(atPath: source.path))
        XCTAssertTrue(try files.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).isEmpty)
        XCTAssertFalse(files.fileExists(atPath: journal.path))
    }

    func testUninstallRestoresInterruptedReplacement() throws {
        let target = destination.appendingPathComponent(source.lastPathComponent)
        try Data("old destination".utf8).write(to: target)
        let engine = TransferEngine(journal: journal)
        engine.onConflict = { _, _ in Decision(.replace) }
        engine.exclusiveRename = { _, _ in errno = ENOTSUP; return -1 }
        engine.afterPublicationChunk = { throw TransferError.stopped }
        let job = try engine.prepare(sources: [source], destination: destination, move: true, limitMB: 0)
        XCTAssertThrowsError(try engine.run(job))
        try UninstallRecovery.prepare(applicationSupport: support)
        XCTAssertEqual(try Data(contentsOf: target), Data("old destination".utf8))
        XCTAssertTrue(files.fileExists(atPath: source.path))
        XCTAssertFalse(files.fileExists(atPath: journal.path))
    }

    func testUninstallRetainsUnknownLegacyRecoveryRecord() throws {
        let legacy = support.appendingPathComponent("Mover/transfer.json")
        try files.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = Data("unknown old transfer".utf8)
        try record.write(to: legacy)
        XCTAssertThrowsError(try UninstallRecovery.prepare(applicationSupport: support))
        XCTAssertEqual(try Data(contentsOf: legacy), record)
        XCTAssertTrue(files.fileExists(atPath: source.path))
    }
}
