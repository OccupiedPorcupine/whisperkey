import CoreGraphics
import Foundation

/// User settings, read from ~/.config/whisperkey/config.json. Decoding is
/// tolerant: any missing or unknown key falls back to the default, so an old or
/// partial config never breaks startup.
struct Config: Codable, Equatable {
    var trigger = "capslock"             // capslock | f17 | f18 | f19 | <keycode>
    var mode = "toggle"                  // toggle | push_to_talk
    var engine = "apple"                 // apple | whisperkit
    // WhisperKit model folder suffix in argmaxinc/whisperkit-coreml. This is
    // OpenAI's large-v3-turbo (Sept 2024 release), quantized to 626 MB — the
    // hyphenated marketing name "large-v3-turbo" does NOT exist in the repo.
    var whisperModel = "large-v3-v20240930_626MB"
    var language = "en"                  // e.g. en, en-US, fr-FR
    var output = "paste"                 // paste | type | clipboard
    var clipboardBehavior = "replace"    // replace | append (when output == clipboard)
    var punctuation = true
    var polish = true                    // on-device LLM cleanup pass (macOS 26+); no-op if unavailable
    var bubblePosition = "notch"         // notch | top-center | bottom-center
    var showBubble = true
    var chordKey = "m"                   // chord companion key (Caps Lock + <key>); "" disables
    var speakChordKey = "s"              // Caps Lock + <key> speaks the selected text; "" disables
    var ttsEngine = "apple"              // apple | neural (local PocketTTS model)
    var ttsVoice = ""                    // Apple voice identifier ("" = system default) | neural voice name
    var ttsRate = 0.5                    // Apple engine speaking rate, 0…1 (0.5 = natural)
    var dictionary: [String] = []        // custom vocabulary: names, jargon, product terms
    var historyLimit = 25                // recent transcripts kept in the menu; 0 disables
    var obsidianVaultPath = ""           // "" = auto-detect from Obsidian's own config
    var obsidianFolder = "WhisperKey Live" // vault subfolder for live-transcript notes; "" = vault root
    var obsidianLogging = false          // save every finalized dictation as its own vault note
    var obsidianLogFolder = "WhisperKey Dictations" // vault subfolder for those notes; "" = vault root
    // Note filename template: DateFormatter patterns + an optional {title}
    // placeholder the on-device AI fills with a short summary. e.g. the default
    // yields "2607171432 - Email The Landlord.md".
    var obsidianNoteNameFormat = "yyMMddHHmm - {title}"

    init() {}

    enum CodingKeys: String, CodingKey {
        case trigger, mode, engine, whisperModel, language, output
        case clipboardBehavior, punctuation, polish, bubblePosition, showBubble, chordKey
        case speakChordKey, ttsEngine, ttsVoice, ttsRate, dictionary, historyLimit
        case obsidianVaultPath, obsidianFolder
        case obsidianLogging, obsidianLogFolder, obsidianNoteNameFormat
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(String.self, forKey: .trigger) { trigger = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .mode) { mode = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .engine) { engine = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .whisperModel) { whisperModel = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .language) { language = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .output) { output = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .clipboardBehavior) { clipboardBehavior = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .punctuation) { punctuation = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .polish) { polish = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .bubblePosition) { bubblePosition = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showBubble) { showBubble = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .chordKey) { chordKey = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .speakChordKey) { speakChordKey = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .ttsEngine) { ttsEngine = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .ttsVoice) { ttsVoice = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .ttsRate) { ttsRate = v }
        if let v = try? c.decodeIfPresent([String].self, forKey: .dictionary) { dictionary = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .historyLimit) { historyLimit = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .obsidianVaultPath) { obsidianVaultPath = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .obsidianFolder) { obsidianFolder = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .obsidianLogging) { obsidianLogging = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .obsidianLogFolder) { obsidianLogFolder = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .obsidianNoteNameFormat) { obsidianNoteNameFormat = v }
    }

    /// SFSpeechRecognizer expects a region (e.g. "en-US"); expand bare codes.
    var localeIdentifier: String {
        if language.contains("-") { return language }
        if language == "en" { return "en-US" }
        return language
    }

    /// F18 (Caps Lock remap) and the other function keys we know by name.
    var triggerKeyCode: CGKeyCode {
        switch trigger.lowercased() {
        case "capslock", "f18": return 79
        case "f17": return 64
        case "f19": return 80
        case "f20": return 90
        default:
            if let n = UInt16(trigger) { return CGKeyCode(n) }
            return 79
        }
    }

    /// Chord companion keycode. Accepts a single letter (a–z), a raw keycode
    /// number, or "" to disable the chord (returns nil). Optional rather than a
    /// 0 sentinel because 0 is a real keycode (the letter A).
    var chordKeyCode: CGKeyCode? {
        Config.keyCode(for: chordKey, fallback: 46) // M
    }

    /// Keycode for the "speak selection" chord (Caps Lock + <key>). nil disables.
    var speakChordKeyCode: CGKeyCode? {
        Config.keyCode(for: speakChordKey, fallback: 1) // S
    }

    private static func keyCode(for name: String, fallback: CGKeyCode) -> CGKeyCode? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if key.isEmpty { return nil }
        if let code = letterKeyCodes[key] { return code }
        if let n = UInt16(key) { return CGKeyCode(n) }
        return fallback
    }

    /// ANSI virtual keycodes for letter keys (kVK_ANSI_*). Letter keycodes are
    /// not sequential, so they're mapped explicitly.
    private static let letterKeyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
        "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
        "m": 46,
    ]
}
