import AppKit

// The Dock remains useful when the always-on-top window is minimized.
final class TransferDock {
    let view = TransferDockView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))

    func start() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        view.autoresizingMask = [.width, .height]
        view.frame = NSRect(origin: .zero, size: NSApp.dockTile.size)
        NSApp.dockTile.contentView = view
        update(fraction: 0, paused: false)
    }

    func update(fraction: Double, paused: Bool) {
        view.fraction = min(1, max(0, fraction))
        view.paused = paused
        view.needsDisplay = true
        NSApp.dockTile.display()
    }

    func hide() {
        NSApp.dockTile.contentView = nil
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }
}

final class TransferDockView: NSView {
    var fraction = 0.0
    var paused = false

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let scale = NSAffineTransform()
        scale.scaleX(by: bounds.width / 128, yBy: bounds.height / 128)
        scale.concat()
        NSApp.applicationIconImage.draw(in: NSRect(x: 4, y: 4, width: 120, height: 120))
        let track = NSRect(x: 8, y: 8, width: 112, height: 14)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: track, xRadius: 7, yRadius: 7).fill()
        let fill = NSRect(x: 10, y: 10, width: 108 * fraction, height: 10)
        (paused ? NSColor.systemOrange : NSColor.systemBlue).setFill()
        if fill.width > 0 {
            let radius = min(5, fill.width / 2)
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let label = paused ? "Paused" : "\(Int(fraction * 100))%"
        let badge = NSRect(x: 30, y: 26, width: 68, height: 23)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
        (label as NSString).draw(in: badge.insetBy(dx: 1, dy: 2), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: paragraph
        ])
    }
}
