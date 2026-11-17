import Foundation
import Darwin

extension TransferEngine {
    func publish(_ index: Int, job: inout Job, target: URL, temporary: URL, temporaryVerified: Bool = false) throws {
        try beforeIO()
        var entry = job.entries[index]
        guard let expected = entry.publicationStamp, let digest = entry.digest else {
            throw TransferError.unsafe("The verified temporary file is missing its verification record.")
        }
        let backup = temporaryURL(entry, job: job, target: target, suffix: "backup")
        if FileAccess.exists(target), expected.sameFile(as: try FileAccess.stamp(target), onNetwork: job.destination.network) {
            if entry.cleanupRequired {
                try copyPublication(index, job: &job, target: target, temporary: temporary, create: false)
                entry = job.entries[index]
            }
        } else {
            guard FileAccess.exists(temporary) else {
                throw TransferError.unsafe("The verified temporary file changed. Original retained.")
            }
            entry.publicationStamp = try verifiedStamp(temporary, expected: expected, digest: digest,
                network: job.destination.network, limitMB: job.limitMB, readContents: !temporaryVerified)
            job.entries[index] = entry
            try checkpoint(index, job: &job)
            // Move the old destination aside before publishing. A new file at the final
            // name is never overwritten, even if another program creates it mid-transfer.
            if entry.replace {
                guard let old = entry.existingStamp else { throw TransferError.unsafe("Missing replacement record.") }
                if FileAccess.exists(backup) {
                    guard old.matches(try FileAccess.stamp(backup), onNetwork: job.destination.network) else {
                        throw TransferError.unsafe("Replacement backup changed. It was left untouched.")
                    }
                    guard !FileAccess.exists(target) else {
                        throw TransferError.unsafe("Destination changed during replacement. Original and backup retained.")
                    }
                } else {
                    guard FileAccess.exists(target), old.matches(try FileAccess.stamp(target), onNetwork: job.destination.network) else {
                        throw TransferError.unsafe("Destination changed after your conflict choice. Original retained.")
                    }
                    try recoveryRename(target, backup)
                    guard old.matches(try FileAccess.stamp(backup), onNetwork: job.destination.network) else {
                        try? recoveryRename(backup, target)
                        throw TransferError.unsafe("Destination changed during replacement. Files retained for inspection.")
                    }
                }
            } else if FileAccess.exists(target) {
                throw TransferError.unsafe("Another file appeared at the destination. It was left untouched.")
            }
            do {
                guard exclusiveRename(temporary.path, target.path) == 0 else {
                    throw FileAccess.posixError(target.path)
                }
            } catch {
                let code = (error as NSError).code
                guard (error as NSError).domain == NSPOSIXErrorDomain,
                      [Int(ENOTSUP), Int(ENOSYS), Int(EINVAL)].contains(code) else { throw error }
                // Some NAS filesystems do not implement exclusive rename. Create the
                // final name exclusively, journal its identity, then copy and verify it.
                try copyPublication(index, job: &job, target: target, temporary: temporary, create: true)
                entry = job.entries[index]
            }
        }
        try afterPublication?()
        guard let published = entry.publicationStamp else {
            throw TransferError.unsafe("Final destination verification failed. Original retained.")
        }
        // Rename keeps the verified inode and contents. A NAS fallback or a
        // resumed publication created/read a different final file and must hash it.
        entry.publicationStamp = try verifiedStamp(target, expected: published, digest: digest,
            network: job.destination.network, limitMB: job.limitMB,
            readContents: !temporaryVerified || entry.cleanupRequired)
        entry.state = "committed"
        entry.cleanupRequired = false
        job.entries[index] = entry
        try checkpoint(index, job: &job)
    }

    func copyPublication(_ index: Int, job: inout Job, target: URL, temporary: URL, create: Bool) throws {
        var entry = job.entries[index]
        let input = try FileAccess.openFile(temporary, flags: O_RDONLY)
        defer { try? input.close() }
        guard let partStamp = entry.temporaryStamp,
              partStamp.sameFile(as: try FileAccess.stamp(input), onNetwork: job.destination.network) else {
            throw TransferError.unsafe("The temporary file changed before publication.")
        }
        let output = try FileAccess.openFile(target, flags: create ? O_CREAT | O_EXCL | O_RDWR : O_RDWR)
        defer { try? output.close() }
        if create {
            entry.publicationStamp = try FileAccess.stamp(output)
            entry.cleanupRequired = true
            job.entries[index] = entry
            try checkpoint(index, job: &job)
        } else {
            guard let expected = entry.publicationStamp,
                  expected.sameFile(as: try FileAccess.stamp(output), onNetwork: job.destination.network) else {
                throw TransferError.unsafe("Destination changed while finishing the copy. Original retained.")
            }
        }
        let partial = try FileAccess.stamp(output).size
        guard partial <= entry.size else { throw TransferError.unsafe("Published partial copy is larger than the source.") }
        var copied: Int64 = 0
        let started = Date()
        while copied < entry.size {
            try beforeIO()
            let count = Int(min(Int64(ioChunkSize(network: job.destination.network)), (copied < partial ? partial : entry.size) - copied))
            let data = try readExactly(input, count: count, network: job.destination.network)
            guard data.count == count else { throw TransferError.unsafe("Temporary file became shorter during publication.") }
            if copied < partial {
                guard try readExactly(output, count: count, network: job.destination.network) == data else {
                    throw TransferError.unsafe("Published partial copy changed. Original retained.")
                }
            } else {
                try paceNetwork(bytes: data.count, network: job.destination.network)
                try output.write(contentsOf: data)
                progress.recordWrite(data.count)
                try output.synchronize()
                try afterPublicationChunk?()
            }
            copied += Int64(count)
            report("Finishing NAS copy · \(target.lastPathComponent)", index: index, job: job, portion: 0.95)
            try pace(bytes: copied, since: started, limitMB: job.limitMB)
        }
        try output.synchronize()
        try output.close()
        try files.setAttributes([.modificationDate: entry.modified,
                                 .posixPermissions: NSNumber(value: try FileAccess.status(temporary).st_mode & 0o777)],
                                ofItemAtPath: target.path)
        entry.publicationStamp = try FileAccess.stamp(target)
        // Keep cleanupRequired until the complete final file has passed verification.
        job.entries[index] = entry
        try checkpoint(index, job: &job)
    }

    // SMB can replace a client-cached modification time with the server's
    // close-time value. Accept that only after checking actual bytes. If the
    // timestamp changes while hashing, require a second stable, matching read.
    func verifiedStamp(_ url: URL, expected: FileStamp, digest: String, network: Bool,
                       limitMB: Double, readContents: Bool, onRead: ((Int64) -> Void)? = nil) throws -> FileStamp {
        try beforeIO()
        let info = try FileAccess.status(url)
        let before = FileAccess.stamp(info)
        guard info.st_mode & S_IFMT == S_IFREG, expected.sameFile(as: before, onNetwork: network),
              expected.size == before.size, network || expected.matches(before) else {
            throw TransferError.unsafe("The copied file changed. Original retained.")
        }
        if !readContents && expected.matches(before, onNetwork: network) { return before }
        guard try hash(url, limitMB: limitMB, network: network, onRead: onRead) == digest else {
            throw TransferError.unsafe("Copied file contents failed verification. Original retained.")
        }
        let after = try FileAccess.stamp(url)
        guard before.sameFile(as: after, onNetwork: network), before.size == after.size else {
            throw TransferError.unsafe("The copied file changed during verification. Original retained.")
        }
        if before.matches(after, onNetwork: network) { return after }
        guard network, try hash(url, limitMB: limitMB, network: network, onRead: onRead) == digest else {
            throw TransferError.unsafe("The copied file changed during verification. Original retained.")
        }
        let settled = try FileAccess.stamp(url)
        guard after.matches(settled, onNetwork: network) else {
            throw TransferError.unsafe("The copied file is still changing. Original retained.")
        }
        return settled
    }

    @discardableResult
    func verifyFinal(_ entry: Entry, job: Job, target: URL, readContents: Bool = true) throws -> FileStamp {
        guard let expected = entry.publicationStamp, let digest = entry.digest else {
            throw TransferError.unsafe("Cannot confirm the final copy. Original retained.")
        }
        return try verifiedStamp(target, expected: expected, digest: digest, network: job.destination.network,
                                 limitMB: job.limitMB, readContents: readContents)
    }

    func finish(_ index: Int, job: inout Job, target: URL, source: URL, alreadyVerified: Bool = false) throws {
        var entry = job.entries[index]
        entry.publicationStamp = try verifyFinal(entry, job: job, target: target, readContents: !alreadyVerified)
        job.entries[index] = entry
        try checkpoint(index, job: &job)
        let temporary = temporaryURL(entry, job: job, target: target)
        let backup = temporaryURL(entry, job: job, target: target, suffix: "backup")
        if FileAccess.exists(temporary), let stamp = entry.temporaryStamp {
            try FileAccess.removeOwnedFile(temporary, stamp: stamp, onNetwork: job.destination.network)
        }
        if FileAccess.exists(backup), let stamp = entry.existingStamp {
            guard stamp.matches(try FileAccess.stamp(backup), onNetwork: job.destination.network) else {
                throw TransferError.unsafe("Replacement backup changed. Original retained.")
            }
            try FileAccess.removeOwnedFile(backup, stamp: stamp, onNetwork: job.destination.network)
        }
        if job.move {
            let holding = source.deletingLastPathComponent().appendingPathComponent(".mover-\(job.id)-\(entry.id).source")
            if !FileAccess.exists(holding), FileAccess.exists(source) {
                try checkSource(source, entry: entry)
                if exclusiveSourceRename(source.path, holding.path) == 0 {
                    do {
                        try checkSource(holding, entry: entry)
                    } catch {
                        try? recoveryRename(holding, source)
                        throw error
                    }
                } else {
                    let error = FileAccess.posixError(holding.path)
                    guard [Int(ENOTSUP), Int(ENOSYS), Int(EINVAL)].contains(error.code) else { throw error }
                    try removeSourceWithoutExclusiveRename(source, target: target, entry: &entry, index: index, job: &job)
                }
            }
            if FileAccess.exists(holding) {
                try checkSource(holding, entry: entry)
                // Check the destination again after taking the original out of its name.
                // A crash here is recoverable from the committed journal and holding file.
                entry.publicationStamp = try verifyFinal(entry, job: job, target: target, readContents: false)
                job.entries[index] = entry
                try checkpoint(index, job: &job)
                try FileAccess.removeOwnedFile(holding, stamp: entry.sourceStamp, onNetwork: entry.source.network)
            }
        }
        entry.state = "done"
        job.entries[index] = entry
        try checkpoint(index, job: &job)
        report(target.lastPathComponent, index: index, job: job, portion: 1)
    }

    func removeSourceWithoutExclusiveRename(_ source: URL, target: URL, entry: inout Entry,
                                           index: Int, job: inout Job) throws {
        guard let digest = entry.digest else { throw TransferError.unsafe("Missing source verification record.") }
        // Some SMB servers do not support exclusive rename at all. In that case
        // re-read BOTH copies before ordinary unlink, then recheck the open source
        // and its pathname immediately before deletion. Never overwrite a holding name.
        entry.sourceStamp = try verifiedStamp(source, expected: entry.sourceStamp, digest: digest,
            network: entry.source.network, limitMB: job.limitMB, readContents: true)
        entry.publicationStamp = try verifyFinal(entry, job: job, target: target)
        job.entries[index] = entry
        try checkpoint(index, job: &job)
        let original = try FileAccess.openFile(source, flags: O_RDONLY)
        defer { try? original.close() }
        guard entry.sourceStamp.matches(try FileAccess.stamp(original), onNetwork: entry.source.network) else {
            throw TransferError.unsafe("Source changed before cleanup. Original retained.")
        }
        try checkSource(source, entry: entry)
        try FileAccess.removeOwnedFile(source, stamp: entry.sourceStamp, onNetwork: entry.source.network)
    }

    public func cancelSavedTransfer() throws {
        try withJournalLock {
            let job = try load()
            for entry in job.entries where !entry.directory && entry.state != "done" && entry.state != "skipped" {
                let target = try safeTarget(job, entry.target)
                let temporary = temporaryURL(entry, job: job, target: target)
                let backup = temporaryURL(entry, job: job, target: target, suffix: "backup")
                var finalIsVerified = false
                if FileAccess.exists(target), let stamp = entry.publicationStamp,
                   stamp.sameFile(as: try FileAccess.stamp(target), onNetwork: job.destination.network) {
                    if (try? verifyFinal(entry, job: job, target: target)) != nil {
                        finalIsVerified = true
                    } else if entry.cleanupRequired {
                        try FileAccess.removeOwnedFile(target, stamp: stamp, onNetwork: job.destination.network)
                    } else {
                        throw TransferError.unsafe("Destination changed after publication. It was left untouched; cleanup needs review.")
                    }
                }
                if FileAccess.exists(temporary) {
                    guard let stamp = entry.temporaryStamp else {
                        throw TransferError.unsafe("Cannot identify a partial copy safely. It was left untouched.")
                    }
                    try FileAccess.removeOwnedFile(temporary, stamp: stamp, onNetwork: job.destination.network)
                }
                if FileAccess.exists(backup) {
                    guard let stamp = entry.existingStamp,
                          stamp.matches(try FileAccess.stamp(backup), onNetwork: job.destination.network) else {
                        throw TransferError.unsafe("Cannot identify the replacement backup safely.")
                    }
                    if finalIsVerified {
                        try FileAccess.removeOwnedFile(backup, stamp: stamp, onNetwork: job.destination.network)
                    } else {
                        guard !FileAccess.exists(target) else {
                            throw TransferError.unsafe("The destination changed. Its replacement backup was retained.")
                        }
                        try recoveryRename(backup, target)
                    }
                }
                if job.move {
                    let source = try entry.source.resolve()
                    let holding = source.deletingLastPathComponent().appendingPathComponent(".mover-\(job.id)-\(entry.id).source")
                    if FileAccess.exists(holding) {
                        try checkSource(holding, entry: entry)
                        guard !FileAccess.exists(source) else {
                            throw TransferError.unsafe("The original name is occupied. The protected original was retained at \(holding.path).")
                        }
                        try recoveryRename(holding, source)
                    }
                }
            }
            try files.removeItem(at: journal)
        }
    }
}
