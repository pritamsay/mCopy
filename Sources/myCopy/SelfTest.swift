import Foundation
import MoverCore

enum SelfTest {
    static func run() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("mcopy-self-test-" + UUID().uuidString)
        let sourceFolder = root.appendingPathComponent("Source")
        let copyFolder = root.appendingPathComponent("Copied")
        let moveFolder = root.appendingPathComponent("Moved")
        for folder in [sourceFolder, copyFolder, moveFolder] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let original = sourceFolder.appendingPathComponent("sample.txt")
        let copied = copyFolder.appendingPathComponent("sample.txt")
        let moved = moveFolder.appendingPathComponent("sample.txt")
        let contents = Data("mCopy packaged transfer check.\n".utf8)
        try contents.write(to: original)
        let copy = TransferEngine(journal: root.appendingPathComponent("copy.json"))
        try copy.run(copy.prepare(sources: [original], destination: copyFolder, move: false, limitMB: 0))
        guard try Data(contentsOf: copied) == contents, files.fileExists(atPath: original.path) else {
            throw TransferError.unsafe("The packaged copy check failed. Generated test files were retained.")
        }
        let move = TransferEngine(journal: root.appendingPathComponent("move.json"))
        try move.run(move.prepare(sources: [copied], destination: moveFolder, move: true, limitMB: 0))
        guard try Data(contentsOf: moved) == contents, !files.fileExists(atPath: copied.path),
              files.fileExists(atPath: original.path) else {
            throw TransferError.unsafe("The packaged move check failed. Generated test files were retained.")
        }
        try files.removeItem(at: root)
        print("PASS: packaged app copy/move checks passed; generated files cleaned up.")
    }
}
