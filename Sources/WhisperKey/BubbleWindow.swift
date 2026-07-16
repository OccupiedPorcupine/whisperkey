import AppKit

/// The dictation session's visual state — each gets its own accent color and
/// placeholder so you always know what the app is doing at a glance.
enum BubbleState {
    case listening      // capturing audio (live waveform follows your voice)
    case live           // live-streaming transcription into a note/textbox
    case transcribing   // batch engine running after stop
    case polishing      // on-device LLM cleanup pass
    case speaking       // TTS reading a selection aloud

    var accent: NSColor {
        switch self {
        case .listening:    return .systemRed
        case .live:         return .systemGreen
        case .transcribing: return .systemOrange
        case .polishing:    return .systemPurple
        case .speaking:     return .systemTeal
        }
    }

    var placeholder: String {
        switch self {
        case .listening:    return "Listening…"
        case .live:         return "Live transcribing…"
        case .transcribing: return "Transcribing…"
        case .polishing:    return "Polishing…"
        case .speaking:     return "Speaking…"
        }
    }

    /// States with real mic input drive the waveform from RMS; the rest shimmer.
    var hasLiveAudio: Bool {
        self == .listening || self == .live
    }
}

/// A small, borderless, non-activating overlay pill (Wispr Flow-style) showing a
/// live scrolling waveform, the in-progress transcript, and the active engine.
/// It never becomes key/main, so it can't steal focus from the field we're about
/// to paste into. Esc cancels whatever it is showing.
final class BubbleWindow {
    var position = "notch"
    var enabled = true

    /// Tap on the engine badge → cycle to the next engine.
    var onEngineTap: (() -> Void)?

    private let panel: NonActivatingPanel
    private let container = NSVisualEffectView()
    private let waveform = WaveformView(frame: .zero)
    private let label = NSTextField(labelWithString: "Listening…")
    private let hint = NSTextField(labelWithString: "esc")
    private let badge = EngineBadgeView(frame: .zero)
    // Solid-black backdrop used only in "notch" mode: a subview layered below the
    // content (waveform/label/badge) but above the frosted material, so the pill
    // reads as an opaque black slab that merges with the MacBook's notch/bezel.
    private let notchBackdrop = NSView()

    private let badgeWidth: CGFloat = 74
    private let badgeHeight: CGFloat = 22

    // Floating-pill metrics (top-center / bottom-center).
    private let width: CGFloat = 460
    private let height: CGFloat = 56
    private let margin: CGFloat = 120
    private let waveWidth: CGFloat = 64

    // Notch-mode metrics: the slab is exactly notch-height and grows sideways
    // out of the notch, so it reads as the notch itself widening. Only a
    // waveform (left wing) and the session uptime (right wing) are shown.
    private let notchWing: CGFloat = 120           // content area added each side
    private let notchFallbackHeight: CGFloat = 34  // slab height on notchless displays
    private let notchFallbackWidth: CGFloat = 200  // pretend-notch width on notchless displays
    private let notchCornerRadius: CGFloat = 12

    // Session uptime, notch mode's only text.
    private let uptimeLabel = NSTextField(labelWithString: "0:00")
    private var uptimeTimer: Timer?
    private var sessionStart = Date()

    // EDIT ME: nudge the transcript text vertically. Positive = up, negative =
    // down (points). 0 is mathematically centered; bump a point or two to taste.
    private let textNudge: CGFloat = -3

    private(set) var state: BubbleState = .listening

    /// Bumped by every show(); hide()'s fade-out completion only tears the panel
    /// down if the token still matches. Without this, a show() during the 0.15 s
    /// fade-out (stop dictation → immediately re-trigger) early-returns on
    /// `isVisible` and the stale completion then hides the bubble mid-recording.
    private var hideToken = 0

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
        // Accept clicks (for the engine badge) — the panel still never becomes
        // key/main, so it won't steal focus from the field we paste into.
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        buildContent()
    }

    private func buildContent() {
        // Frosted-glass pill: system material blur with a dark tint, like the
        // native dictation HUD, instead of a flat black rectangle.
        container.frame = NSRect(x: 0, y: 0, width: width, height: height)
        container.material = .hudWindow
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = height / 2
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // Black backdrop for notch mode. Added first so it sits below every
        // content subview, hiding the blur without covering the waveform/label/
        // badge. Tracks the container so it stays covering during the notch's
        // expand/shrink window animation. Hidden in the frosted positions.
        notchBackdrop.wantsLayer = true
        notchBackdrop.frame = container.bounds
        notchBackdrop.autoresizingMask = [.width, .height]
        notchBackdrop.isHidden = true
        container.addSubview(notchBackdrop)

        // Styling only here — frames and per-mode visibility live in
        // layoutPillContent / layoutNotchContent, because the two modes show
        // different content (pill: waveform+transcript+badge+esc; notch:
        // waveform+uptime).
        container.addSubview(waveform)

        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.backgroundColor = .clear
        label.isBordered = false
        container.addSubview(label)

        badge.onTap = { [weak self] in self?.onEngineTap?() }
        container.addSubview(badge)

        hint.font = .systemFont(ofSize: 9, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.45)
        hint.alignment = .center
        hint.backgroundColor = .clear
        hint.isBordered = false
        hint.stringValue = "esc to cancel"
        container.addSubview(hint)

        uptimeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        uptimeLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        uptimeLabel.alignment = .center
        uptimeLabel.backgroundColor = .clear
        uptimeLabel.isBordered = false
        container.addSubview(uptimeLabel)

        // Content views need layers so their alpha can animate (the notch
        // reveal fades them in after the slab finishes expanding).
        for view in [waveform, label, badge, hint, uptimeLabel] { view.wantsLayer = true }

        layoutPillContent()
        panel.contentView = container
    }

    // MARK: Per-mode layout

    /// Floating pill: waveform | transcript | engine badge + esc hint.
    private func layoutPillContent() {
        waveform.frame = NSRect(x: 20, y: 10, width: waveWidth, height: height - 20)

        let labelHeight: CGFloat = 24
        let labelLeft = 20 + waveWidth + 12
        let labelRight = width - badgeWidth - 12 - 8   // badge + its right margin + gap
        label.frame = NSRect(x: labelLeft, y: (height - labelHeight) / 2 + textNudge,
                             width: labelRight - labelLeft, height: labelHeight)
        badge.frame = NSRect(x: width - badgeWidth - 12, y: (height - badgeHeight) / 2 + 6,
                             width: badgeWidth, height: badgeHeight)
        hint.frame = NSRect(x: width - badgeWidth - 12, y: (height - badgeHeight) / 2 - 10,
                            width: badgeWidth, height: 12)

        label.isHidden = false
        badge.isHidden = false
        hint.isHidden = false
        uptimeLabel.isHidden = true
    }

    /// Notch slab: waveform in the left wing, uptime in the right wing — the
    /// middle stays empty because the physical notch covers it.
    private func layoutNotchContent(_ geo: NotchGeometry) {
        let size = geo.final.size
        let padX: CGFloat = 18
        let padY: CGFloat = 8
        waveform.frame = NSRect(x: padX, y: padY,
                                width: geo.wing - padX * 2, height: size.height - padY * 2)
        let uptimeHeight: CGFloat = 16
        uptimeLabel.frame = NSRect(x: size.width - geo.wing + padX,
                                   y: (size.height - uptimeHeight) / 2,
                                   width: geo.wing - padX * 2, height: uptimeHeight)

        label.isHidden = true
        badge.isHidden = true
        hint.isHidden = true
        uptimeLabel.isHidden = false
    }

    /// Update the engine badge text (e.g. "Apple", "Whisper", "Parakeet").
    func setEngine(_ badgeText: String) {
        badge.setTitle(badgeText)
    }

    // MARK: API (call on main thread)

    func show(state: BubbleState = .listening) {
        guard enabled else { return }
        hideToken &+= 1                 // cancel any in-flight hide teardown
        setState(state)
        // Already on screen (restyle) — possibly mid-fade-out: bring it back.
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                panel.animator().alphaValue = 1
                if position == "notch", let geo = notchGeometry() {
                    panel.animator().setFrame(geo.final, display: true)
                }
                setContentAlpha(1, animated: true)
            }
            waveform.start()            // hide() stopped it; restart is idempotent
            startUptime()
            return
        }
        label.stringValue = state.placeholder
        waveform.start()
        startUptime()
        applyPositionStyle()

        if position == "notch", let geo = notchGeometry() {
            // The notch "expands": the black slab starts at the notch's own
            // rect, grows horizontally to its final width (never downward — it
            // stays exactly notch-height), then the content fades in.
            layoutNotchContent(geo)
            setContentAlpha(0, animated: false)
            panel.alphaValue = 1
            panel.setFrame(geo.seed, display: false)
            panel.orderFrontRegardless()
            let token = hideToken
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(geo.final, display: true)
            }, completionHandler: { [weak self] in
                guard let self, self.hideToken == token else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    self.setContentAlpha(1, animated: true)
                }
            })
        } else {
            // Floating pill: fade + rise from its anchoring edge.
            layoutPillContent()
            setContentAlpha(1, animated: false)
            repositionFloating()
            panel.alphaValue = 0
            var frame = panel.frame
            frame.origin.y -= 8
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                frame.origin.y += 8
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    func setState(_ new: BubbleState) {
        state = new
        waveform.color = new.accent
        // Batch phases have no live audio — let the waveform idle-shimmer.
        waveform.indeterminate = !new.hasLiveAudio
        if label.stringValue.isEmpty { label.stringValue = new.placeholder }
    }

    func update(text: String) {
        guard enabled else { return }
        label.stringValue = text.isEmpty ? state.placeholder : text
    }

    func updateLevel(_ rms: Float) {
        guard enabled, panel.isVisible else { return }
        waveform.push(rms)
    }

    func hide() {
        let token = hideToken
        waveform.stop()
        stopUptime()
        if position == "notch", panel.isVisible, let geo = notchGeometry() {
            // Reverse of the reveal: content fades, the slab shrinks back into
            // the notch and disappears.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                setContentAlpha(0, animated: true)
                panel.animator().setFrame(geo.seed, display: true)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.hideToken == token else { return }  // superseded by a show()
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.setContentAlpha(1, animated: false)
                self.label.stringValue = ""
            })
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.hideToken == token else { return }  // superseded by a show()
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.label.stringValue = ""
            })
        }
    }

    // MARK: Notch geometry

    private struct NotchGeometry {
        let seed: NSRect    // the notch's own rect — where the reveal starts
        let final: NSRect   // the expanded slab
        let wing: CGFloat   // content area each side of the notch
    }

    /// Measure the physical notch from the screen: `safeAreaInsets.top` is its
    /// height; the auxiliary top areas flank it, so full-width minus both gives
    /// its width. On notchless displays a pretend notch is used so the mode
    /// still degrades to a compact top-center slab.
    private func notchGeometry() -> NotchGeometry? {
        guard let screen = targetScreen() else { return nil }
        let full = screen.frame
        let inset = screen.safeAreaInsets.top
        let slabHeight = inset > 0 ? inset : notchFallbackHeight
        var notchWidth = notchFallbackWidth
        if let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            notchWidth = full.width - left - right
        }
        let finalWidth = notchWidth + notchWing * 2
        let top = full.maxY - slabHeight
        return NotchGeometry(
            seed: NSRect(x: full.midX - notchWidth / 2, y: top, width: notchWidth, height: slabHeight),
            final: NSRect(x: full.midX - finalWidth / 2, y: top, width: finalWidth, height: slabHeight),
            wing: notchWing
        )
    }

    /// Prefer the built-in display that actually has a notch (non-zero top safe
    /// area); fall back to the main screen on notchless Macs and external displays.
    private func targetScreen() -> NSScreen? {
        if position == "notch",
           let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main
    }

    private func repositionFloating() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - width / 2
        let y = (position == "top-center") ? frame.maxY - height - margin
                                           : frame.minY + margin   // bottom-center
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    /// Corner rounding, border, backdrop, and window level for the current
    /// position. Notch mode: flush top (square top corners), gently rounded
    /// bottom corners like the notch's own, solid black, above the menu bar.
    /// The floating positions keep the fully-rounded frosted pill.
    private func applyPositionStyle() {
        guard let layer = container.layer else { return }
        if position == "notch" {
            layer.cornerRadius = notchCornerRadius
            layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            layer.borderWidth = 0
            if let back = notchBackdrop.layer {
                back.cornerRadius = notchCornerRadius
                back.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                back.backgroundColor = NSColor.black.cgColor
            }
            notchBackdrop.frame = container.bounds
            notchBackdrop.isHidden = false
            panel.level = .statusBar
        } else {
            layer.cornerRadius = height / 2
            layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                   .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            layer.borderWidth = 1
            notchBackdrop.isHidden = true
            panel.level = .floating
        }
    }

    // MARK: Uptime + content fade helpers

    /// Tick the "how long have I been recording" readout once a second. Only
    /// notch mode shows it; no-op elsewhere. Idempotent, so the mid-hide
    /// re-show path can call it safely.
    private func startUptime() {
        guard position == "notch", uptimeTimer == nil else { return }
        sessionStart = Date()
        uptimeLabel.stringValue = "0:00"
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let s = Int(Date().timeIntervalSince(self.sessionStart))
            self.uptimeLabel.stringValue = String(format: "%d:%02d", s / 60, s % 60)
        }
        RunLoop.main.add(t, forMode: .common)
        uptimeTimer = t
    }

    private func stopUptime() {
        uptimeTimer?.invalidate()
        uptimeTimer = nil
    }

    /// Fade all content in/out together (the black slab itself is animated
    /// separately via the window frame/alpha).
    private func setContentAlpha(_ alpha: CGFloat, animated: Bool) {
        for view in [waveform, label, badge, hint, uptimeLabel] {
            (animated ? view.animator() : view).alphaValue = alpha
        }
    }
}

/// NSPanel that refuses to become key or main, so showing it never pulls focus
/// away from the user's target text field.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A scrolling live waveform: a row of rounded bars whose heights follow the
/// recent mic level, drifting left as new audio arrives — the same visual
/// language as Wispr Flow / Siri, rendered with plain CALayers.
///
/// In `indeterminate` mode (transcribing/polishing/speaking, when there's no
/// mic input) the bars ripple with a gentle traveling sine wave instead.
final class WaveformView: NSView {
    var color: NSColor = .systemRed {
        didSet { for bar in bars { bar.backgroundColor = color.cgColor } }
    }
    var indeterminate = false

    private let barCount = 16
    private let barWidth: CGFloat = 2.5
    private var bars: [CALayer] = []
    private var levels: [Float]
    private var latest: Float = 0
    private var phase: CGFloat = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        levels = Array(repeating: 0, count: barCount)
        super.init(frame: frameRect)
        wantsLayer = true
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = color.cgColor
            bar.cornerRadius = barWidth / 2
            // Height changes every tick; implicit 0.25 s animations would smear.
            bar.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Feed the current mic RMS (0…~0.3 speech range).
    func push(_ rms: Float) {
        latest = rms
    }

    func start() {
        stop()
        levels = Array(repeating: 0, count: barCount)
        latest = 0
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if indeterminate {
            phase += 0.25
        } else {
            // Scroll: drop the oldest level, append the newest (with a touch of
            // decay so short gaps between words don't flatline instantly).
            levels.removeFirst()
            levels.append(latest)
            latest *= 0.72
        }
        layoutBars()
    }

    private func layoutBars() {
        let h = bounds.height
        let w = bounds.width
        guard h > 0, w > 0, barCount > 1 else { return }
        let gap = (w - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)
        let minH: CGFloat = 3

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let x = CGFloat(i) * (barWidth + gap)
            let barHeight: CGFloat
            if indeterminate {
                let s = sin(phase + CGFloat(i) * 0.55)
                barHeight = minH + (s * s) * (h * 0.45)
            } else {
                // Speech RMS rarely exceeds ~0.25; scale so a normal voice
                // fills most of the view.
                let level = CGFloat(min(levels[i] * 5.5, 1))
                barHeight = minH + level * (h - minH)
            }
            bar.frame = CGRect(x: x, y: (h - barHeight) / 2, width: barWidth, height: barHeight)
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layoutBars()
    }
}

/// A small rounded pill showing the active engine. Receives clicks even though
/// its window is never key (overriding `mouseDown` works regardless of key
/// status), so tapping it can cycle engines without disturbing the paste target.
final class EngineBadgeView: NSView {
    var onTap: (() -> Void)?
    private let text = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor

        text.font = .systemFont(ofSize: 11, weight: .semibold)
        text.textColor = .white
        text.alignment = .center
        text.backgroundColor = .clear
        text.isBordered = false
        text.isEditable = false
        text.isSelectable = false
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let h: CGFloat = 14
        text.frame = NSRect(x: 4, y: (bounds.height - h) / 2, width: bounds.width - 8, height: h)
    }

    func setTitle(_ s: String) { text.stringValue = s }

    override func mouseDown(with event: NSEvent) { onTap?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
