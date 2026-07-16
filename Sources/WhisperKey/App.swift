import AppKit
import ApplicationServices
import AVFoundation
import Speech

/// Menu-bar lifecycle + permission bootstrap. Owns the DictationEngine (STT),
/// the Speaker (TTS), the transcript history, and reflects state in the
/// status-bar icon and the overlay bubble.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = DictationEngine()
    private let speaker = Speaker()
    private let history = HistoryStore()
    private let configStore = ConfigStore()
    private let bubble = BubbleWindow()

    private var engineMenuItems: [NSMenuItem] = []
    private var voiceMenuItems: [NSMenuItem] = []
    private var modeMenuItems: [NSMenuItem] = []
    private var polishMenuItem: NSMenuItem?
    private var historyMenu: NSMenu?
    private var liveObsidianItem: NSMenuItem?
    private var liveTypingItem: NSMenuItem?
    private var obsidianLogItem: NSMenuItem?
    private var configWarningItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !anotherInstanceRunning() else {
            NSLog("WhisperKey: another instance is already running — exiting this one.")
            NSApp.terminate(nil)
            return
        }
        setUpStatusItem()
        requestPermissions()

        // --- Dictation (STT) → bubble + history --------------------------------
        engine.onStateChange = { [weak self] recording in
            self?.updateIcon(recording: recording)
            // Show on start; teardown is driven by onFinished so the bubble stays
            // visible through transcription finalize + the LLM polish pass.
            if recording { self?.bubble.show(state: .listening) }
        }
        engine.onPhase = { [weak self] phase in
            switch phase {
            case .listening:    self?.bubble.setState(.listening)
            case .transcribing: self?.bubble.setState(.transcribing)
            case .polishing:    self?.bubble.setState(.polishing)
            }
        }
        engine.onPartial = { [weak self] text in
            self?.bubble.update(text: text)
        }
        engine.onLevel = { [weak self] rms in
            self?.bubble.updateLevel(rms)
        }
        engine.onFinished = { [weak self] in
            // Only tear down if TTS isn't mid-flight in the same bubble.
            guard let self else { return }
            if !self.speaker.isActive { self.bubble.hide() }
        }
        engine.onDelivered = { [weak self] text in
            self?.history.add(text)
            self?.rebuildHistoryMenu()
        }
        engine.onLiveStateChange = { [weak self] active, target in
            guard let self else { return }
            if active {
                self.bubble.show(state: .live)
                self.liveObsidianItem?.title = target != nil && target != "focused app"
                    ? "◉ Stop Live Note (\(target!))" : "◉ Stop Live Transcription"
                self.liveTypingItem?.title = "◉ Stop Live Transcription"
            } else {
                self.liveObsidianItem?.title = "Live Transcribe → Obsidian Note"
                self.liveTypingItem?.title = "Live Transcribe → Focused Textbox"
            }
        }
        bubble.onEngineTap = { [weak self] in self?.cycleEngine() }

        // --- TTS (speak selection) ---------------------------------------------
        engine.onSpeakRequest = { [weak self] in
            self?.speaker.toggleSpeakSelection()
        }
        engine.onExternalEscape = { [weak self] in
            self?.speaker.stop()
        }
        speaker.onPhaseChange = { [weak self] phase, text in
            guard let self else { return }
            // While speaking, Esc should stop playback (routed via the engine's
            // event tap, which owns the keyboard).
            self.engine.externalEscapeInterest = (phase != .idle)
            switch phase {
            case .preparing:
                self.bubble.show(state: .speaking)
                self.bubble.update(text: "Generating voice…")
            case .speaking:
                self.bubble.show(state: .speaking)
                self.bubble.update(text: text)
            case .idle:
                self.bubble.hide()
            }
        }

        // Load config, apply it, and re-apply on every hot reload.
        configStore.onChange = { [weak self] config in
            self?.applyConfig(config)
        }
        configStore.start()
        applyConfig(configStore.config)

        // Warm the on-device LLM at launch so the first dictation's polish is snappy.
        if configStore.config.polish { TranscriptPolisher.prewarm() }
        // If the user opted into the local neural voice, pre-load it too.
        if configStore.config.ttsEngine == "neural" { Speaker.prewarmNeural() }

        rebuildHistoryMenu()
        engine.start()
    }

    private func applyConfig(_ config: Config) {
        engine.applyConfig(config)
        bubble.position = config.bubblePosition
        bubble.enabled = config.showBubble
        bubble.setEngine(EngineCatalog.option(for: config.engine).badge)

        speaker.engine = config.ttsEngine
        speaker.voice = config.ttsVoice
        speaker.rate = config.ttsRate
        history.limit = config.historyLimit

        for item in engineMenuItems {
            item.state = (item.representedObject as? String == config.engine) ? .on : .off
        }
        for item in voiceMenuItems {
            item.state = (item.representedObject as? String == config.ttsEngine) ? .on : .off
        }
        for item in modeMenuItems {
            item.state = (item.representedObject as? String == config.mode) ? .on : .off
        }
        polishMenuItem?.state = config.polish ? .on : .off
        obsidianLogItem?.state = config.obsidianLogging ? .on : .off
        refreshConfigWarnings(config)
    }

    /// Surface config problems (unknown values, a missing Obsidian vault) as a
    /// menu item that's hidden when the config is clean. Each problem is a
    /// disabled sub-item; the parent also offers a jump to the config file.
    private func refreshConfigWarnings(_ config: Config) {
        guard let item = configWarningItem else { return }
        let problems = ConfigValidator.warnings(for: config)
        guard !problems.isEmpty else {
            item.isHidden = true
            item.submenu = nil
            return
        }
        item.isHidden = false
        item.title = problems.count == 1
            ? "⚠️ Config issue"
            : "⚠️ Config issues (\(problems.count))"
        let sub = NSMenu()
        for problem in problems {
            let p = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
            p.isEnabled = false
            sub.addItem(p)
        }
        sub.addItem(.separator())
        let open = NSMenuItem(title: "Open Config File", action: #selector(openConfig), keyEquivalent: "")
        open.target = self
        sub.addItem(open)
        item.submenu = sub
    }

    // MARK: Engine / voice / mode selection

    /// Persist + hot-apply an engine choice (takes effect on the next dictation).
    private func selectEngine(_ id: String) {
        configStore.update { $0.engine = id }
    }

    /// Bubble badge tap → advance to the next engine in the catalog.
    private func cycleEngine() {
        selectEngine(EngineCatalog.next(after: configStore.config.engine))
    }

    @objc private func engineMenuPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectEngine(id)
    }

    @objc private func voiceMenuPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        configStore.update { $0.ttsEngine = id }
        if id == "neural" { Speaker.prewarmNeural() }
    }

    @objc private func modeMenuPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        configStore.update { $0.mode = id }
    }

    @objc private func togglePolish() {
        configStore.update { $0.polish.toggle() }
        if configStore.config.polish { TranscriptPolisher.prewarm() }
    }

    @objc private func speakSelection() {
        speaker.toggleSpeakSelection()
    }

    @objc private func toggleLiveObsidian() {
        if engine.isLive { engine.stopLiveTranscription() }
        else { engine.startLiveTranscription(to: .obsidian) }
    }

    @objc private func toggleLiveTyping() {
        if engine.isLive { engine.stopLiveTranscription() }
        else { engine.startLiveTranscription(to: .typing) }
    }

    @objc private func toggleObsidianLogging() {
        configStore.update { $0.obsidianLogging.toggle() }
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(configStore.fileURL)
    }

    // MARK: History menu

    @objc private func historyItemPicked(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func speakHistoryItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        speaker.speak(text)
    }

    @objc private func clearHistory() {
        history.clear()
        rebuildHistoryMenu()
    }

    private func rebuildHistoryMenu() {
        guard let menu = historyMenu else { return }
        menu.removeAllItems()
        if history.entries.isEmpty {
            let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            for entry in history.entries {
                let preview = entry.text.count > 60
                    ? String(entry.text.prefix(60)) + "…"
                    : entry.text
                let item = NSMenuItem(title: "\(formatter.string(from: entry.date))  \(preview)",
                                      action: #selector(historyItemPicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                item.toolTip = entry.text + "\n\nClick to copy · ⌥-click to speak"
                // ⌥-variant reads the transcript aloud instead of copying.
                let speakAlt = NSMenuItem(title: "🔊 Speak", action: #selector(speakHistoryItem(_:)), keyEquivalent: "")
                speakAlt.target = self
                speakAlt.representedObject = entry.text
                speakAlt.isAlternate = true
                speakAlt.keyEquivalentModifierMask = .option
                menu.addItem(item)
                menu.addItem(speakAlt)
            }
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }

    // MARK: Menu construction

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(recording: false)

        let menu = NSMenu()
        let status = NSMenuItem(title: "WhisperKey — idle", action: nil, keyEquivalent: "")
        status.tag = 1
        menu.addItem(status)

        // Config-problem banner: hidden while the config is valid, populated by
        // refreshConfigWarnings on every (re)load.
        let warn = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warn.isHidden = true
        configWarningItem = warn
        menu.addItem(warn)
        menu.addItem(.separator())

        // Engine submenu (mirrors the bubble badge; checkmark shows the active one).
        let engineParent = NSMenuItem(title: "Dictation Engine", action: nil, keyEquivalent: "")
        let engineMenu = NSMenu()
        engineMenuItems = EngineCatalog.all.map { opt in
            let item = NSMenuItem(title: opt.menuTitle, action: #selector(engineMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = opt.id
            engineMenu.addItem(item)
            return item
        }
        engineParent.submenu = engineMenu
        menu.addItem(engineParent)

        // Mode submenu.
        let modeParent = NSMenuItem(title: "Trigger Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        modeMenuItems = [("toggle", "Toggle (tap to start/stop)"),
                         ("push_to_talk", "Push-to-talk (hold)")].map { id, title in
            let item = NSMenuItem(title: title, action: #selector(modeMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            modeMenu.addItem(item)
            return item
        }
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)

        // Polish toggle (on-device LLM cleanup).
        let polish = NSMenuItem(title: "Polish with On-Device AI", action: #selector(togglePolish), keyEquivalent: "")
        polish.target = self
        polishMenuItem = polish
        menu.addItem(polish)
        menu.addItem(.separator())

        // TTS: voice picker + speak-selection action.
        let voiceParent = NSMenuItem(title: "Voice (Text-to-Speech)", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        voiceMenuItems = [("apple", "Apple System Voice"),
                          ("neural", "Neural Voice (local AI)")].map { id, title in
            let item = NSMenuItem(title: title, action: #selector(voiceMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            voiceMenu.addItem(item)
            return item
        }
        voiceParent.submenu = voiceMenu
        menu.addItem(voiceParent)

        let speak = NSMenuItem(title: "Speak Selection    ⇪S", action: #selector(speakSelection), keyEquivalent: "")
        speak.target = self
        menu.addItem(speak)
        menu.addItem(.separator())

        // Live transcription: stream speech into an Obsidian note or whatever
        // textbox has focus, until stopped (menu again, ⇪ tap, or Esc).
        let liveObsidian = NSMenuItem(title: "Live Transcribe → Obsidian Note",
                                      action: #selector(toggleLiveObsidian), keyEquivalent: "")
        liveObsidian.target = self
        liveObsidianItem = liveObsidian
        menu.addItem(liveObsidian)

        let liveTyping = NSMenuItem(title: "Live Transcribe → Focused Textbox",
                                    action: #selector(toggleLiveTyping), keyEquivalent: "")
        liveTyping.target = self
        liveTypingItem = liveTyping
        menu.addItem(liveTyping)

        // Archive every finalized dictation as its own Obsidian note (off by
        // default; filename template + folder live in the config file).
        let obsidianLog = NSMenuItem(title: "Log Dictations → Obsidian",
                                     action: #selector(toggleObsidianLogging), keyEquivalent: "")
        obsidianLog.target = self
        obsidianLogItem = obsidianLog
        menu.addItem(obsidianLog)
        menu.addItem(.separator())

        // Recent transcripts.
        let historyParent = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        let hMenu = NSMenu()
        historyMenu = hMenu
        historyParent.submenu = hMenu
        menu.addItem(historyParent)
        menu.addItem(.separator())

        let configItem = NSMenuItem(title: "Open Config File", action: #selector(openConfig), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)

        let quitItem = NSMenuItem(title: "Quit WhisperKey", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
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

    /// Held open for the app's whole lifetime; the kernel releases the lock
    /// automatically when the process dies (even on crash/kill).
    private var singletonLockFD: CInt = -1

    /// True when another WhisperKey already holds the singleton lock.
    ///
    /// Uses an exclusive `flock` rather than an NSRunningApplication scan: the
    /// scan is racy — two copies launched in the same instant (e.g. installer +
    /// LaunchAgent) each see the other not-yet-registered and both survive,
    /// which leaves a second invisible instance that can hold the mic open.
    /// A kernel lock has exactly one winner no matter how close the race.
    private func anotherInstanceRunning() -> Bool {
        let path = NSTemporaryDirectory() + "com.munyau.whisperkey.lock"
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }   // can't create the lock — don't block launch
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return true
        }
        singletonLockFD = fd
        return false
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
