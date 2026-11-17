import XCTest
import Darwin
@testable import MoverCore

final class TransferEngineTests: XCTestCase {
    var root: URL!
    var source: URL!
    var destination: URL!
    var journal: URL!
    let files = FileManager.default

    override func setUpWithError() throws {
        root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("mycopy-tests-" + UUID().uuidString)
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("destination")
        journal = root.appendingPathComponent("state/transfer.json")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try files.removeItem(at: root) }

    func write(_ name: String = "sample.txt", text: String = "hello") throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func prepare(_ engine: TransferEngine, _ urls: [URL], move: Bool = false) throws -> Job {
        try engine.prepare(sources: urls, destination: destination, move: move, limitMB: 100_000)
    }

    func target(_ name: String = "sample.txt") -> URL { destination.appendingPathComponent(name) }

    func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func hiddenFiles() throws -> [URL] {
        try files.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".mover-") }
    }

    func largeFile() throws -> URL {
        let url = source.appendingPathComponent("large.bin")
        var data = Data(repeating: 13, count: 1_048_576)
        data.append(Data(repeating: 27, count: 1_048_576))
        data.append(Data(repeating: 42, count: 1_048_576))
        try data.write(to: url)
        return url
    }

    func testCopyKeepsSourceAndCopiesNestedAndEmptyFolders() throws {
        let folder = source.appendingPathComponent("folder")
        try files.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: folder.appendingPathComponent("file.txt"))
        let engine = TransferEngine(journal: journal)
        try engine.run(prepare(engine, [folder]))
        XCTAssertEqual(try contents(target("folder/file.txt")), "nested")
        XCTAssertTrue(files.fileExists(atPath: target("folder/empty").path))
        XCTAssertTrue(files.fileExists(atPath: folder.appendingPathComponent("file.txt").path))
        XCTAssertFalse(files.fileExists(atPath: journal.path))
        XCTAssertTrue(try hiddenFiles().isEmpty)
    }

    func testMoveRemovesSourceOnlyAfterVerifiedPublication() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        engine.afterPublication = {
            XCTAssertTrue(self.files.fileExists(atPath: original.path))
            XCTAssertEqual(try self.contents(self.target()), "hello")
        }
        try engine.run(prepare(engine, [original], move: true))
        XCTAssertFalse(files.fileExists(atPath: original.path))
        XCTAssertEqual(try contents(target()), "hello")
    }

    func testPauseAndResumeVerifiesAndContinuesPartialFile() throws {
        let original = try largeFile()
        let first = TransferEngine(journal: journal)
        first.afterChunk = { throw TransferError.stopped }
        XCTAssertThrowsError(try first.run(prepare(first, [original], move: true)))
        XCTAssertEqual(try hiddenFiles().count, 1)
        XCTAssertTrue(files.fileExists(atPath: original.path))
        XCTAssertFalse(files.fileExists(atPath: target("large.bin").path))
        let expected = try Data(contentsOf: original)
        let second = TransferEngine(journal: journal)
        var written: Int64 = 0
        second.onProgress = { if $0.fraction == 1 { written = $0.writtenBytes } }
        try second.run(second.load())
        XCTAssertEqual(try Data(contentsOf: target("large.bin")), expected)
        XCTAssertFalse(files.fileExists(atPath: original.path))
        XCTAssertTrue(try hiddenFiles().isEmpty)
        XCTAssertEqual(written, 2 * 1_048_576, "Checking the saved prefix must not count as new writes.")
    }

    func testChangedPartialIsRejectedAndOriginalRetained() throws {
        let original = try largeFile()
        let engine = TransferEngine(journal: journal)
        engine.afterChunk = { throw TransferError.stopped }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        let partial = try XCTUnwrap(hiddenFiles().first)
        let handle = try FileHandle(forUpdating: partial)
        try handle.write(contentsOf: Data([99]))
        try handle.close()
        let resumed = TransferEngine(journal: journal)
        XCTAssertThrowsError(try resumed.run(resumed.load()))
        XCTAssertTrue(files.fileExists(atPath: original.path))
        XCTAssertTrue(files.fileExists(atPath: partial.path))
    }

    func testCancelRemovesOnlyIncompleteCopy() throws {
        let original = try largeFile()
        let unrelated = target("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)
        let engine = TransferEngine(journal: journal)
        engine.afterChunk = { throw TransferError.stopped }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        try TransferEngine(journal: journal).cancelSavedTransfer()
        XCTAssertTrue(files.fileExists(atPath: original.path))
        XCTAssertEqual(try contents(unrelated), "keep")
        XCTAssertTrue(try hiddenFiles().isEmpty)
        XCTAssertFalse(files.fileExists(atPath: journal.path))
    }

    func testReplacePublishesVerifiedFileAndRemovesBackup() throws {
        let original = try write(text: "new")
        try Data("old".utf8).write(to: target())
        let engine = TransferEngine(journal: journal)
        engine.onConflict = { _, _ in Decision(.replace) }
        try engine.run(prepare(engine, [original]))
        XCTAssertEqual(try contents(target()), "new")
        XCTAssertEqual(try contents(original), "new")
        XCTAssertTrue(try hiddenFiles().isEmpty)
    }

    func testSkipKeepsOriginalDuringMove() throws {
        let original = try write(text: "new")
        try Data("old".utf8).write(to: target())
        let engine = TransferEngine(journal: journal)
        engine.onConflict = { _, _ in Decision(.skip) }
        try engine.run(prepare(engine, [original], move: true))
        XCTAssertEqual(try contents(target()), "old")
        XCTAssertEqual(try contents(original), "new")
    }

    func testRenameKeepsBothFiles() throws {
        let original = try write(text: "new")
        try Data("old".utf8).write(to: target())
        let engine = TransferEngine(journal: journal)
        engine.onConflict = { _, _ in Decision(.rename) }
        try engine.run(prepare(engine, [original]))
        XCTAssertEqual(try contents(target()), "old")
        XCTAssertEqual(try contents(target("sample 2.txt")), "new")
    }

    func testFolderRenameUpdatesDescendantDestinations() throws {
        let folder = source.appendingPathComponent("folder")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: folder.appendingPathComponent("file.txt"))
        try files.createDirectory(at: target("folder"), withIntermediateDirectories: true)
        let engine = TransferEngine(journal: journal)
        engine.onConflict = { _, _ in Decision(.rename) }
        try engine.run(prepare(engine, [folder]))
        XCTAssertEqual(try contents(target("folder 2/file.txt")), "new")
        XCTAssertFalse(files.fileExists(atPath: target("folder/file.txt").path))
    }

    func testMergeRetainsUnrelatedDestinationFiles() throws {
        let folder = source.appendingPathComponent("folder")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: folder.appendingPathComponent("file.txt"))
        try files.createDirectory(at: target("folder"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target("folder/unrelated.txt"))
        let engine = TransferEngine(journal: journal)
        engine.onConflict = { _, _ in Decision(.replace, all: true) }
        try engine.run(prepare(engine, [folder], move: true))
        XCTAssertEqual(try contents(target("folder/unrelated.txt")), "keep")
        XCTAssertEqual(try contents(target("folder/file.txt")), "new")
        XCTAssertFalse(files.fileExists(atPath: folder.path))
    }

    func testSourceMutationBeforeDeletionRetainsChangedOriginal() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        engine.afterPublication = { try Data("changed source".utf8).write(to: original) }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        XCTAssertEqual(try contents(original), "changed source")
        XCTAssertEqual(try contents(target()), "hello")
    }

    func testDestinationMutationBeforeDeletionRetainsOriginal() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        engine.afterPublication = { try Data("changed destination".utf8).write(to: self.target()) }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        XCTAssertEqual(try contents(original), "hello")
        XCTAssertEqual(try contents(target()), "changed destination")
    }

    func testCrashAfterPublicationRecoversWithoutCopyingTwice() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        engine.afterPublication = { throw TransferError.stopped }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        XCTAssertTrue(files.fileExists(atPath: original.path))
        let resumed = TransferEngine(journal: journal)
        try resumed.run(resumed.load())
        XCTAssertEqual(try contents(target()), "hello")
        XCTAssertFalse(files.fileExists(atPath: original.path))
    }

    func testCancelAfterPublicationKeepsCompletedCopyAndOriginal() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        engine.afterPublication = { throw TransferError.stopped }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        try TransferEngine(journal: journal).cancelSavedTransfer()
        XCTAssertEqual(try contents(target()), "hello")
        XCTAssertEqual(try contents(original), "hello")
    }

    func testSymbolicLinkSourceAndDestinationAreRejected() throws {
        let original = try write()
        let link = source.appendingPathComponent("link.txt")
        try files.createSymbolicLink(at: link, withDestinationURL: original)
        let engine = TransferEngine(journal: journal)
        XCTAssertThrowsError(try prepare(engine, [link]))
        try files.createSymbolicLink(at: target(), withDestinationURL: original)
        let job = try prepare(engine, [original], move: true)
        XCTAssertThrowsError(try engine.run(job))
        XCTAssertEqual(try contents(original), "hello")
    }

    func testDestinationInsideSourceIsRejectedIncludingAliasParent() throws {
        let inside = source.appendingPathComponent("inside")
        try files.createDirectory(at: inside, withIntermediateDirectories: true)
        let engine = TransferEngine(journal: journal)
        XCTAssertThrowsError(try engine.prepare(sources: [source], destination: inside, move: true, limitMB: 30))
        let alias = root.appendingPathComponent("alias")
        try files.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try engine.prepare(sources: [alias.appendingPathComponent("source")],
                                               destination: inside, move: true, limitMB: 30))
    }

    func testASecondJobCannotReplaceSavedTransfer() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        let first = try prepare(engine, [original])
        XCTAssertThrowsError(try prepare(TransferEngine(journal: journal), [original]))
        XCTAssertEqual(try engine.load().id, first.id)
    }

    func testJournalLockExcludesAnotherProcess() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        _ = try prepare(engine, [original])
        let descriptor = open(journal.path + ".lock", O_RDWR)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try TransferEngine(journal: journal).cancelSavedTransfer())
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
    }

    func testForgetRetainsOriginalAndPartialCopy() throws {
        let original = try largeFile()
        let engine = TransferEngine(journal: journal)
        engine.afterChunk = { throw TransferError.stopped }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        try TransferEngine(journal: journal).forgetSavedTransfer()
        XCTAssertTrue(files.fileExists(atPath: original.path))
        XCTAssertEqual(try hiddenFiles().count, 1)
        XCTAssertFalse(files.fileExists(atPath: journal.path))
    }

    func testNetworkRetryDoesNotRetryUnsafeOrPermissionErrors() {
        let engine = TransferEngine(journal: journal)
        XCTAssertTrue(engine.shouldRetry(NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)), network: true))
        XCTAssertFalse(engine.shouldRetry(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), network: true))
        XCTAssertFalse(engine.shouldRetry(NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)), network: false))
        XCTAssertFalse(engine.shouldRetry(TransferError.unsafe("changed"), network: true))
    }

    func useNASPublicationFallback(_ engine: TransferEngine) {
        engine.exclusiveRename = { _, _ in
            errno = ENOTSUP
            return -1
        }
    }

    func testNASPublicationFallbackCopiesAndVerifiesBeforeMove() throws {
        let original = try largeFile()
        let expected = try Data(contentsOf: original)
        let engine = TransferEngine(journal: journal)
        useNASPublicationFallback(engine)
        try engine.run(prepare(engine, [original], move: true))
        XCTAssertEqual(try Data(contentsOf: target("large.bin")), expected)
        XCTAssertFalse(files.fileExists(atPath: original.path))
        XCTAssertTrue(try hiddenFiles().isEmpty)
    }

    func testNASPublicationPartialCanResume() throws {
        let original = try largeFile()
        let expected = try Data(contentsOf: original)
        let engine = TransferEngine(journal: journal)
        useNASPublicationFallback(engine)
        engine.afterPublicationChunk = { throw TransferError.stopped }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        XCTAssertTrue(files.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: target("large.bin")).count, 1_048_576)
        let resumed = TransferEngine(journal: journal)
        try resumed.run(resumed.load())
        XCTAssertEqual(try Data(contentsOf: target("large.bin")), expected)
        XCTAssertFalse(files.fileExists(atPath: original.path))
    }

    func testCancelNASPublicationPartialRemovesIncompleteFinalFile() throws {
        let original = try largeFile()
        let engine = TransferEngine(journal: journal)
        useNASPublicationFallback(engine)
        engine.afterPublicationChunk = { throw TransferError.stopped }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        try TransferEngine(journal: journal).cancelSavedTransfer()
        XCTAssertTrue(files.fileExists(atPath: original.path))
        XCTAssertFalse(files.fileExists(atPath: target("large.bin").path))
        XCTAssertTrue(try hiddenFiles().isEmpty)
    }

    func testNewDestinationFileIsNeverOverwrittenDuringPublication() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        engine.afterChunk = { try Data("other program".utf8).write(to: self.target()) }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        XCTAssertEqual(try contents(target()), "other program")
        XCTAssertEqual(try contents(original), "hello")
    }

    func testChangedDestinationAfterReplaceChoiceIsRetained() throws {
        let original = try write()
        try Data("old".utf8).write(to: target())
        let engine = TransferEngine(journal: journal)
        engine.onConflict = { _, _ in Decision(.replace) }
        engine.afterChunk = { try Data("changed by another program".utf8).write(to: self.target()) }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        XCTAssertEqual(try contents(target()), "changed by another program")
        XCTAssertEqual(try contents(original), "hello")
    }

    func testNetworkResumeAcceptsChangedMountDeviceNumber() throws {
        let original = try largeFile()
        let expected = try Data(contentsOf: original)
        let engine = TransferEngine(journal: journal)
        engine.afterChunk = { throw TransferError.stopped }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        var saved = try engine.load()
        // Reconnecting the same share can assign a new local device number.
        // Location still validates the volume; inode, size, time and data are checked.
        saved.destination.network = true
        saved.destinationStamp.device &+= 1
        saved.entries[0].source.network = true
        saved.entries[0].sourceStamp.device &+= 1
        saved.entries[0].temporaryStamp?.device &+= 1
        try engine.save(saved)
        let resumed = TransferEngine(journal: journal)
        try resumed.run(resumed.load())
        XCTAssertEqual(try Data(contentsOf: target("large.bin")), expected)
        XCTAssertFalse(files.fileExists(atPath: original.path))
    }

    func testLocalFileDeviceMismatchIsRejected() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        var job = try prepare(engine, [original], move: true)
        job.entries[0].sourceStamp.device &+= 1
        try engine.save(job)
        XCTAssertThrowsError(try engine.run(job))
        XCTAssertEqual(try contents(original), "hello")
    }

    func testSameFolderCopyRequestsNameAndRetainsOriginal() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        var asked = false
        engine.onConflict = { _, _ in XCTFail("Same-folder paste must use the rename-only decision"); return Decision(.replace) }
        engine.onSameFolderConflict = { _, _ in asked = true; return Decision(.rename, newName: "renamed.txt") }
        let job = try engine.prepare(sources: [original], destination: source, move: false, limitMB: 0)
        try engine.run(job)
        XCTAssertTrue(asked)
        XCTAssertEqual(try contents(original), "hello")
        XCTAssertEqual(try contents(source.appendingPathComponent("renamed.txt")), "hello")
    }

    func testSameFolderCutRenamesOnlyAfterVerification() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        engine.onSameFolderConflict = { _, _ in Decision(.rename, newName: "renamed.txt") }
        engine.onVerificationStarted = { _ in XCTAssertTrue(self.files.fileExists(atPath: original.path)) }
        try engine.run(engine.prepare(sources: [original], destination: source, move: true, limitMB: 0))
        XCTAssertFalse(files.fileExists(atPath: original.path))
        XCTAssertEqual(try contents(source.appendingPathComponent("renamed.txt")), "hello")
    }

    func testSameFolderCannotReplaceItself() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        engine.onSameFolderConflict = { _, _ in Decision(.replace) }
        XCTAssertThrowsError(try engine.run(engine.prepare(sources: [original], destination: source, move: true, limitMB: 0)))
        XCTAssertEqual(try contents(original), "hello")
    }

    func testCustomRenameRejectsPathTraversal() throws {
        let original = try write()
        try Data("old".utf8).write(to: target())
        let engine = TransferEngine(journal: journal)
        engine.onConflict = { _, _ in Decision(.rename, newName: "../escape.txt") }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        XCTAssertEqual(try contents(original), "hello")
        XCTAssertEqual(try contents(target()), "old")
        XCTAssertFalse(files.fileExists(atPath: root.appendingPathComponent("escape.txt").path))
    }

    func testNextFileCopiesWhilePreviousFileIsBeingVerified() throws {
        let first = try write("a.txt", text: "first")
        let second = try write("second.txt", text: "second")
        let verifying = DispatchSemaphore(value: 0)
        let copiedNext = DispatchSemaphore(value: 0)
        let engine = TransferEngine(journal: journal)
        var current = ""
        engine.onCopyStarted = { path in
            current = path
            if path == second.path { XCTAssertEqual(verifying.wait(timeout: .now() + 5), .success) }
        }
        engine.afterChunk = {
            if current == second.path {
                XCTAssertTrue(self.files.fileExists(atPath: first.path))
                copiedNext.signal()
            }
        }
        engine.onVerificationStarted = { path in
            if path == first.path {
                verifying.signal()
                guard copiedNext.wait(timeout: .now() + 5) == .success else {
                    throw TransferError.unsafe("The next copy did not overlap verification.")
                }
            }
        }
        try engine.run(prepare(engine, [first, second], move: true))
        XCTAssertEqual(try contents(target("a.txt")), "first")
        XCTAssertEqual(try contents(target("second.txt")), "second")
        XCTAssertFalse(files.fileExists(atPath: first.path))
        XCTAssertFalse(files.fileExists(atPath: second.path))
    }

    func testConcurrentJournalUpdatesDoNotLoseCompletedFiles() throws {
        var originals: [URL] = []
        for number in 0..<30 { originals.append(try write("file-\(number).txt", text: "data \(number)")) }
        let engine = TransferEngine(journal: journal)
        try engine.run(prepare(engine, originals, move: true))
        for number in 0..<30 {
            XCTAssertEqual(try contents(target("file-\(number).txt")), "data \(number)")
            XCTAssertFalse(files.fileExists(atPath: originals[number].path))
        }
        XCTAssertFalse(files.fileExists(atPath: journal.path))
    }

    func testProgressTracksBytesAndVerificationBeforeMoveCompletion() throws {
        let first = try largeFile()
        let second = try write("tiny.txt", text: "small")
        let engine = TransferEngine(journal: journal)
        let lock = NSLock()
        var updates: [MoverCore.Progress] = []
        engine.onProgress = { progress in
            lock.lock()
            updates.append(progress)
            lock.unlock()
            if progress.fraction == 1 {
                XCTAssertFalse(self.files.fileExists(atPath: first.path))
                XCTAssertFalse(self.files.fileExists(atPath: second.path))
            }
        }
        try engine.run(prepare(engine, [first, second], move: true))
        let ordered = updates.sorted { $0.sequence < $1.sequence }
        XCTAssertTrue(ordered.contains { !$0.copyingFile.isEmpty && $0.fraction > 0 })
        XCTAssertTrue(ordered.contains { !$0.verifyingFile.isEmpty && $0.fraction < 1 })
        for pair in zip(ordered, ordered.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.fraction, pair.1.fraction) }
        let final = try XCTUnwrap(ordered.last)
        XCTAssertEqual(final.fraction, 1)
        XCTAssertEqual(final.completedFiles, 2)
        XCTAssertEqual(final.totalFiles, 2)
        XCTAssertEqual(final.totalBytes, 3 * 1_048_576 + 5)
        XCTAssertEqual(final.copiedBytes, final.totalBytes)
        XCTAssertEqual(final.writtenBytes, final.totalBytes)
    }

    func testEarlierVerifierDoesNotRegressLaterFileProgress() throws {
        let first = try write("a.txt", text: "first")
        let second = try write("b.txt", text: "second")
        let engine = TransferEngine(journal: journal)
        let tracker = TransferProgress()
        tracker.begin(try prepare(engine, [first, second]))
        _ = tracker.update("a.txt", index: 0, portion: 0.8, lane: "verify")
        let copying = tracker.update("b.txt", index: 1, portion: 0.6, lane: "copy")
        let checking = tracker.update("a.txt", index: 0, portion: 0.9, lane: "verify")
        XCTAssertGreaterThanOrEqual(checking.fraction, copying.fraction)
        XCTAssertEqual(checking.copyingFile, "b.txt")
        XCTAssertEqual(checking.verifyingFile, "a.txt")
        let done = tracker.update("a.txt", index: 0, portion: 1)
        XCTAssertEqual(done.copyingFile, "b.txt")
        XCTAssertTrue(done.verifyingFile.isEmpty)
        XCTAssertGreaterThan(done.sequence, checking.sequence)
    }

    func testUserPauseResumesTheSameMoveWithoutCancelling() throws {
        let original = try largeFile()
        let engine = TransferEngine(journal: journal)
        let paused = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var failure: Error?
        var firstChunk = true
        engine.afterChunk = {
            if firstChunk { firstChunk = false; engine.suspend(); paused.signal() }
        }
        let job = try prepare(engine, [original], move: true)
        DispatchQueue.global().async {
            do { try engine.run(job) }
            catch { lock.lock(); failure = error; lock.unlock() }
            finished.signal()
        }
        XCTAssertEqual(paused.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertTrue(files.fileExists(atPath: original.path))
        XCTAssertFalse(files.fileExists(atPath: target("large.bin").path))
        engine.resume()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        lock.lock(); let error = failure; lock.unlock()
        XCTAssertNil(error)
        XCTAssertEqual(try Data(contentsOf: target("large.bin")).count, 3 * 1_048_576)
        XCTAssertFalse(files.fileExists(atPath: original.path))
    }

    func testUserPauseDuringVerificationRetainsMoveOriginal() throws {
        let original = try largeFile()
        let engine = TransferEngine(journal: journal)
        let paused = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var failure: Error?
        engine.onVerificationStarted = { _ in engine.suspend(); paused.signal() }
        let job = try prepare(engine, [original], move: true)
        DispatchQueue.global().async {
            do { try engine.run(job) }
            catch { lock.lock(); failure = error; lock.unlock() }
            finished.signal()
        }
        XCTAssertEqual(paused.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertTrue(files.fileExists(atPath: original.path))
        engine.resume()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        lock.lock(); let error = failure; lock.unlock()
        XCTAssertNil(error)
        XCTAssertFalse(files.fileExists(atPath: original.path))
    }

    func testCancelWhileUserPausedWakesWorkersAndRecoversPartial() throws {
        let original = try largeFile()
        let engine = TransferEngine(journal: journal)
        let paused = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var failure: Error?
        engine.afterChunk = { engine.suspend(); paused.signal() }
        let job = try prepare(engine, [original], move: true)
        DispatchQueue.global().async {
            do { try engine.run(job) }
            catch { lock.lock(); failure = error; lock.unlock() }
            finished.signal()
        }
        XCTAssertEqual(paused.wait(timeout: .now() + 5), .success)
        engine.pause() // Safe stop, including when the worker is suspended.
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        lock.lock(); let error = failure; lock.unlock()
        guard let error, case TransferError.stopped = error else { return XCTFail("Expected safe cancellation, got \(String(describing: error))") }
        try TransferEngine(journal: journal).cancelSavedTransfer()
        XCTAssertTrue(files.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: original).count, 3 * 1_048_576)
        XCTAssertTrue(try hiddenFiles().isEmpty)
    }

    func testEmptyFolderAndSkippedFileProgressStillCompletes() throws {
        let folder = source.appendingPathComponent("empty")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = try write()
        try Data("existing".utf8).write(to: target())
        let engine = TransferEngine(journal: journal)
        engine.onConflict = { _, _ in Decision(.skip) }
        var last: MoverCore.Progress?
        engine.onProgress = { last = $0 }
        try engine.run(prepare(engine, [folder, original], move: true))
        XCTAssertEqual(last?.fraction, 1)
        XCTAssertEqual(last?.completedFiles, 1)
        XCTAssertEqual(last?.totalFiles, 1)
        XCTAssertTrue(last?.message.contains("skipped") == true)
        XCTAssertEqual(last?.writtenBytes, 0)
        XCTAssertTrue(files.fileExists(atPath: original.path))
    }

    func testBusyNASWaitsForTwoSuccessfulProbesBeforeRetry() throws {
        let original = try largeFile()
        let engine = TransferEngine(journal: journal)
        engine.retrySeconds = 0.001
        engine.stabilityProbeSeconds = 0.001
        var interrupted = false
        var probes = 0
        engine.afterChunk = {
            if !interrupted {
                interrupted = true
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
            }
        }
        engine.networkProbe = { _ in
            probes += 1
            if probes == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)) }
        }
        var job = try prepare(engine, [original], move: true)
        job.destination.network = true
        job.entries[0].source.network = true
        try engine.save(job)
        try engine.run(job)
        XCTAssertGreaterThanOrEqual(probes, 3)
        XCTAssertEqual(try Data(contentsOf: target("large.bin")).count, 3 * 1_048_576)
        XCTAssertFalse(files.fileExists(atPath: original.path))
    }

    func testCompletedJournalCanBeReplayedWithoutRepeatingAMove() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        engine.keepCompletedJournal = true
        try engine.run(prepare(engine, [original], move: true))
        XCTAssertFalse(files.fileExists(atPath: original.path))
        XCTAssertTrue(files.fileExists(atPath: journal.path))
        let restarted = TransferEngine(journal: journal)
        try restarted.run(restarted.load())
        XCTAssertEqual(try contents(target()), "hello")
        XCTAssertFalse(files.fileExists(atPath: journal.path))
    }

    func testNASTimestampRefreshStillRequiresMatchingContents() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        var job = try prepare(engine, [original], move: true)
        job.destination.network = true
        try engine.save(job)
        engine.onVerificationStarted = { _ in
            let partial = try XCTUnwrap(self.hiddenFiles().first)
            try self.files.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: partial.path)
        }
        try engine.run(job)
        XCTAssertEqual(try contents(target()), "hello")
        XCTAssertFalse(files.fileExists(atPath: original.path))
    }

    func testNASTimestampRefreshCannotHideWrongBytes() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        var job = try prepare(engine, [original], move: true)
        job.destination.network = true
        try engine.save(job)
        engine.onVerificationStarted = { _ in
            let partial = try XCTUnwrap(self.hiddenFiles().first)
            let handle = try FileHandle(forWritingTo: partial)
            try handle.write(contentsOf: Data("wrong".utf8))
            try handle.close()
        }
        XCTAssertThrowsError(try engine.run(job))
        XCTAssertEqual(try contents(original), "hello")
    }

    func testLocalTimestampChangesRemainStrictlyRejected() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        let job = try prepare(engine, [original], move: true)
        engine.onVerificationStarted = { _ in
            let partial = try XCTUnwrap(self.hiddenFiles().first)
            try self.files.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: partial.path)
        }
        XCTAssertThrowsError(try engine.run(job))
        XCTAssertEqual(try contents(original), "hello")
    }

    func testNASMoveSupportsServersWithoutExclusiveSourceRename() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        engine.exclusiveSourceRename = { _, _ in errno = ENOTSUP; return -1 }
        var job = try prepare(engine, [original], move: true)
        job.entries[0].source.network = true
        try engine.save(job)
        try engine.run(job)
        XCTAssertEqual(try contents(target()), "hello")
        XCTAssertFalse(files.fileExists(atPath: original.path))
    }

    func testNASUnlinkFallbackRetainsOriginalIfItsContentsChanged() throws {
        let original = try write()
        let engine = TransferEngine(journal: journal)
        engine.exclusiveSourceRename = { _, _ in
            try? Data("wrong".utf8).write(to: original)
            errno = ENOTSUP
            return -1
        }
        var job = try prepare(engine, [original], move: true)
        job.entries[0].source.network = true
        try engine.save(job)
        XCTAssertThrowsError(try engine.run(job))
        XCTAssertEqual(try contents(original), "wrong")
        XCTAssertEqual(try contents(target()), "hello")
    }

    func useNASRecoveryRenameFallback(_ engine: TransferEngine) {
        engine.recoveryRename = { source, target in
            try FileAccess.renameRecoveryFile(source, target, exclusive: { _, _ in errno = ENOTSUP; return -1 })
        }
    }

    func testNASReplaceSupportsBackupRenameFallback() throws {
        let original = try write(text: "new")
        try Data("old".utf8).write(to: target())
        let engine = TransferEngine(journal: journal)
        useNASRecoveryRenameFallback(engine)
        engine.onConflict = { _, _ in Decision(.replace) }
        try engine.run(prepare(engine, [original], move: true))
        XCTAssertEqual(try contents(target()), "new")
        XCTAssertFalse(files.fileExists(atPath: original.path))
        XCTAssertTrue(try hiddenFiles().isEmpty)
    }

    func testCancelNASReplaceRestoresOldDestinationWithoutExclusiveRename() throws {
        let original = try largeFile()
        let final = target("large.bin")
        try Data("old".utf8).write(to: final)
        let engine = TransferEngine(journal: journal)
        useNASRecoveryRenameFallback(engine)
        useNASPublicationFallback(engine)
        engine.onConflict = { _, _ in Decision(.replace) }
        engine.afterPublicationChunk = { throw TransferError.stopped }
        XCTAssertThrowsError(try engine.run(prepare(engine, [original], move: true)))
        let cleanup = TransferEngine(journal: journal)
        useNASRecoveryRenameFallback(cleanup)
        try cleanup.cancelSavedTransfer()
        XCTAssertEqual(try contents(final), "old")
        XCTAssertTrue(files.fileExists(atPath: original.path))
        XCTAssertTrue(try hiddenFiles().isEmpty)
    }
}
