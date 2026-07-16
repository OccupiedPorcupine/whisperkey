import XCTest
@testable import WhisperKey

/// The filesystem-free structural checks. (Vault-existence checks in
/// `warnings(for:)` touch disk and Obsidian's registry, so they're left to
/// manual/integration verification.)
final class ConfigValidatorTests: XCTestCase {
    func testDefaultConfigIsClean() {
        XCTAssertTrue(ConfigValidator.structuralWarnings(for: Config()).isEmpty)
    }

    func testUnknownEnumValuesAreFlagged() {
        var c = Config()
        c.engine = "bogus"
        c.mode = "sideways"
        c.output = "fax"
        c.ttsEngine = "robot"
        let w = ConfigValidator.structuralWarnings(for: c)
        XCTAssertEqual(w.count, 4)
        XCTAssertTrue(w.contains { $0.contains("engine") })
        XCTAssertTrue(w.contains { $0.contains("mode") })
        XCTAssertTrue(w.contains { $0.contains("output") })
        XCTAssertTrue(w.contains { $0.contains("ttsEngine") })
    }

    func testUnknownBubblePositionIsFlagged() {
        var c = Config()
        c.bubblePosition = "notch"
        XCTAssertTrue(ConfigValidator.structuralWarnings(for: c).isEmpty)
        c.bubblePosition = "middle"
        XCTAssertTrue(ConfigValidator.structuralWarnings(for: c).contains { $0.contains("bubblePosition") })
    }

    func testNegativeHistoryLimitIsFlagged() {
        var c = Config()
        c.historyLimit = -3
        XCTAssertTrue(ConfigValidator.structuralWarnings(for: c).contains { $0.contains("historyLimit") })
    }

    func testMissingTitlePlaceholderFlaggedOnlyWhenLoggingOn() {
        var c = Config()
        c.obsidianNoteNameFormat = "yyMMddHHmm"   // no {title}
        XCTAssertTrue(ConfigValidator.structuralWarnings(for: c).isEmpty)   // logging off → fine

        c.obsidianLogging = true
        XCTAssertTrue(ConfigValidator.structuralWarnings(for: c).contains { $0.contains("{title}") })
    }
}
