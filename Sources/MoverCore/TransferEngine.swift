import Foundation
import CryptoKit
import Darwin

public final class TransferEngine {
    public let journal: URL
    public var onProgress: (Progress) -> Void = { _ in }
    public var onConflict: (String, Bool) -> Decision = { _, _ in Decision(.cancel) }
    public var onSameFolderConflict: (String, Bool) -> Decision = { _, _ in Decision(.rename) }
    public var onReconnect: (String) -> Void = { _ in }
    public var retrySeconds = 5.0
    public var maximumRetrySeconds = 30.0
    public var stabilityProbeSeconds = 1.0
    public var keepCompletedJournal = false

    // These hooks let tests interrupt real transfers at specific disk operations.
    public var afterChunk: (() throws -> Void)?
    public var onCopyStarted: ((String) throws -> Void)?
    public var afterPublication: (() throws -> Void)?
    public var afterPublicationChunk: (() throws -> Void)?
    public var onVerificationStarted: ((String) throws -> Void)?
    public var networkProbe: ((Int) throws -> Void)?
    public var exclusiveRename: (String, String) -> Int32 = { source, target in
        renamex_np(source, target, UInt32(RENAME_EXCL))
    }
    public var exclusiveSourceRename: (String, String) -> Int32 = { source, target in
        renamex_np(source, target, UInt32(RENAME_EXCL))
    }
    public var recoveryRename: (URL, URL) throws -> Void = { source, target in
        try FileAccess.renameRecoveryFile(source, target)
    }

    let files = FileManager.default
    let stopLock = NSCondition()
    var stopRequested = false
    var suspended = false
    var pipelineFailure: Error?
    let stateLock = NSRecursiveLock()
    var activeJob: Job?
    let networkLock = NSLock()
    let progress = TransferProgress()
    let networkBandwidth = NetworkBandwidth()
    var networkQuietUntil = Date.distantPast
    var allChoice: Choice?
    let chunkSize = 1_048_576

    public init(journal: URL) {
        self.journal = journal
    }

    public var networkLimitMB: Double {
        get { networkBandwidth.limitMB }
        set { networkBandwidth.setLimitMB(newValue) }
    }

    public func usesNetwork(_ job: Job) -> Bool {
        job.destination.network || job.entries.contains { $0.source.network }
    }

    func ioChunkSize(network: Bool) -> Int {
        network && networkLimitMB > 0 ? 65_536 : chunkSize
    }

    func paceNetwork(bytes: Int, network: Bool) throws {
        guard network else { return }
        var remaining = bytes
        while remaining > 0 {
            try checkStop()
            let allowance = networkBandwidth.take(remaining, at: ProcessInfo.processInfo.systemUptime)
            remaining -= allowance.bytes
            if allowance.wait > 0 { Thread.sleep(forTimeInterval: min(0.05, allowance.wait)) }
        }
    }

    public func pause() {
        stopLock.lock()
        stopRequested = true
        suspended = false
        stopLock.broadcast()
        stopLock.unlock()
    }

    // A user pause keeps both workers and the journal alive. The older pause()
    // method requests a safe stop for cancellation, shutdown and recovery.
    public func suspend() {
        stopLock.lock()
        if !stopRequested { suspended = true }
        stopLock.unlock()
    }

    public func resume() {
        stopLock.lock()
        suspended = false
        stopLock.broadcast()
        stopLock.unlock()
    }

    public func checkCancellation() throws { try checkStop() }
    public func waitForRetry(_ seconds: Double) throws { try wait(seconds) }

    func checkStop() throws {
        stopLock.lock()
        while suspended && !stopRequested && pipelineFailure == nil { stopLock.wait() }
        let stopped = stopRequested
        let failure = pipelineFailure
        stopLock.unlock()
        if stopped { throw TransferError.stopped }
        if let failure { throw failure }
    }

    func withJournalLock<T>(_ work: () throws -> T) throws -> T {
        try files.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(journal.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw FileAccess.posixError(journal.path + ".lock") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw TransferError.unsafe("Another myCopy process is already using this saved transfer.")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try work()
    }

    public func load() throws -> Job {
        let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: journal))
        guard job.formatVersion == 1 || job.formatVersion == 2 else {
            throw TransferError.unsafe("This saved transfer uses an unsupported journal version.")
        }
        return job
    }

    func save(_ job: Job) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(job).write(to: journal, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        let handle = try FileAccess.openFile(journal, flags: O_RDWR)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    public func forgetSavedTransfer() throws {
        try withJournalLock {
            if FileAccess.exists(journal) { try files.removeItem(at: journal) }
        }
    }

    public func prepare(sources: [URL], destination: URL, move: Bool, limitMB: Double,
                        finderTarget: Bool = false, folderOnly: Bool = false) throws -> Job {
        try withJournalLock {
            guard !FileAccess.exists(journal) else {
                throw TransferError.unsafe("Finish or resume the saved transfer before starting another one.")
            }
            guard !sources.isEmpty else { throw TransferError.unsafe("Add at least one file or folder.") }
            guard limitMB >= 0, limitMB.isFinite else { throw TransferError.unsafe("Choose a valid transfer speed.") }
            let destination = destination.standardizedFileURL
            try FileAccess.requireDirectory(destination)
            // Remove duplicate and nested selections so a file is never moved twice.
            var selected: [URL] = []
            let normalized = sources.map { source in
                source.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appendingPathComponent(source.lastPathComponent).standardizedFileURL
            }
            for source in normalized.sorted(by: { $0.path.count < $1.path.count }) {
                if selected.contains(where: { source.path == $0.path || source.path.hasPrefix($0.path + "/") }) { continue }
                guard source.path != "/", destination.path != source.path, !destination.path.hasPrefix(source.path + "/") else {
                    throw TransferError.unsafe("Choose a destination outside the source folder.")
                }
                selected.append(source)
            }
            var entries: [Entry] = []
            for source in selected {
                try scan(source, target: source.lastPathComponent, entries: &entries)
            }
            let job = Job(destination: try Location(destination), destinationStamp: try FileAccess.stamp(destination),
                          entries: entries, move: move, limitMB: limitMB)
            try save(job)
            return job
        }
    }

    func scan(_ source: URL, target: String, entries: inout [Entry]) throws {
        try checkStop()
        let info = try FileAccess.status(source)
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFDIR || kind == S_IFREG else {
            throw TransferError.unsafe("\(source.lastPathComponent): symbolic links and special files are not supported. No files have been moved.")
        }
        if kind == S_IFREG {
            let fork = source.path + "/..namedfork/rsrc"
            var forkInfo = stat()
            if stat(fork, &forkInfo) == 0, forkInfo.st_size > 0 {
                throw TransferError.unsafe("\(source.lastPathComponent) has a resource fork. Use Finder for this file to preserve it.")
            }
        }
        let date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        entries.append(Entry(source: try Location(source), target: target, directory: kind == S_IFDIR,
                             size: kind == S_IFREG ? info.st_size : 0, modified: date, sourceStamp: FileAccess.stamp(info)))
        if kind == S_IFDIR {
            let children = try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                try scan(child, target: target + "/" + child.lastPathComponent, entries: &entries)
            }
        }
    }

    public func run(_ savedJob: Job) throws {
        try withJournalLock {
            var job = try load()
            guard job.id == savedJob.id else { throw TransferError.unsafe("The saved transfer changed. Try the operation again.") }
            job.limitMB = savedJob.limitMB
            job.formatVersion = 2
            try save(job)
            stateLock.lock()
            activeJob = job
            stateLock.unlock()
            progress.begin(job)
            defer {
                stateLock.lock()
                activeJob = nil
                stateLock.unlock()
            }
            try runPipeline()
            job = snapshot()
            guard job.entries.allSatisfy({ $0.state == "done" || $0.state == "skipped" }) else {
                throw TransferError.unsafe("Some files are still waiting for verification. Their originals were retained.")
            }
            if job.move {
                // Only remove empty source folders. Skipped/new files keep their parents alive.
                for entry in job.entries.reversed() where entry.directory && entry.state == "done" {
                    guard let source = try? entry.source.resolve(), let info = try? FileAccess.status(source),
                          info.st_mode & S_IFMT == S_IFDIR,
                          entry.sourceStamp.sameFile(as: FileAccess.stamp(info), onNetwork: entry.source.network) else { continue }
                    _ = rmdir(source.path)
                }
            }
            let skipped = job.entries.filter { $0.state == "skipped" }.count
            if !keepCompletedJournal { try files.removeItem(at: journal) }
            let message = skipped == 0 ? "Transfer complete." : "Transfer complete. \(skipped) item(s) skipped; originals kept."
            onProgress(Progress(message: message, fraction: 1,
                copiedBytes: job.entries.reduce(0) { $0 + $1.size },
                totalBytes: job.entries.reduce(0) { $0 + $1.size },
                completedFiles: job.entries.filter { !$0.directory }.count,
                totalFiles: job.entries.filter { !$0.directory }.count, sequence: UInt64.max,
                writtenBytes: progress.writtenByteCount, copyingFinished: true))
        }
    }

    public func shouldRetry(_ error: Error, network: Bool) -> Bool {
        guard network else { return false }
        if case TransferError.unavailable = error { return true }
        if error is TransferError { return false }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            return [EBUSY, EIO, ENXIO, ENODEV, ENOTCONN, ETIMEDOUT, ECONNRESET, ECONNABORTED,
                    EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ENETUNREACH, ESTALE, EAGAIN, ENOENT].contains(Int32(error.code))
        }
        if error.domain == NSCocoaErrorDomain, let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return shouldRetry(underlying, network: true)
        }
        return false
    }

    func report(_ message: String, index: Int, job: Job, portion: Double = 0, lane: String = "") {
        onProgress(progress.update(message, index: index, portion: portion, lane: lane))
    }

    func safeTarget(_ job: Job, _ relative: String) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw TransferError.unsafe("Invalid destination path.")
        }
        let root = try job.destination.resolve()
        try FileAccess.requireDirectory(root)
        guard job.destinationStamp.sameFile(as: try FileAccess.stamp(root), onNetwork: job.destination.network) else {
            throw TransferError.unsafe("Destination folder changed during the transfer.")
        }
        let target = root.appendingPathComponent(relative)
        try FileAccess.requireDirectory(target.deletingLastPathComponent())
        for entry in job.entries where entry.directory && entry.state == "done" && relative.hasPrefix(entry.target + "/") {
            let ancestor = root.appendingPathComponent(entry.target)
            guard let expected = entry.publicationStamp,
                  expected.sameFile(as: try FileAccess.stamp(ancestor), onNetwork: job.destination.network) else {
                throw TransferError.unsafe("A destination folder changed during the transfer.")
            }
        }
        if FileAccess.exists(target), try FileAccess.status(target).st_mode & S_IFMT == S_IFLNK {
            throw TransferError.unsafe("Destination contains a symbolic link: \(target.path)")
        }
        return target
    }

    func temporaryURL(_ entry: Entry, job: Job, target: URL, suffix: String = "part") -> URL {
        target.deletingLastPathComponent().appendingPathComponent(".mover-\(job.id)-\(entry.id).\(suffix)")
    }
}
