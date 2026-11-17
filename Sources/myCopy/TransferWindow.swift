import AppKit
import MoverCore

final class TransferStatusWindow: NSWindow {
    override func miniaturize(_ sender: Any?) {
        // Floating utility windows are not normally managed by the Dock.
        // Lower the level only when the user asks to minimize.
        level = .normal
        collectionBehavior = [.managed]
        if CommandLine.arguments.contains("--ui-self-test") {
            print("Minimize request: allowed=\(isMiniaturizable), style=\(styleMask.rawValue), button=\(standardWindowButton(.miniaturizeButton)?.isEnabled ?? false), policy=\(NSApp.activationPolicy().rawValue), active=\(NSApp.isActive)")
        }
        super.miniaturize(sender)
    }
}

// This window appears automatically for a transfer.
// Closing it hides the window; it never interrupts the transfer.
final class TransferWindow: NSWindowController, NSWindowDelegate {
    let heading = NSTextField(labelWithString: "No active transfers")
    let destination = NSTextField(labelWithString: "")
    let progressBar = NSProgressIndicator()
    let percentage = NSTextField(labelWithString: "")
    let counts = NSTextField(labelWithString: "")
    let speed = NSTextField(labelWithString: "—")
    let copying = NSTextField(labelWithString: "")
    let verifying = NSTextField(labelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "Copy or cut files using mCopy in Finder.")
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    let internetPriority = NSButton(checkboxWithTitle: "Internet priority", target: nil, action: nil)
    var paused = false
    var operationTitle = "Copying files"
    var onCancel: (() -> Void)?
    var onPause: (() -> Void)?
    var onInternetPriority: ((Bool) -> Void)?
    var speedMeter = TransferSpeed()
    var lastWrittenBytes: Int64 = 0
    let dock = TransferDock()
    var transferActive = false
    var lastFraction = 0.0
    var presentationID = 0
    var userMinimized = false
    var copyPhaseFinished = false

    init() {
        let window = TransferStatusWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "mCopy — Transfer Status"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .managed, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.contentMinSize = NSSize(width: 420, height: 230)
        window.contentMaxSize = NSSize(width: 420, height: 230)
        super.init(window: window)
        window.delegate = self
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        for label in [destination, counts, copying, verifying] {
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingMiddle
        }
        destination.textColor = .secondaryLabelColor
        counts.textColor = .secondaryLabelColor
        for label in [heading, destination, counts, copying, verifying, status] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byTruncatingTail
        speed.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        speed.alignment = .right
        speed.toolTip = "Bytes written per second, averaged over about two seconds."
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        percentage.alignment = .right
        let headingRow = NSStackView(views: [heading, percentage])
        headingRow.spacing = 8
        headingRow.distribution = .fill
        percentage.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let statistics = NSStackView(views: [counts, speed])
        statistics.spacing = 8
        statistics.distribution = .fill
        speed.widthAnchor.constraint(equalToConstant: 102).isActive = true
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        pauseButton.isEnabled = false
        internetPriority.target = self
        internetPriority.action = #selector(internetPriorityClicked)
        internetPriority.font = .systemFont(ofSize: 11)
        internetPriority.state = .on
        internetPriority.isHidden = true
        internetPriority.toolTip = "NAS traffic yields dynamically to other Wi-Fi traffic. Idle internet leaves NAS unrestricted."
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.isEnabled = false
        let spacer = NSView()
        let buttons = NSStackView(views: [internetPriority, spacer, pauseButton, cancelButton])
        buttons.spacing = 10
        let stack = NSStackView(views: [headingRow, destination, progressBar, statistics, copying, verifying, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        for view in [headingRow, destination, progressBar, statistics, copying, verifying, status, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 396),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -12),
            status.heightAnchor.constraint(equalToConstant: 28)
        ])
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func begin(_ request: TransferRequest, queued: Int) {
        transferActive = true
        lastFraction = 0
        copyPhaseFinished = false
        if !userMinimized && window?.isMiniaturized != true { window?.level = .floating }
        dock.start()
        operationTitle = request.move ? "Moving files" : "Copying files"
        heading.stringValue = operationTitle
        paused = false
        pauseButton.title = "Pause"
        pauseButton.isEnabled = false
        destination.stringValue = "To: " + request.destination
        destination.toolTip = request.destination
        copying.stringValue = "Copy: Preparing files…"
        verifying.stringValue = "Verification: Waiting for copied files"
        counts.stringValue = queued > 0 ? "\(queued) more transfer(s) queued" : "Scanning files…"
        percentage.stringValue = ""
        lastWrittenBytes = 0
        speedMeter.reset()
        _ = speedMeter.sample(bytes: 0, at: ProcessInfo.processInfo.systemUptime)
        speed.stringValue = "0 B/s"
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.doubleValue = 0
        cancelButton.isEnabled = false
        status.stringValue = "Original files are kept until their destination copies verify."
        // Respect a user's minimize choice across queued transfer requests.
        if !userMinimized && window?.isMiniaturized != true { show() }
    }

    func update(_ progress: MoverCore.Progress) {
        lastFraction = progress.fraction
        copyPhaseFinished = progress.copyingFinished
        dock.update(fraction: progress.fraction, paused: paused)
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.doubleValue = progress.fraction * 100
        percentage.stringValue = "\(Int(progress.fraction * 100))%"
        let copied = ByteCountFormatter.string(fromByteCount: progress.copiedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
        counts.stringValue = "\(copied) / \(total) · \(progress.completedFiles)/\(progress.totalFiles) files"
        counts.toolTip = counts.stringValue
        lastWrittenBytes = progress.writtenBytes
        let rate = speedMeter.sample(bytes: progress.writtenBytes, at: ProcessInfo.processInfo.systemUptime)
        speed.stringValue = paused ? "Paused" : ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s"
        copying.stringValue = "Copy: " + (progress.copyingFinished ? "Finished" :
            (progress.copyingFile.isEmpty ? "Preparing / waiting" : progress.copyingFile))
        verifying.stringValue = "Verification: " + (progress.verifyingFile.isEmpty ? "Waiting / finished" : progress.verifyingFile)
        copying.toolTip = copying.stringValue
        verifying.toolTip = verifying.stringValue
        if progress.fraction == 1 { status.stringValue = progress.message }
        else if progress.copyingFinished { status.stringValue = "Copy phase finished. Verifying remaining files…" }
        else { status.stringValue = "Copying and checksum verification run together." }
        if paused { showPausedMessage() }
        if progress.fraction == 1 { finish(progress.message) }
    }

    func waiting(_ message: String) {
        status.toolTip = message
        if paused { showPausedMessage() }
        else { status.stringValue = message }
    }

    func setPaused(_ value: Bool) {
        paused = value
        pauseButton.title = value ? "Resume" : "Pause"
        heading.stringValue = value ? "Transfer paused" : operationTitle
        speedMeter.reset()
        _ = speedMeter.sample(bytes: lastWrittenBytes, at: ProcessInfo.processInfo.systemUptime)
        speed.stringValue = value ? "Paused" : "0 B/s"
        dock.update(fraction: lastFraction, paused: value)
        if value { showPausedMessage() }
        else { status.stringValue = "Resuming copying and verification…" }
    }

    func showPausedMessage() {
        status.stringValue = "Paused. In-flight disk operations may finish first. Click Resume to continue."
    }

    func finish(_ message: String) {
        transferActive = false
        window?.level = .normal
        heading.stringValue = message.hasPrefix("Transfer complete") ? "Transfer complete" : "Transfer stopped"
        status.stringValue = message
        cancelButton.isEnabled = false
        pauseButton.isEnabled = false
        paused = false
        pauseButton.title = "Pause"
        speed.stringValue = "—"
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        dock.update(fraction: lastFraction, paused: false)
        if window?.isVisible != true && window?.isMiniaturized != true { dock.hide() }
    }

    func windowWillClose(_ notification: Notification) {
        presentationID += 1
        if !transferActive { dock.hide() }
    }

    func windowWillMiniaturize(_ notification: Notification) {
        userMinimized = true
        presentationID += 1
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        userMinimized = false
        window?.collectionBehavior = [.canJoinAllSpaces, .managed, .fullScreenAuxiliary]
        window?.level = transferActive ? .floating : .normal
    }

    func show() {
        guard let window else { return }
        userMinimized = false
        presentationID += 1
        let requestedPresentation = presentationID
        present(window)
        // Dock activation-policy changes and app hiding are applied by macOS
        // asynchronously. Retry after that transition, unless the user closed
        // or minimized the window in the meantime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.presentationID == requestedPresentation,
                  !self.userMinimized, !window.isMiniaturized else { return }
            self.present(window)
        }
    }

    func present(_ window: NSWindow) {
        // Startup runs in the background. Ordering an inactive app's window
        // alone can leave it behind Finder, minimized, or on a different Space.
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.collectionBehavior = [.canJoinAllSpaces, .managed, .fullScreenAuxiliary]
        window.level = transferActive ? .floating : .normal
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
    @objc func cancelClicked() { onCancel?() }
    @objc func pauseClicked() { onPause?() }
    @objc func internetPriorityClicked() { onInternetPriority?(internetPriority.state == .on) }

    func showInternetPriority(_ status: InternetPriorityStatus, enabled: Bool) {
        guard !internetPriority.isHidden, enabled, transferActive, !paused else { return }
        if !status.available {
            internetPriority.toolTip = "Passive Wi-Fi monitoring is starting or unavailable. NAS is currently unrestricted."
        } else if status.active && status.limitMB > 0 {
            let budget = ByteCountFormatter.string(fromByteCount: Int64(status.limitMB * 1_000_000), countStyle: .file)
            self.status.stringValue = copyPhaseFinished ? "Copy done; verifying. Internet priority (~\(budget)/s)." :
                "Internet active · NAS yielding dynamically (~\(budget)/s)."
            internetPriority.toolTip = self.status.stringValue
        } else {
            internetPriority.toolTip = "Internet idle or no shared Wi-Fi NAS connection. NAS transfer is unrestricted."
        }
    }
}
