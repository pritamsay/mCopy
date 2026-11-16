import AppKit
import MoverCore

// Test the packaged progress window with generated files, without touching the
// real transfer queue, clipboard, permissions or login registrations.
final class UISelfTest {
    let window = TransferWindow()
    let lock = NSLock()
    var latest: MoverCore.Progress?
    var timer: Timer?

    static func run() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("mcopy-ui-test-" + UUID().uuidString)
        let source = root.appendingPathComponent("Source")
        let destination = root.appendingPathComponent("Copied")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let first = source.appendingPathComponent("Generated large file.bin")
        let second = source.appendingPathComponent("Generated next file.bin")
        try Data(repeating: 17, count: 24 * 1_048_576).write(to: first)
        try Data(repeating: 29, count: 8 * 1_048_576).write(to: second)
        let test = UISelfTest()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let request = TransferRequest(sources: [first, second], destination: destination, move: true, token: UUID().uuidString)
        test.window.begin(request, queued: 0)
        let engine = TransferEngine(journal: root.appendingPathComponent("state/job.json"))
        test.window.cancelButton.isEnabled = false
        engine.onProgress = { progress in
            test.lock.lock()
            if test.latest == nil || progress.sequence >= test.latest!.sequence { test.latest = progress }
            test.lock.unlock()
        }
        test.timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            test.lock.lock()
            let progress = test.latest
            test.lock.unlock()
            if let progress { test.window.update(progress) }
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                let job = try engine.prepare(sources: [first, second], destination: destination, move: true, limitMB: 4)
                try engine.run(job)
                guard !files.fileExists(atPath: first.path), !files.fileExists(atPath: second.path),
                      try Data(contentsOf: destination.appendingPathComponent(first.lastPathComponent)) == Data(repeating: 17, count: 24 * 1_048_576),
                      try Data(contentsOf: destination.appendingPathComponent(second.lastPathComponent)) == Data(repeating: 29, count: 8 * 1_048_576) else {
                    throw TransferError.unsafe("The UI test move did not verify.")
                }
                DispatchQueue.main.async {
                    print("PASS: packaged status window and verified move; generated files only.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        test.timer?.invalidate()
                        try? files.removeItem(at: root)
                        app.terminate(nil)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    test.timer?.invalidate()
                    test.window.finish("UI test failed: " + error.localizedDescription)
                    fputs("mCopy UI test: \(error.localizedDescription)\n", stderr)
                }
            }
        }
        app.run()
    }
}
