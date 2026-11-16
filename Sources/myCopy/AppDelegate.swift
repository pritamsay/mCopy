import AppKit
import ServiceManagement
import MoverCore

// Finder supplies the files and destination. Only decisions/errors open a dialog.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let worker = DispatchQueue(label: "local.pritam.mycopy.requests", qos: .utility)
    let store = RequestStore(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mCopy/Requests"))
    var running = false
    var quitting = false
    var engine: TransferEngine?
    var activity: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(receiveURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerLoginItem()
        processNextRequest()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard running else { return .terminateNow }
        quitting = true
        engine?.pause()
        // An installer/uninstaller must also be able to stop a request waiting
        // in a rename/conflict dialog, without requiring a visible app window.
        if let dialog = NSApp.modalWindow {
            NSApp.abortModal()
            dialog.orderOut(nil)
        }
        return .terminateLater
    }

    func registerLoginItem() {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let homeApp = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/myCopy.app").path
        guard path == homeApp || path == "/Applications/myCopy.app" else { return }
        do {
            let status = SMAppService.mainApp.status
            if status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() }
            if SMAppService.mainApp.status == .enabled { NSLog("mCopy: start at login is enabled.") }
            if SMAppService.mainApp.status == .requiresApproval {
                NSLog("mCopy: macOS requires approval in Login Items before automatic login startup is enabled.")
            }
        } catch { NSLog("mCopy: login registration failed: %@", error.localizedDescription) }
    }

    @objc func receiveURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        handleURL(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleURL(url) }
    }

    func handleURL(_ url: URL) {
        guard !quitting, url.scheme == "mycopy", url.host == "paste",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = parts.queryItems ?? []
        guard let token = items.first(where: { $0.name == "token" })?.value,
              token == NSPasteboard.general.string(forType: FinderClipboard.tokenType),
              token != UserDefaults.standard.string(forKey: "lastRequestToken"),
              let path = items.first(where: { $0.name == "destination" })?.value, path.hasPrefix("/") else { return }
        let urls = FinderClipboard.files()
        guard !urls.isEmpty, FinderClipboard.hasSelection() else { return }
        let move = NSPasteboard.general.string(forType: FinderClipboard.operationType) == "move"
        let request = TransferRequest(sources: urls, destination: URL(fileURLWithPath: path), move: move, token: token)
        do {
            try store.save(request)
            UserDefaults.standard.set(token, forKey: "lastRequestToken")
            processNextRequest()
        } catch { showError("mCopy could not queue these files", error) }
    }

    func processNextRequest() {
        guard !running, !quitting else { return }
        do {
            guard let request = try store.pending().first else { return }
            running = true
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Copying and verifying files")
            worker.async { [self] in
                var continueQueue = true
                do { try perform(request) }
                catch {
                    continueQueue = false
                    NSLog("mCopy: request retained: %@", error.localizedDescription)
                    if !DispatchQueue.main.sync(execute: { quitting }) {
                        var retained = request
                        retained.paused = true
                        try? store.save(retained)
                        DispatchQueue.main.sync { showError("mCopy retained this transfer", error) }
                    }
                }
                DispatchQueue.main.async { [self] in
                    running = false
                    engine = nil
                    if let activity { ProcessInfo.processInfo.endActivity(activity) }
                    activity = nil
                    if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
                    else if continueQueue { processNextRequest() }
                }
            }
        } catch { showError("mCopy could not read the transfer queue", error) }
    }

    func makeEngine(_ request: TransferRequest) -> TransferEngine {
        let engine = TransferEngine(journal: store.journal(for: request))
        engine.keepCompletedJournal = true
        engine.onConflict = { [weak self] name, directory in
            DispatchQueue.main.sync { self?.conflict(name, directory: directory, sameFolder: false) ?? Decision(.cancel) }
        }
        engine.onSameFolderConflict = { [weak self] name, directory in
            DispatchQueue.main.sync { self?.conflict(name, directory: directory, sameFolder: true) ?? Decision(.cancel) }
        }
        engine.onReconnect = { NSLog("mCopy: %@", $0) }
        DispatchQueue.main.sync {
            self.engine = engine
            if quitting { engine.pause() }
        }
        return engine
    }

    func perform(_ savedRequest: TransferRequest) throws {
        var request = savedRequest
        while true {
            let engine = makeEngine(request)
            do {
                if request.cancelled {
                    if FileManager.default.fileExists(atPath: engine.journal.path) { try engine.cancelSavedTransfer() }
                } else {
                    let job: Job
                    if FileManager.default.fileExists(atPath: engine.journal.path) {
                        var saved = try engine.load()
                        saved.limitMB = 0
                        job = saved
                    } else {
                        job = try prepare(engine, request: request)
                    }
                    try engine.run(job)
                }
                try store.remove(request)
                // The completed journal remains until the request is removed, so
                // a crash between completion and queue cleanup never repeats a move.
                try? engine.forgetSavedTransfer()
                if request.move, !request.cancelled {
                    DispatchQueue.main.sync { FinderClipboard.clear(ifToken: request.token) }
                }
                return
            } catch {
                if DispatchQueue.main.sync(execute: { quitting }) { throw error }
                if request.cancelled {
                    let network = request.sources.contains { $0.hasPrefix("/Volumes/") } || request.destination.hasPrefix("/Volumes/")
                    if engine.shouldRetry(error, network: network) {
                        try engine.waitForRetry(5)
                        continue
                    }
                    request.paused = true
                    try store.save(request)
                    DispatchQueue.main.sync { showError("mCopy retained files for recovery", error) }
                    return
                }
                let cancel: Bool
                if case TransferError.stopped = error { cancel = true }
                else {
                    cancel = DispatchQueue.main.sync {
                        let alert = NSAlert()
                        alert.messageText = "mCopy could not finish this transfer"
                        alert.informativeText = error.localizedDescription + "\n\nUnverified originals are retained."
                        alert.addButton(withTitle: "Retry")
                        alert.addButton(withTitle: "Cancel Transfer")
                        NSApp.activate(ignoringOtherApps: true)
                        return alert.runModal() == .alertSecondButtonReturn
                    }
                }
                if cancel {
                    request.cancelled = true
                    try store.save(request)
                }
            }
        }
    }

    func prepare(_ engine: TransferEngine, request: TransferRequest) throws -> Job {
        var attempts = 0
        while true {
            try engine.checkCancellation()
            do {
                return try engine.prepare(sources: request.sources.map { URL(fileURLWithPath: $0) },
                    destination: URL(fileURLWithPath: request.destination), move: request.move, limitMB: 0)
            } catch {
                let network = request.sources.contains { $0.hasPrefix("/Volumes/") } || request.destination.hasPrefix("/Volumes/")
                guard engine.shouldRetry(error, network: network) else { throw error }
                attempts += 1
                let delay = min(30.0, 2.0 * pow(2, Double(min(4, attempts - 1))))
                NSLog("mCopy: waiting for NAS before scanning files: %@", error.localizedDescription)
                try engine.waitForRetry(delay)
            }
        }
    }

    func conflict(_ name: String, directory: Bool, sameFolder: Bool) -> Decision {
        if sameFolder { return askName(name, directory: directory) }
        let alert = NSAlert()
        alert.messageText = "\(name) already exists"
        alert.informativeText = directory ? "Replace merges the folders and retains unrelated files." :
            "Replace the existing file, choose a new name, or skip this file."
        for title in ["Replace", "Rename", "Skip", "Cancel"] { alert.addButton(withTitle: title) }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply Replace or Skip to remaining conflicts"
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        switch result {
        case .alertFirstButtonReturn: return Decision(.replace, all: alert.suppressionButton?.state == .on)
        case .alertSecondButtonReturn: return askName(name, directory: directory)
        case .alertThirdButtonReturn: return Decision(.skip, all: alert.suppressionButton?.state == .on)
        default: return Decision(.cancel)
        }
    }

    func askName(_ name: String, directory: Bool) -> Decision {
        let alert = NSAlert()
        alert.messageText = "Rename \(name)"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        let filename = name as NSString
        let ext = directory ? "" : filename.pathExtension
        input.stringValue = ext.isEmpty ? name + " 2" : filename.deletingPathExtension + " 2." + ext
        alert.accessoryView = input
        alert.addButton(withTitle: "Use This Name")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        return alert.runModal() == .alertFirstButtonReturn ? Decision(.rename, newName: input.stringValue) : Decision(.cancel)
    }

    func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
