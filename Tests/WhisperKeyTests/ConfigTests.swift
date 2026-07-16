import XCTest
@testable import WhisperKey

/// Config decoding must be tolerant: a partial or slightly-wrong config.json
/// should never break startup — every missing or mistyped field falls back to
/// its default.
final class ConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testEmptyObjectYieldsDefaults() throws {
        let c = try decode("{}")
        XCTAssertEqual(c, Config())
        XCTAssertEqual(c.engine, "apple")
        XCTAssertEqual(c.mode, "toggle")
        XCTAssertEqual(c.bubblePosition, "notch")
        XCTAssertFalse(c.obsidianLogging)
        XCTAssertEqual(c.obsidianNoteNameFormat, "yyMMddHHmm - {title}")
    }

    func testPartialConfigKeepsDefaultsForOmittedKeys() throws {
        let c = try decode(#"{"engine":"whisperkit","obsidianLogging":true}"#)
        XCTAssertEqual(c.engine, "whisperkit")
        XCTAssertTrue(c.obsidianLogging)
        XCTAssertEqual(c.mode, "toggle")          // untouched default
        XCTAssertEqual(c.output, "paste")         // untouched default
    }

    func testUnknownKeysAreIgnored() throws {
        let c = try decode(#"{"somethingNew":42,"punctuation":false}"#)
        XCTAssertFalse(c.punctuation)
        XCTAssertEqual(c.engine, "apple")
    }

    func testWronglyTypedValueFallsBackInsteadOfThrowing() throws {
        // punctuation should be a Bool; a string must not crash decoding.
        let c = try decode(#"{"punctuation":"nope","historyLimit":"lots"}"#)
        XCTAssertTrue(c.punctuation)               // default preserved
        XCTAssertEqual(c.historyLimit, 25)         // default preserved
    }

    // MARK: Keycode mapping

    func testTriggerKeyCodes() {
        var c = Config()
        c.trigger = "capslock"; XCTAssertEqual(c.triggerKeyCode, 79)
        c.trigger = "f17";      XCTAssertEqual(c.triggerKeyCode, 64)
        c.trigger = "f19";      XCTAssertEqual(c.triggerKeyCode, 80)
        c.trigger = "42";       XCTAssertEqual(c.triggerKeyCode, 42)
    }

    func testChordKeyCodes() {
        var c = Config()
        c.chordKey = "m";       XCTAssertEqual(c.chordKeyCode, 46)
        c.speakChordKey = "s";  XCTAssertEqual(c.speakChordKeyCode, 1)
        c.chordKey = "";        XCTAssertNil(c.chordKeyCode)        // disabled
        c.chordKey = "a";       XCTAssertEqual(c.chordKeyCode, 0)   // A is keycode 0, still valid
    }
}
