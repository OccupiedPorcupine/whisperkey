import XCTest
@testable import WhisperKey

/// The pure string-building behind the Obsidian dictation archive: filename
/// templating (date patterns + the {title} placeholder), filesystem-safe
/// sanitization, and the Markdown note body.
final class ObsidianNoteTests: XCTestCase {
    private let date: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 15
        comps.hour = 14; comps.minute = 32
        return Calendar.current.date(from: comps)!
    }()

    // MARK: renderFilename

    func testTitlePlaceholderIsSubstituted() {
        let name = ObsidianVault.renderFilename("'note-'{title}", title: "Hello World", date: date)
        XCTAssertEqual(name, "note-Hello World")
    }

    func testDatePatternIsFormattedButTitleLettersAreNot() {
        // The title contains "MMdd"-like letters that must NOT be read as date
        // tokens — they're substituted after formatting.
        let name = ObsidianVault.renderFilename("yyyy'-'{title}", title: "MMdd Report", date: date)
        XCTAssertEqual(name, "2026-MMdd Report")
    }

    func testIllegalFilenameCharactersAreStripped() {
        let name = ObsidianVault.renderFilename("{title}", title: "a/b:c*d?e", date: date)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertEqual(name, "a b c d e")
    }

    func testTemplateWithoutPlaceholderStillAppendsTitle() {
        let name = ObsidianVault.renderFilename("'log'", title: "Standup", date: date)
        XCTAssertEqual(name, "log - Standup")
    }

    func testEmptyResultFallsBackToDictation() {
        let name = ObsidianVault.renderFilename("{title}", title: "   ", date: date)
        XCTAssertEqual(name, "Dictation")
    }

    // MARK: noteBody

    func testNoteBodyIncludesFrontmatterTitleAndBacklink() {
        let body = ObsidianVault.noteBody(text: "Buy milk and eggs.",
                                          title: "Grocery List",
                                          appName: "Notes", date: date)
        XCTAssertTrue(body.hasPrefix("---\n"))
        XCTAssertTrue(body.contains("source: WhisperKey"))
        XCTAssertTrue(body.contains("app: \"Notes\""))
        XCTAssertTrue(body.contains("- dictation"))
        XCTAssertTrue(body.contains("# Grocery List"))
        XCTAssertTrue(body.contains("Buy milk and eggs."))
        XCTAssertTrue(body.contains("Dictated in **Notes**"))
        XCTAssertTrue(body.contains("[[2026-06-15]]"))
    }

    func testNoteBodyOmitsAppWhenUnknown() {
        let body = ObsidianVault.noteBody(text: "Some thought.",
                                          title: "Idea", appName: "", date: date)
        XCTAssertFalse(body.contains("app:"))
        XCTAssertFalse(body.contains("Dictated in"))
        XCTAssertTrue(body.contains("[[2026-06-15]]"))   // backlink still present
    }
}
