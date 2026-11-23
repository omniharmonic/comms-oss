@testable import CommsCore
import CoreGraphics
import XCTest

/// The chat-draft character policy (DraftText) — the SAME vectors as the server's
/// apps/server/test/comms-draft-text.test.ts; and the read-coverage gate (ReadCoverage).
final class DraftTextTests: XCTestCase {
    static func tags(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.map { Unicode.Scalar(0xE0000 + $0.value)! })) }

    static let allowed: [(String, String)] = [
        ("plain", "Sure, Thursday works."),
        ("accents, lines", "Ça marche — à jeudi 15h\nÀ plus"),
        ("two blank lines", "a\n\n\nb"),
        ("leading indentation", "  indented"),
        ("family ZWJ (2 ZWJs)", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"),
        ("heart VS16", "\u{2764}\u{FE0F}"),
        ("thumbs skin tone", "\u{1F44D}\u{1F3FD}"),
        ("runner woman ZWJ VS16", "\u{1F3C3}\u{200D}\u{2640}\u{FE0F}"),
        ("skin tone inside ZWJ", "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}"),
        ("keycap", "1\u{FE0F}\u{20E3}"),
        ("regional flag", "\u{1F1EB}\u{1F1F7}"),
        ("four ZWJs", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}\u{200D}\u{1F476}"),
    ]
    static let refused: [(String, String)] = [
        ("flag smuggling 7 tags", "Go team \u{1F3F4}" + tags("PW=1234") + "\u{E007F}"),
        ("england flag (tags refused, period)", "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"),
        ("stacked VS16", "\u{1F44D}\u{FE0F}\u{FE0F}"),
        ("VS15 then VS16", "\u{1F44D}\u{FE0E}\u{FE0F}"),
        ("VS15", "\u{260E}\u{FE0E}"),
        ("VS16 after skin tone", "\u{1F44D}\u{1F3FD}\u{FE0F}"),
        ("VS16 then skin tone", "\u{1F44D}\u{FE0F}\u{1F3FD}"),
        ("ZWJ between © and ™", "\u{00A9}\u{200D}\u{2122}"),
        ("ZWJ between regional indicators", "\u{1F1EB}\u{200D}\u{1F1F7}"),
        ("five ZWJs", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}\u{200D}\u{1F476}\u{200D}\u{1F474}"),
        ("NBSP", "Sure,\u{00A0}Thursday"),
        ("ideographic space", "Sure,\u{3000}Thursday"),
        ("hair space", "a\u{200A}b"),
        ("narrow NBSP", "a\u{202F}b"),
        ("braille blank", "a\u{2800}b"),
        ("object replacement", "a\u{FFFC}b"),
        ("skin tone alone", "a\u{1F3FD}"),
        ("skin tone on a non-base", "\u{2764}\u{1F3FD}"),
        ("VS17 smuggling", "a\u{E0100}b"),
        ("VS1 on a letter", "a\u{FE00}b"),
        ("ZWJ between letters", "a\u{200D}b"),
        ("VS16 on a letter", "a\u{FE0F}b"),
        ("ZWNJ", "a\u{200C}b"),
        ("zero-width space", "Sure\u{200B}"),
        ("bidi override", "pay \u{202E}evil"),
        ("word joiner", "ok\u{2060}"),
        ("soft hyphen", "\u{00AD}soft"),
        ("BOM", "\u{FEFF}hi"),
        ("bare tags", "hi\u{E0041}\u{E0042}"),
        ("trailing ZWJ after emoji", "\u{2764}\u{FE0F}\u{200D}"),
        ("Hangul filler", "a\u{3164}b"),
        ("musical formatting", "a\u{1D173}b"),
        ("bell", "a\u{0007}b"),
        ("C1 control", "a\u{0085}b"),
        ("line separator", "a\u{2028}b"),
    ]
    static let whitespaceRefused: [(String, String)] = [
        ("tab", "Sure,\tThursday"),
        ("trailing spaces on a line", "Sure  \nThursday"),
        ("trailing space at end", "Sure "),
        ("CR", "Sure\r\nThursday"),
        ("three blank lines", "a\n\n\n\nb"),
        ("leading blank line", "\nSure"),
        ("trailing blank line", "Sure\n"),
        ("SNOW-style tail", "Sure, Thursday works." + String(repeating: " \t", count: 50)),
    ]

    func testAllowed() {
        for (name, s) in Self.allowed {
            XCTAssertNil(DraftText.firstRefused(s), name)
            XCTAssertNil(DraftText.problem(s), name)
        }
    }

    func testRefused() {
        for (name, s) in Self.refused { XCTAssertNotNil(DraftText.firstRefused(s), name) }
    }

    func testWhitespaceShape() {
        for (name, s) in Self.whitespaceRefused { XCTAssertNotNil(DraftText.problem(s), name) }
    }

    func testProblem() {
        XCTAssertNil(DraftText.problem(String(repeating: "x", count: 4000)))
        XCTAssertNotNil(DraftText.problem(String(repeating: "x", count: 4001)))
        XCTAssertNotNil(DraftText.problem("   "))
    }

    func testCoverageFitsAtOnce() {
        var c = ReadCoverage()
        c.see(0...300, contentHeight: 200)
        XCTAssertTrue(c.isComplete)
    }

    func testCoverageNeedsEveryLineTopToBottom() {
        var c = ReadCoverage()
        c.see(0...300, contentHeight: 1000)
        XCTAssertFalse(c.isComplete)
        c.see(280...580, contentHeight: 1000)
        c.see(560...860, contentHeight: 1000)
        XCTAssertFalse(c.isComplete)
        c.see(700...1000, contentHeight: 1000)
        XCTAssertTrue(c.isComplete)
    }

    func testCoverageAJumpLeavesAGap() {
        var c = ReadCoverage()
        c.see(0...300, contentHeight: 1000)
        c.see(700...1000, contentHeight: 1000) // a scroll-indicator jump to the end
        XCTAssertFalse(c.isComplete, "lines 300–700 were never on screen")
        c.see(250...720, contentHeight: 1000)
        XCTAssertTrue(c.isComplete)
    }

    func testCoverageStartingMidwayMissesTheTop() {
        var c = ReadCoverage()
        c.see(400...700, contentHeight: 1000)
        c.see(700...1000, contentHeight: 1000)
        XCTAssertFalse(c.isComplete, "the top lines")
    }

    func testCoverageStartsOverWhenTheWidthChanges() {
        var c = ReadCoverage()
        c.see(0...600, contentHeight: 1000, width: 390)
        c.see(400...1000, contentHeight: 1000, width: 390)
        XCTAssertTrue(c.isComplete)
        c.see(0...600, contentHeight: 1000, width: 844) // same height, other line breaks
        XCTAssertFalse(c.isComplete)
    }

    func testCoverageStartsOverWhenTheTextReflows() {
        var c = ReadCoverage()
        c.see(0...600, contentHeight: 1000)
        c.see(400...1000, contentHeight: 1000)
        XCTAssertTrue(c.isComplete)
        c.see(0...600, contentHeight: 1600) // larger text: positions mean other lines now
        XCTAssertFalse(c.isComplete)
    }
}
