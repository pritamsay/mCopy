import Foundation

// Copying and verification run together. Keep their progress separate so an
// earlier file finishing verification cannot move the overall bar backwards.
final class TransferProgress {
    let lock = NSLock()
    var sizes: [Int64] = []
    var directories: [Bool] = []
    var portions: [Double] = []
    var copyingFile = ""
    var verifyingFile = ""
    var copyIndex: Int?
    var verifyIndex: Int?
    var totalBytes: Int64 = 0
    var copiedBytes: Int64 = 0
    var totalWeight = 0.0
    var finishedWeight = 0.0
    var completedFiles = 0
    var totalFiles = 0
    var sequence: UInt64 = 0

    func begin(_ job: Job) {
        lock.lock()
        defer { lock.unlock() }
        sizes = job.entries.map(\.size)
        directories = job.entries.map(\.directory)
        portions = job.entries.map { entry in
            switch entry.state {
            case "done", "skipped": return 1
            case "verifying", "publishing", "committed": return 0.8
            default: return 0
            }
        }
        copyingFile = ""
        verifyingFile = ""
        copyIndex = nil
        verifyIndex = nil
        totalBytes = sizes.reduce(0, +)
        copiedBytes = portions.indices.reduce(Int64(0)) { $0 + Int64(Double(sizes[$1]) * min(1, portions[$1] / 0.8)) }
        totalWeight = sizes.reduce(0.0) { $0 + Double(max(1, $1)) }
        finishedWeight = portions.indices.reduce(0.0) { $0 + portions[$1] * Double(max(1, sizes[$1])) }
        completedFiles = portions.indices.filter { !directories[$0] && portions[$0] >= 1 }.count
        totalFiles = directories.filter { !$0 }.count
        sequence = 0
    }

    func update(_ message: String, index: Int, portion: Double, lane: String = "") -> Progress {
        lock.lock()
        defer { lock.unlock() }
        guard portions.indices.contains(index) else { return Progress(message: message, fraction: 0) }
        let previous = portions[index]
        portions[index] = max(previous, min(1, max(0, portion)))
        finishedWeight += (portions[index] - previous) * Double(max(1, sizes[index]))
        copiedBytes += Int64(Double(sizes[index]) * min(1, portions[index] / 0.8)) -
            Int64(Double(sizes[index]) * min(1, previous / 0.8))
        if previous < 1, portions[index] >= 1, !directories[index] { completedFiles += 1 }
        sequence += 1
        if lane == "copy" { copyingFile = message; copyIndex = index }
        if lane == "verify" { verifyingFile = message; verifyIndex = index }
        if portion >= 0.8, copyIndex == index { copyingFile = ""; copyIndex = nil }
        if portion >= 1, verifyIndex == index { verifyingFile = ""; verifyIndex = nil }
        // Give empty files/folders a small weight too, so a directory-only job
        // has meaningful progress and 100% still means all entries are finished.
        return Progress(message: message, fraction: min(0.999, totalWeight == 0 ? 0 : finishedWeight / totalWeight),
            copiedBytes: copiedBytes, totalBytes: totalBytes, completedFiles: completedFiles,
            totalFiles: totalFiles, copyingFile: copyingFile, verifyingFile: verifyingFile, sequence: sequence)
    }
}
