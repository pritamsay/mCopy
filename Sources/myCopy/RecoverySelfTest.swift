import AppKit
import MoverCore

// Run the real app delegate against a generated queue, never the user's queue.
// A half-copied move is left as if its first process had stopped, then startup
// must resume its saved prefix without rewriting that prefix or losing data.
enum RecoverySelfTest {
    static func run() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("mcopy-startup-test-" + UUID().uuidString)
        let source = root.appendingPathComponent("Source")
        let destination = root.appendingPathComponent("Destination")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = source.appendingPathComponent("Generated resume file.bin")
        let contents = Data(repeating: 37, count: 8 * 1_048_576)
        try contents.write(to: original)
        let store = RequestStore(directory: root.appendingPathComponent("Requests"))
        var request = TransferRequest(sources: [original], destination: destination, move: true, token: UUID().uuidString)
        try store.save(request)
        let interrupted = TransferEngine(journal: store.journal(for: request))
        var chunks = 0
        interrupted.afterChunk = {
            chunks += 1
            if chunks == 4 { throw TransferError.stopped }
        }
        do {
            try interrupted.run(interrupted.prepare(sources: [original], destination: destination, move: true, limitMB: 0))
            throw TransferError.unsafe("Expected the generated move to stop halfway.")
        } catch TransferError.stopped { }
        let partials = try files.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        guard partials.count == 1, try Data(contentsOf: partials[0]).count == contents.count / 2,
              try Data(contentsOf: original) == contents else {
            throw TransferError.unsafe("The halfway fixture was not safely retained.")
        }
        request.paused = true
        try store.save(request)
        let app = NSApplication.shared
        var injectedUnexpectedStop = false
        var resumedChunks = 0
        let delegate = AppDelegate(store: store, managesSystemIntegration: false, engineFactory: { journal in
            let engine = TransferEngine(journal: journal)
            engine.afterChunk = {
                resumedChunks += 1
                if !injectedUnexpectedStop {
                    injectedUnexpectedStop = true
                    engine.pause() // No user Cancel: the app must retain/retry.
                }
            }
            return engine
        })
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        let deadline = Date().addingTimeInterval(30)
        var completed = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            guard !completed else { return }
            do {
                if !delegate.running, let progress = delegate.latestProgress, progress.fraction == 1 {
                    guard !files.fileExists(atPath: original.path),
                          try Data(contentsOf: destination.appendingPathComponent(original.lastPathComponent)) == contents,
                          injectedUnexpectedStop, resumedChunks == 4,
                          try store.pending(includePaused: true).isEmpty,
                          delegate.transferPower.assertion == 0, delegate.transferPower.activity == nil else {
                        throw TransferError.unsafe("Startup did not safely finish the generated saved move.")
                    }
                    completed = true
                    timer.invalidate()
                    try files.removeItem(at: root)
                    print("PASS: real app startup resumed a retained half-copied move, retried an unexpected stop without cancellation, wrote only the remaining half, verified its bytes and released sleep prevention.")
                    app.terminate(nil)
                } else if Date() > deadline {
                    throw TransferError.unavailable("Generated startup recovery did not finish in time.")
                }
            } catch {
                fputs("FAIL: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        app.run()
        timer.invalidate()
    }
}
