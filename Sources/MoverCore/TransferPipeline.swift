import Foundation

extension TransferEngine {
    // Only this lock protects the shared journal. Disk copying and hashing happen
    // outside it, so the two workers can make progress together.
    func snapshot() -> Job {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeJob!
    }

    func checkpoint(_ indices: [Int], job: inout Job) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard var shared = activeJob else {
            try save(job)
            return
        }
        // Merge only the entries this worker owns. Saving a whole old snapshot
        // would otherwise erase another worker's completed verification.
        for index in indices { shared.entries[index] = job.entries[index] }
        try save(shared)
        activeJob = shared
        job = shared
    }

    func checkpoint(_ index: Int, job: inout Job) throws {
        try checkpoint([index], job: &job)
    }

    func recordFailure(_ error: Error) {
        stopLock.lock()
        if pipelineFailure == nil { pipelineFailure = error }
        stopLock.broadcast()
        stopLock.unlock()
    }

    func runPipeline() throws {
        let verifier = DispatchQueue(label: "local.pritam.mycopy.verification", qos: .utility)
        let finished = DispatchGroup()
        // A slot covers copying + queued verification + verification. Two slots
        // allow the next file to copy while one file is checked, with bounded I/O.
        let slots = DispatchSemaphore(value: 2)
        let count = snapshot().entries.count
        for index in 0..<count {
            var acquired = false
            do {
                while slots.wait(timeout: .now() + 0.1) != .success { try checkStop() }
                acquired = true
                try checkStop()
                var job = snapshot()
                try retryNetwork(job: job, index: index) { try process(index, job: &job) }
                let state = job.entries[index].state
                if state == "verifying" || state == "publishing" || state == "committed" {
                    finished.enter()
                    verifier.async { [self] in
                        defer { slots.signal(); finished.leave() }
                        do {
                            try checkStop()
                            var latest = snapshot()
                            try retryNetwork(job: latest, index: index) {
                                try verifyAndFinish(index, job: &latest)
                            }
                        } catch { recordFailure(error) }
                    }
                } else {
                    slots.signal()
                }
            } catch {
                if acquired { slots.signal() }
                recordFailure(error)
                break
            }
        }
        // Keep the process/journal lock until every verifier has stopped safely.
        finished.wait()
        try checkStop()
    }

    func verifyAndFinish(_ index: Int, job: inout Job) throws {
        var entry = job.entries[index]
        let target = try safeTarget(job, entry.target)
        let source = try entry.source.resolve()
        let temporary = temporaryURL(entry, job: job, target: target)
        var verifiedHere = false
        if entry.state == "verifying" {
            try onVerificationStarted?(entry.source.original)
            report(source.lastPathComponent, index: index, job: job, portion: 0.8, lane: "verify")
            try checkSource(source, entry: entry)
            guard let expected = entry.publicationStamp, let digest = entry.digest else {
                throw TransferError.unsafe("Verification failed for \(source.lastPathComponent). Original retained.")
            }
            let reportingJob = job
            let size = entry.size
            entry.publicationStamp = try verifiedStamp(temporary, expected: expected, digest: digest,
                network: job.destination.network, limitMB: job.limitMB, readContents: true, onRead: { [self] read in
                    let checked = size == 0 ? 1 : min(1, Double(read) / Double(size))
                    report(source.lastPathComponent, index: index, job: reportingJob, portion: 0.8 + checked * 0.14, lane: "verify")
                })
            try checkSource(source, entry: entry)
            verifiedHere = true
            entry.state = "publishing"
            job.entries[index] = entry
            try checkpoint(index, job: &job)
        }
        if job.entries[index].state == "publishing" {
            try checkSource(source, entry: job.entries[index])
            try publish(index, job: &job, target: target, temporary: temporary, temporaryVerified: verifiedHere)
        }
        // A committed entry loaded from disk needs a fresh full check. Entries
        // just published have already been read and checked by this worker.
        try finish(index, job: &job, target: target, source: source,
                   alreadyVerified: entry.state != "committed")
    }
}
