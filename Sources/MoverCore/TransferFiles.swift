import Foundation
import CryptoKit
import Darwin

extension TransferEngine {
    func checkSource(_ source: URL, entry: Entry) throws {
        let info = try FileAccess.status(source)
        let actual = FileAccess.stamp(info)
        let expectedKind = entry.directory ? S_IFDIR : S_IFREG
        let matches = entry.directory ? entry.sourceStamp.sameFile(as: actual, onNetwork: entry.source.network) :
            entry.sourceStamp.matches(actual, onNetwork: entry.source.network)
        guard info.st_mode & S_IFMT == expectedKind, matches else {
            throw TransferError.unsafe("Source changed: \(source.lastPathComponent). Original retained.")
        }
    }

    func process(_ index: Int, job: inout Job) throws {
        var entry = job.entries[index]
        if entry.state == "done" || entry.state == "skipped" { return }
        var target = try safeTarget(job, entry.target)
        let source = try entry.source.resolve()
        if ["verifying", "publishing", "committed"].contains(entry.state) { return }
        try checkSource(source, entry: entry)

        if entry.state == "ready", FileAccess.exists(target) {
            let destinationStamp = try FileAccess.stamp(target)
            let sameItem = source.path == target.path || entry.sourceStamp.sameFile(as: destinationStamp)
            let decision = sameItem ? onSameFolderConflict(target.lastPathComponent, entry.directory) :
                (allChoice.map { Decision($0) } ?? onConflict(target.lastPathComponent, entry.directory))
            guard !decision.interrupted else { throw TransferError.interrupted }
            if !sameItem, decision.applyToAll, decision.choice != .cancel { allChoice = decision.choice }
            switch decision.choice {
            case .cancel:
                throw TransferError.stopped
            case .skip:
                let rootSource = entry.source.original
                var changed: [Int] = []
                for position in job.entries.indices where position == index || job.entries[position].source.original.hasPrefix(rootSource + "/") {
                    if position >= index {
                        job.entries[position].state = "skipped"
                        changed.append(position)
                    }
                }
                try checkpoint(changed, job: &job)
                for position in changed { report("Skipped · " + job.entries[position].target, index: position, job: job, portion: 1) }
                return
            case .rename:
                let newTarget: URL
                if let name = decision.newName {
                    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"),
                          !name.utf8.contains(0) else {
                        throw TransferError.unsafe("Choose a valid filename without / or :.")
                    }
                    newTarget = target.deletingLastPathComponent().appendingPathComponent(name)
                    guard !FileAccess.exists(newTarget) else {
                        throw TransferError.unsafe("\(name) already exists. Choose a different name.")
                    }
                } else {
                    newTarget = try availableName(target)
                }
                let oldRelative = entry.target
                let parent = (oldRelative as NSString).deletingLastPathComponent
                let newRelative = parent.isEmpty ? newTarget.lastPathComponent : parent + "/" + newTarget.lastPathComponent
                let rootSource = entry.source.original
                var changed: [Int] = []
                for position in job.entries.indices where position >= index {
                    let candidate = job.entries[position]
                    if position == index || candidate.source.original.hasPrefix(rootSource + "/") {
                        job.entries[position].target = newRelative + String(candidate.target.dropFirst(oldRelative.count))
                        changed.append(position)
                    }
                }
                try checkpoint(changed, job: &job)
                entry = job.entries[index]
                target = try safeTarget(job, entry.target)
            case .replace:
                guard !sameItem else {
                    throw TransferError.unsafe("Choose a new name when pasting into the same folder. The original cannot replace itself.")
                }
                let info = try FileAccess.status(target)
                let expectedKind = entry.directory ? S_IFDIR : S_IFREG
                guard info.st_mode & S_IFMT == expectedKind else {
                    throw TransferError.unsafe("A file and folder have the same name. Choose Skip or Rename after resuming this job.")
                }
                entry.replace = true
                entry.existingStamp = FileAccess.stamp(info)
                job.entries[index] = entry
            }
            try checkpoint(index, job: &job)
        }

        if entry.directory {
            if FileAccess.exists(target) {
                guard entry.replace, let expected = entry.existingStamp,
                      expected.sameFile(as: try FileAccess.stamp(target), onNetwork: job.destination.network) else {
                    throw TransferError.unsafe("Destination changed after your conflict choice. Original retained.")
                }
            } else {
                try files.createDirectory(at: target, withIntermediateDirectories: false)
            }
            entry.publicationStamp = try FileAccess.stamp(target)
            entry.state = "done"
            job.entries[index] = entry
            try checkpoint(index, job: &job)
            report(target.lastPathComponent, index: index, job: job, portion: 1)
            return
        }

        let temporary = temporaryURL(entry, job: job, target: target)
        try copyResuming(source: source, temporary: temporary, index: index, job: &job)
    }

    func availableName(_ target: URL) throws -> URL {
        let parent = target.deletingLastPathComponent()
        let info = try FileAccess.status(target)
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        let name = target.lastPathComponent as NSString
        let ext = isDirectory ? "" : name.pathExtension
        let stem = ext.isEmpty ? String(name) : name.deletingPathExtension
        var number = 2
        while true {
            try checkStop()
            let filename = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            let candidate = parent.appendingPathComponent(filename)
            if !FileAccess.exists(candidate) { return candidate }
            number += 1
        }
    }

    func copyResuming(source: URL, temporary: URL, index: Int, job: inout Job) throws {
        try onCopyStarted?(source.path)
        report(source.lastPathComponent, index: index, job: job, lane: "copy")
        var entry = job.entries[index]
        let input = try FileAccess.openFile(source, flags: O_RDONLY)
        defer { try? input.close() }
        guard entry.sourceStamp.matches(try FileAccess.stamp(input), onNetwork: entry.source.network) else {
            throw TransferError.unsafe("Source changed before copying. Original retained.")
        }
        let output: FileHandle
        if FileAccess.exists(temporary) {
            output = try FileAccess.openFile(temporary, flags: O_RDWR)
            guard let expected = entry.temporaryStamp,
                  expected.sameFile(as: try FileAccess.stamp(output), onNetwork: job.destination.network) else {
                try? output.close()
                throw TransferError.unsafe("The partial copy changed or belongs to another job. It was left untouched.")
            }
        } else {
            guard entry.temporaryStamp == nil else {
                throw TransferError.unsafe("The saved partial copy is missing. Cancel this transfer before restarting it.")
            }
            output = try FileAccess.openFile(temporary, flags: O_CREAT | O_EXCL | O_RDWR)
            entry.temporaryStamp = try FileAccess.stamp(output)
            entry.state = "copying"
            job.entries[index] = entry
            try checkpoint(index, job: &job)
        }
        defer { try? output.close() }
        let partial = try FileAccess.stamp(output).size
        guard partial <= entry.size else {
            throw TransferError.unsafe("Partial file is larger than the source. Original retained.")
        }
        var copied: Int64 = 0
        var hasher = SHA256()
        let started = Date()
        var pacedBytes: Int64 = 0
        // Never trust an offset alone: verify the whole existing prefix against the source.
        while copied < partial {
            try beforeIO()
            let count = Int(min(Int64(chunkSize), partial - copied))
            let original = try readExactly(input, count: count, network: entry.source.network)
            let saved = try readExactly(output, count: count, network: job.destination.network)
            guard original == saved, original.count == count else {
                throw TransferError.unsafe("Saved partial copy does not match the source. Original and partial copy retained for inspection.")
            }
            hasher.update(data: original)
            copied += Int64(count)
            pacedBytes += Int64(count)
            report("Checking saved progress · \(source.lastPathComponent)", index: index, job: job,
                   portion: entry.size == 0 ? 0 : Double(copied) / Double(entry.size) * 0.8, lane: "copy")
            try pace(bytes: pacedBytes, since: started, limitMB: job.limitMB)
        }
        while copied < entry.size {
            try beforeIO()
            let count = Int(min(Int64(ioChunkSize(network: entry.source.network || job.destination.network)), entry.size - copied))
            let data = try readExactly(input, count: count, network: entry.source.network)
            guard data.count == count else {
                throw TransferError.unsafe("Source became shorter during the transfer. Original retained.")
            }
            try beforeIO()
            try paceNetwork(bytes: data.count, network: job.destination.network)
            try output.write(contentsOf: data)
            progress.recordWrite(data.count)
            hasher.update(data: data)
            copied += Int64(data.count)
            pacedBytes += Int64(data.count)
            // A complete file is synchronized before verification. Per-chunk fsync
            // needlessly stalls SMB writes; resume verifies any surviving prefix.
            report("\(source.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: copied, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))",
                   index: index, job: job, portion: entry.size == 0 ? 0.8 : Double(copied) / Double(entry.size) * 0.8, lane: "copy")
            try afterChunk?()
            try pace(bytes: pacedBytes, since: started, limitMB: job.limitMB)
        }
        try output.synchronize()
        // SMB servers may apply the last-write timestamp when the write handle
        // closes. Close it before restoring metadata and recording the stamp.
        try output.close()
        try checkSource(source, entry: entry)
        guard entry.sourceStamp.matches(try FileAccess.stamp(input), onNetwork: entry.source.network) else {
            throw TransferError.unsafe("Source changed during the transfer. Original retained.")
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        try files.setAttributes([.modificationDate: entry.modified,
                                 .posixPermissions: NSNumber(value: try FileAccess.status(source).st_mode & 0o777)],
                                ofItemAtPath: temporary.path)
        entry.digest = digest
        entry.state = "verifying"
        entry.publicationStamp = try FileAccess.stamp(temporary)
        job.entries[index] = entry
        try checkpoint(index, job: &job)
        report(source.lastPathComponent, index: index, job: job, portion: 0.8, lane: "copy")
    }

    func readExactly(_ handle: FileHandle, count: Int, network: Bool = false) throws -> Data {
        var result = Data()
        while result.count < count {
            try beforeIO()
            let chunk = try handle.read(upToCount: min(count - result.count, ioChunkSize(network: network))) ?? Data()
            if chunk.isEmpty { break }
            try paceNetwork(bytes: chunk.count, network: network)
            result.append(chunk)
        }
        return result
    }

    func hash(_ url: URL, limitMB: Double, network: Bool = false, onRead: ((Int64) -> Void)? = nil) throws -> String {
        let input = try FileAccess.openFile(url, flags: O_RDONLY)
        defer { try? input.close() }
        var hasher = SHA256()
        var read: Int64 = 0
        let started = Date()
        while true {
            try beforeIO()
            let data = try input.read(upToCount: ioChunkSize(network: network)) ?? Data()
            if data.isEmpty { break }
            try paceNetwork(bytes: data.count, network: network)
            hasher.update(data: data)
            read += Int64(data.count)
            onRead?(read)
            try pace(bytes: read, since: started, limitMB: limitMB)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func pace(bytes: Int64, since start: Date, limitMB: Double) throws {
        if limitMB == 0 { return }
        let duration = Double(bytes) / (limitMB * 1_000_000)
        while duration > Date().timeIntervalSince(start) {
            try checkStop()
            Thread.sleep(forTimeInterval: min(0.05, duration - Date().timeIntervalSince(start)))
        }
    }
}
