import AppKit
import MoverCore

// Test the packaged progress window with generated files, without touching the
// real transfer queue, clipboard, permissions or login registrations.
final class UISelfTest {
    let window = TransferWindow()
    let lock = NSLock()
    var latest: MoverCore.Progress?
    var timer: Timer?
    var startedMinimizeCheck = false
    var passedMinimizeCheck = false

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
        test.window.internetPriority.isHidden = false
        let engine = TransferEngine(journal: root.appendingPathComponent("state/job.json"))
        let minimizeConfirmed = DispatchSemaphore(value: 0)
        var waitedForMinimize = false
        engine.onVerificationStarted = { _ in
            if !waitedForMinimize {
                waitedForMinimize = true
                guard minimizeConfirmed.wait(timeout: .now() + 50) == .success else {
                    throw TransferError.unsafe("Minimize the generated test window to exercise its Dock progress.")
                }
            }
        }
        test.window.cancelButton.isEnabled = false
        test.window.pauseButton.isEnabled = true
        test.window.onPause = {
            let paused = !test.window.paused
            if paused { engine.suspend() }
            else { engine.resume() }
            test.window.setPaused(paused)
        }
        // Check hidden startup without a control tool activating the app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            app.hide(nil)
            test.window.begin(request, queued: 0)
            test.window.pauseButton.isEnabled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let window = test.window.window {
                    print("UI state: visible=\(window.isVisible), mini=\(window.isMiniaturized), hidden=\(app.isHidden), space=\(window.isOnActiveSpace), level=\(window.level.rawValue), size=\(window.contentView?.bounds.size ?? .zero)")
                }
                guard let window = test.window.window, window.isVisible,
                      !window.isMiniaturized, !app.isHidden, window.isOnActiveSpace,
                      window.level == .floating,
                      let content = window.contentView, abs(content.bounds.width - 420) < 1,
                      abs(content.bounds.height - 230) < 1 else {
                    fputs("FAIL: transfer status did not appear above other windows.\n", stderr)
                    exit(1)
                }
                print("PASS: 420×230 status restored from hidden startup at floating window level.")
            }
        }
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
            // The operator clicks the native minimize button. Check that the
            // next queued request keeps it down, with live progress in the Dock.
            if test.window.window?.isMiniaturized == true, !test.startedMinimizeCheck, let progress, progress.fraction > 0 {
                test.startedMinimizeCheck = true
                test.window.begin(request, queued: 0)
                test.window.pauseButton.isEnabled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard test.window.window?.isMiniaturized == true,
                          NSApp.activationPolicy() == .regular,
                          NSApp.dockTile.contentView === test.window.dock.view,
                          test.window.dock.view.fraction > 0 else {
                        fputs("FAIL: minimized status or live Dock progress was lost.\n", stderr)
                        exit(1)
                    }
                    test.passedMinimizeCheck = true
                    minimizeConfirmed.signal()
                    print("PASS: minimized window stays minimized while the Dock progress updates.")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { test.window.show() }
            }
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
                    guard test.passedMinimizeCheck else {
                        fputs("FAIL: the active-window minimize check was not exercised.\n", stderr)
                        exit(1)
                    }
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
