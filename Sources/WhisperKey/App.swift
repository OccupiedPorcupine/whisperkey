import AppKit
import ApplicationServices
import AVFoundation
import Speech

/// Menu-bar lifecycle + permission bootstrap. Owns the DictationEngine and
/// reflects recording state in the status-bar icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = DictationEngine()
    private let configStore = ConfigStore()
    private let bubble = BubbleWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !anotherInstanceRunning() else {
            NSLog("WhisperKey: another instance is already running — exiting this one.")
            NSApp.terminate(nil)
            return
        }
        setUpStatusItem()
        requestPermissions()

        engine.onStateChange = { [weak self] recording in
            self?.updateIcon(recording: recording)
            if recording { self?.bubble.show() } else { self?.bubble.hide() }
        }
        engine.onPartial = { [weak self] text in
            self?.bubble.update(text: text)
        }
        engine.onLevel = { [weak self] rms in
            self?.bubble.updateLevel(rms)
        }

        // Load config, apply it, and re-apply on every hot reload.
        configStore.onChange = { [weak self] config in
            self?.applyConfig(config)
        }
        configStore.start()
        applyConfig(configStore.config)

        engine.start()
    }

    private func applyConfig(_ config: Config) {
        engine.applyConfig(config)
        bubble.position = config.bubblePosition
        bubble.enabled = config.showBubble
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(recording: false)

        let menu = NSMenu()
        let status = NSMenuItem(title: "WhisperKey — idle", action: nil, keyEquivalent: "")
        status.tag = 1
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WhisperKey", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
        statusItem.menu = menu
    }

    private func updateIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol = recording ? "mic.fill" : "mic"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WhisperKey")
        button.contentTintColor = recording ? .systemRed : nil
        if let status = statusItem.menu?.item(withTag: 1) {
            status.title = recording ? "WhisperKey — listening…" : "WhisperKey — idle"
        }
    }

    private func requestPermissions() {
        // Speech recognition authorization (Apple engine).
        SFSpeechRecognizer.requestAuthorization { status in
            NSLog("WhisperKey speech auth: %d", status.rawValue)
        }
        // Microphone authorization. Triggers the system prompt on first run.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            NSLog("WhisperKey mic access: %@", granted ? "granted" : "denied")
        }
        // Accessibility — required both to detect the focused text field and to
        // type into it. Prompt the user to add WhisperKey if not yet trusted.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        NSLog("WhisperKey accessibility trusted: %@", trusted ? "yes" : "NO — add WhisperKey.app under Privacy & Security → Accessibility, then relaunch")
    }

    private func anotherInstanceRunning() -> Bool {
        let me = NSRunningApplication.current
        let id = Bundle.main.bundleIdentifier ?? "com.munyau.whisperkey"
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me.processIdentifier }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
