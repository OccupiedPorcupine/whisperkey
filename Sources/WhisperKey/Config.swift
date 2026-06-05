import CoreGraphics
import Foundation

/// User settings, read from ~/.config/whisperkey/config.json. Decoding is
/// tolerant: any missing or unknown key falls back to the default, so an old or
/// partial config never breaks startup.
struct Config: Codable, Equatable {
    var trigger = "capslock"             // capslock | f17 | f18 | f19 | <keycode>
    var mode = "toggle"                  // toggle | push_to_talk
    var engine = "apple"                 // apple | whisperkit
    var whisperModel = "large-v3-turbo"
    var language = "en"                  // e.g. en, en-US, fr-FR
    var output = "paste"                 // paste | type | clipboard
    var clipboardBehavior = "replace"    // replace | append (when output == clipboard)
    var punctuation = true
    var bubblePosition = "bottom-center" // bottom-center | top-center
    var showBubble = true

    init() {}

    enum CodingKeys: String, CodingKey {
        case trigger, mode, engine, whisperModel, language, output
        case clipboardBehavior, punctuation, bubblePosition, showBubble
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
        if let v = try? c.decodeIfPresent(String.self, forKey: .bubblePosition) { bubblePosition = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showBubble) { showBubble = v }
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
}
