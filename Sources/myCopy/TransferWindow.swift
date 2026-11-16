import AppKit
import MoverCore

// This window appears only for a transfer, or when Show Transfer Status is used.
// Closing it hides the window; it never interrupts the transfer.
final class TransferWindow: NSWindowController {
    let heading = NSTextField(labelWithString: "No active transfers")
    let destination = NSTextField(labelWithString: "")
    let progressBar = NSProgressIndicator()
    let percentage = NSTextField(labelWithString: "")
    let counts = NSTextField(labelWithString: "")
    let copying = NSTextField(labelWithString: "")
    let verifying = NSTextField(labelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "Copy or cut files using mCopy in Finder.")
    let cancelButton = NSButton(title: "Cancel Transfer", target: nil, action: nil)
    var onCancel: (() -> Void)?
    var onPermissions: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 350),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "mCopy — Transfer Status"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        for label in [destination, counts, copying, verifying] {
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
        }
        destination.textColor = .secondaryLabelColor
        counts.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        percentage.alignment = .right
        let progressRow = NSStackView(views: [progressBar, percentage])
        progressRow.spacing = 12
        percentage.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let permissions = NSButton(title: "Permissions…", target: self, action: #selector(permissionsClicked))
        let hide = NSButton(title: "Hide", target: self, action: #selector(hideClicked))
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.isEnabled = false
        let spacer = NSView()
        let buttons = NSStackView(views: [permissions, spacer, hide, cancelButton])
        buttons.spacing = 10
        let stack = NSStackView(views: [heading, destination, progressRow, counts, copying, verifying, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        for view in [heading, destination, progressRow, counts, copying, verifying, status, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func begin(_ request: TransferRequest, queued: Int) {
        heading.stringValue = request.move ? "Moving files" : "Copying files"
        destination.stringValue = "To: " + request.destination
        copying.stringValue = "Copy: Preparing files…"
        verifying.stringValue = "Verification: Waiting for copied files"
        counts.stringValue = queued > 0 ? "\(queued) more transfer(s) queued" : "Scanning files…"
        percentage.stringValue = ""
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        cancelButton.isEnabled = false
        status.stringValue = "Original files are kept until their destination copies verify."
        show()
    }

    func update(_ progress: MoverCore.Progress) {
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.doubleValue = progress.fraction * 100
        percentage.stringValue = "\(Int(progress.fraction * 100))%"
        let copied = ByteCountFormatter.string(fromByteCount: progress.copiedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
        counts.stringValue = "\(copied) / \(total) processed · \(progress.completedFiles) / \(progress.totalFiles) files finished"
        copying.stringValue = "Copy: " + (progress.copyingFile.isEmpty ? "Waiting / finished" : progress.copyingFile)
        verifying.stringValue = "Verification: " + (progress.verifyingFile.isEmpty ? "Waiting / finished" : progress.verifyingFile)
        status.stringValue = progress.fraction == 1 ? progress.message : "Copying and checksum verification run together."
        if progress.fraction == 1 { finish(progress.message) }
    }

    func waiting(_ message: String) { status.stringValue = message }

    func finish(_ message: String) {
        heading.stringValue = message.hasPrefix("Transfer complete") ? "Transfer complete" : "Transfer stopped"
        status.stringValue = message
        cancelButton.isEnabled = false
        progressBar.stopAnimation(nil)
    }

    func show() { window?.orderFrontRegardless() }
    @objc func hideClicked() { window?.orderOut(nil) }
    @objc func cancelClicked() { onCancel?() }
    @objc func permissionsClicked() { onPermissions?() }
}
