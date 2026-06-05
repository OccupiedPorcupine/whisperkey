import AppKit

/// A small, borderless, non-activating overlay that shows the live transcript
/// and a mic level indicator while dictating. It never becomes key/main, so it
/// can't steal focus from the field we're about to paste into.
final class BubbleWindow {
    var position = "bottom-center"
    var enabled = true

    private let panel: NonActivatingPanel
    private let container = NSView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "Listening…")

    private let width: CGFloat = 440
    private let height: CGFloat = 56
    private let margin: CGFloat = 120

    // EDIT ME: nudge the transcript text vertically. Positive = up, negative =
    // down (points). 0 is mathematically centered; bump a point or two to taste.
    private let textNudge: CGFloat = -3

    init() {
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        buildContent()
    }

    private func buildContent() {
        container.frame = NSRect(x: 0, y: 0, width: width, height: height)
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.frame = NSRect(x: 18, y: height / 2 - 5, width: 10, height: 10)
        container.addSubview(dot)

        // Single line, vertically centered on the dot's line, showing the most
        // recent words (head truncates as the transcript grows).
        let labelHeight: CGFloat = 24
        label.frame = NSRect(x: 44, y: (height - labelHeight) / 2 + textNudge, width: width - 64, height: labelHeight)
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.backgroundColor = .clear
        label.isBordered = false
        container.addSubview(label)

        panel.contentView = container
    }

    // MARK: API (call on main thread)

    func show() {
        guard enabled else { return }
        label.stringValue = "Listening…"
        reposition()
        panel.orderFrontRegardless()
    }

    func update(text: String) {
        guard enabled else { return }
        label.stringValue = text.isEmpty ? "Listening…" : text
    }

    func updateLevel(_ rms: Float) {
        guard enabled, panel.isVisible else { return }
        // Map RMS to a gentle pulse of the dot (10…22 pt).
        let size = CGFloat(min(max(rms * 60, 0), 12)) + 10
        let y = height / 2 - size / 2
        dot.layer?.cornerRadius = size / 2
        dot.frame = NSRect(x: 18, y: y, width: size, height: size)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - width / 2
        let y: CGFloat
        switch position {
        case "top-center": y = frame.maxY - height - margin
        default:           y = frame.minY + margin   // bottom-center
        }
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

/// NSPanel that refuses to become key or main, so showing it never pulls focus
/// away from the user's target text field.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
