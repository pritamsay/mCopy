import Foundation
import Darwin

// Uses generated test data only. The NAS path is intentionally hardcoded.
@main
struct NASSmoke {
    static func main() {
        do { try runCheck() }
        catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func runCheck() throws {
        let files = FileManager.default
        let nasPath = ProcessInfo.processInfo.environment["MCOPY_NAS_PATH"] ?? "/Volumes/NAS"
        let nas = URL(fileURLWithPath: nasPath)
        let values = try nas.resourceValues(forKeys: [.volumeIsLocalKey])
        guard values.volumeIsLocal == false else {
            throw TransferError.unsafe("Mount the NAS share and set MCOPY_NAS_PATH before running this check.")
        }
        let name = UUID().uuidString
        let local = URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent(".build/NASSmoke-" + name)
        let remote = nas.appendingPathComponent(".mcopy-validation-" + name)
        let original = local.appendingPathComponent("TransferFolder")
        let returned = local.appendingPathComponent("Returned")
        try files.createDirectory(at: original.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try files.createDirectory(at: returned, withIntermediateDirectories: true)
        try files.createDirectory(at: remote, withIntermediateDirectories: false)
        let payload = Data(repeating: 73, count: 131_072)
        let text = Data("mCopy generated NAS validation file.\n".utf8)
        try payload.write(to: original.appendingPathComponent("payload.bin"))
        try text.write(to: original.appendingPathComponent("note.txt"))

        let copy = TransferEngine(journal: local.appendingPathComponent("copy.json"))
        copy.networkLimitMB = 0.5 // Exercise the shared adaptive I/O budget on a real NAS.
        copy.onReconnect = { print($0) }
        let copyJob = try copy.prepare(sources: [original], destination: remote, move: false, limitMB: 0)
        guard copyJob.destination.network else { throw TransferError.unsafe("Destination was not identified as a NAS.") }
        try copy.run(copyJob)
        let nasFolder = remote.appendingPathComponent("TransferFolder")
        guard try Data(contentsOf: nasFolder.appendingPathComponent("payload.bin")) == payload,
              try Data(contentsOf: nasFolder.appendingPathComponent("note.txt")) == text,
              files.fileExists(atPath: original.appendingPathComponent("payload.bin").path) else {
            throw TransferError.unsafe("NAS copy validation failed. Generated artifacts retained for inspection.")
        }
        print("PASS: local-to-NAS copy, bytes verified, originals retained.")

        // Test rollback of a NAS replacement interrupted during final publication.
        let originalNote = original.appendingPathComponent("note.txt")
        try Data("New replacement data to cancel.\n".utf8).write(to: originalNote)
        let interrupted = TransferEngine(journal: local.appendingPathComponent("cancel-replace.json"))
        interrupted.onConflict = { _, _ in Decision(.replace) }
        interrupted.afterPublicationChunk = { throw TransferError.stopped }
        do {
            try interrupted.run(interrupted.prepare(sources: [originalNote], destination: nasFolder, move: false, limitMB: 0))
            throw TransferError.unsafe("The NAS replacement was expected to be interrupted.")
        } catch TransferError.stopped { }
        try TransferEngine(journal: interrupted.journal).cancelSavedTransfer()
        guard try Data(contentsOf: nasFolder.appendingPathComponent("note.txt")) == text else {
            throw TransferError.unsafe("NAS replacement rollback did not retain the old destination.")
        }
        print("PASS: interrupted NAS replacement restored the old destination.")

        try text.write(to: originalNote)
        let replace = TransferEngine(journal: local.appendingPathComponent("replace.json"))
        replace.onConflict = { _, _ in Decision(.replace, all: true) }
        try replace.run(replace.prepare(sources: [original], destination: remote, move: false, limitMB: 0))
        guard try Data(contentsOf: nasFolder.appendingPathComponent("note.txt")) == text,
              try Data(contentsOf: nasFolder.appendingPathComponent("payload.bin")) == payload else {
            throw TransferError.unsafe("NAS replacement verification failed.")
        }
        print("PASS: existing NAS files replaced and verified.")

        let move = TransferEngine(journal: local.appendingPathComponent("move.json"))
        move.networkLimitMB = 0.5
        move.onReconnect = { print($0) }
        try move.run(move.prepare(sources: [nasFolder], destination: returned, move: true, limitMB: 0))
        let result = returned.appendingPathComponent("TransferFolder")
        guard try Data(contentsOf: result.appendingPathComponent("payload.bin")) == payload,
              try Data(contentsOf: result.appendingPathComponent("note.txt")) == text,
              files.fileExists(atPath: result.appendingPathComponent("Empty").path),
              !files.fileExists(atPath: nasFolder.path) else {
            throw TransferError.unsafe("NAS move validation failed. Generated artifacts retained for inspection.")
        }
        print("PASS: NAS-to-local move, bytes verified, NAS originals removed after verification.")
        try files.removeItem(at: remote)
        try files.removeItem(at: local)
        print("PASS: generated NAS and local test folders cleaned up.")
    }
}
