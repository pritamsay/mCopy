import Foundation
import Darwin

enum FileAccess {
    static func status(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError(url.path) }
        return info
    }

    static func stamp(_ url: URL) throws -> FileStamp {
        stamp(try status(url))
    }

    static func stamp(_ info: stat) -> FileStamp {
        FileStamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                  seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        // A dangling symlink counts as an existing entry too.
        return lstat(url.path, &info) == 0
    }

    static func requireDirectory(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/")
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            let info = try status(current)
            // Foundation normalizes /private/var and /private/tmp to the standard
            // macOS aliases. Permit only these fixed system aliases, not user links.
            let systemAliases = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"]
            if info.st_mode & S_IFMT == S_IFLNK, let resolved = systemAliases[current.path],
               let link = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) {
                if link == resolved || "/" + link == resolved {
                    current = URL(fileURLWithPath: resolved)
                    continue
                }
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw TransferError.unsafe("Destination contains a symbolic link or is no longer a folder: \(current.path)")
            }
        }
    }

    static func openFile(_ url: URL, flags: Int32) throws -> FileHandle {
        let descriptor = open(url.path, flags | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError(url.path) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw TransferError.unsafe("The selected path is no longer a regular file: \(url.path)")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func stamp(_ handle: FileHandle) throws -> FileStamp {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw posixError("open file") }
        return stamp(info)
    }

    static func renameExclusive(_ source: URL, _ destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw posixError(destination.path)
        }
    }

    // Recovery names are unique to a job. Some SMB servers reject RENAME_EXCL
    // even though ordinary rename is supported. Guard the empty recovery name
    // and verify the moved file's identity in the caller before proceeding.
    static func renameRecoveryFile(_ source: URL, _ destination: URL,
                                   exclusive: (String, String) -> Int32 = {
        renamex_np($0, $1, UInt32(RENAME_EXCL))
    }) throws {
        if exclusive(source.path, destination.path) == 0 { return }
        let error = posixError(destination.path)
        guard [Int(ENOTSUP), Int(ENOSYS), Int(EINVAL)].contains(error.code) else { throw error }
        guard !exists(destination) else {
            throw TransferError.unsafe("A file appeared at the recovery destination. It was left untouched.")
        }
        guard rename(source.path, destination.path) == 0 else { throw posixError(destination.path) }
    }

    static func removeOwnedFile(_ url: URL, stamp expected: FileStamp, onNetwork: Bool = false) throws {
        guard exists(url) else { return }
        let info = try status(url)
        guard info.st_mode & S_IFMT == S_IFREG, expected.sameFile(as: stamp(info), onNetwork: onNetwork) else {
            throw TransferError.unsafe("File identity changed. It was left untouched: \(url.path)")
        }
        guard unlink(url.path) == 0 else { throw posixError(url.path) }
    }

    static func posixError(_ path: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "\(String(cString: strerror(code))): \(path)"
        ])
    }
}
