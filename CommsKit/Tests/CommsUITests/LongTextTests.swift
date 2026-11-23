@testable import CommsUI
import CommsCore
import PrismModels
import SwiftUI
import XCTest

/// Very long messages: a stack of text layers, each far under the ~16 384 px layer limit, cut
/// where lines start so the stack wraps exactly like one text.
@MainActor
final class LongTextTests: XCTestCase {
    private let words = ["the", "quick", "brown", "fox", "jumps", "over", "a", "lazy", "dog,", "and", "keeps", "running", "through", "fields", "of", "barley", "until", "evening."]

    private func paragraph(words count: Int) -> String {
        (0..<count).map { words[($0 * 7 + $0 / 3) % words.count] }.joined(separator: " ")
    }

    /// Body text as RichTextBlocks builds it (SwiftUI font + the platform font TextKit measures).
    private func attributed(_ s: String, metrics: BubbleMetrics = .iOS) -> AttributedString {
        var out = AttributedString()
        RichTextBlocks.append(.text(s), style: .init(), metrics: metrics, into: &out)
        return out
    }

    /// The text of each laid-out line at `width`.
    private func lines(_ s: AttributedString, width: CGFloat) -> [String] {
        let string = String(s.characters)
        let starts = LongText.lineStarts(s, width: width) ?? []
        let units = Array(string.utf16)
        return starts.enumerated().map { i, start in
            let end = i + 1 < starts.count ? starts[i + 1] : units.count
            return String(decoding: units[start..<end], as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func testA20kPixelMessageIsCutIntoLayersThatWrapExactlyLikeTheWhole() {
        let metrics = BubbleMetrics.iOS
        let width: CGFloat = 250
        let text = attributed(paragraph(words: 2_600), metrics: metrics)
        let whole = lines(text, width: width)
        // ≈ 20 000 px at 3× (the layer limit is ~16 384 px).
        let lineHeight = metrics.lineHeight + metrics.lineSpacing
        XCTAssertGreaterThan(CGFloat(whole.count) * lineHeight * 3, 20_000, "\(whole.count) lines")

        let pieces = LongText.chunks(text, width: width)
        XCTAssertGreaterThanOrEqual(pieces.count, 5)
        var stacked: [String] = []
        for piece in pieces {
            let l = lines(piece, width: width)
            XCTAssertLessThanOrEqual(l.count, LongText.maxLines)
            // Each layer stays well under the limit, even at 3×.
            XCTAssertLessThan(CGFloat(l.count) * lineHeight * 3, 8_192)
            stacked += l
        }
        XCTAssertEqual(stacked, whole, "the pieces wrap exactly as the whole")
        XCTAssertEqual(pieces.map { String($0.characters) }.joined(), String(text.characters), "nothing lost or added")
    }

    /// Messages does not push a word down to avoid a one-word last line (SwiftUI does): the
    /// demo's first bubble wraps after "dinner", as in the Simulator capture (255 pt wide).
    func testMessagesLineBreaksHaveNoPushOut() throws {
        let m = BubbleMetrics.iOS
        let width = 402 * m.maxWidthRatio - 2 * m.padH
        let text = attributed("Hey! Are we still on for dinner tonight?", metrics: m)
        XCTAssertEqual(lines(text, width: width).last, "dinner tonight?", "SwiftUI/TextKit standard: push-out")
        let broken = try XCTUnwrap(LongText.messagesLineBreaks(text, width: width))
        XCTAssertEqual(String(broken.characters), "Hey! Are we still on for dinner\ntonight?")
        // One line, or text that already breaks the same way: unchanged.
        XCTAssertNil(LongText.messagesLineBreaks(attributed("See you soon 👋", metrics: m), width: width))
        XCTAssertNil(LongText.messagesLineBreaks(attributed("Line one\nline two", metrics: m), width: width))
    }

    func testCutAtAHardLineBreakDropsTheNewline() {
        // 200 short lines: every cut lands on a newline, which the cut replaces.
        let text = attributed((1...200).map { "Line \($0) of the list" }.joined(separator: "\n"))
        let pieces = LongText.chunks(text, width: 250)
        XCTAssertGreaterThan(pieces.count, 1)
        for p in pieces.dropLast() {
            XCTAssertNotEqual(p.characters.last, "\n")
        }
        XCTAssertEqual(pieces.map { String($0.characters) }.joined(separator: "\n"), String(text.characters))
    }

    /// Review I1: a pasted list of short lines is tall though short in characters.
    func testManyShortLinesAreCutByLinesNotCharacters() {
        // 590 one-character lines: 1 179 characters (< 1 200) but ~590 lines ≈ 39 000 px at 3×.
        let list = (0..<590).map { _ in "x" }.joined(separator: "\n")
        XCTAssertLessThan(list.utf16.count, LongText.threshold)
        XCTAssertTrue(LongText.mayNeedCutting(list))
        for width in [CGFloat(250), nil] {
            let text = attributed(list)
            let pieces = LongText.chunks(text, width: width)
            XCTAssertGreaterThanOrEqual(pieces.count, 10, "width \(String(describing: width))")
            for p in pieces {
                let hard = String(p.characters).filter { $0 == "\n" }.count + 1
                XCTAssertLessThanOrEqual(hard, LongText.maxLines)
                if let width { XCTAssertLessThanOrEqual(lines(p, width: width).count, LongText.maxLines) }
            }
            XCTAssertEqual(pieces.map { String($0.characters) }.joined(separator: "\n"), list, "the cut newlines are the breaks")
        }
        // 1 000 short lines (a code block has no width): pieces of ≤ 60 lines.
        let block = (1...1_000).map { "\($0)" }.joined(separator: "\n")
        let pre = LongText.chunks(AttributedString(block), width: nil)
        XCTAssertTrue(pre.allSatisfy { String($0.characters).filter { $0 == "\n" }.count < LongText.maxLines })
        XCTAssertEqual(pre.map { String($0.characters) }.joined(separator: "\n"), block)
        // A few lines stay one piece and are never measured.
        XCTAssertFalse(LongText.mayNeedCutting("a\nb\nc"))
    }

    /// Review I3: the iOS line breaks and long-text cuts are laid out once per (text, width).
    func testLayoutIsCachedPerTextAndWidth() {
        LongTextCache.reset()
        let m = BubbleMetrics.iOS
        let width = 402 * m.maxWidthRatio - 2 * m.padH
        let text = attributed("Hey! Are we still on for dinner tonight?", metrics: m)
        let a = LongTextCache.messagesLineBreaks(text, width: width)
        let b = LongTextCache.messagesLineBreaks(text, width: width)
        XCTAssertEqual(a, b)
        XCTAssertEqual(LongTextCache.misses, 1, "the second render reuses the layout")
        _ = LongTextCache.messagesLineBreaks(text, width: width - 40)
        XCTAssertEqual(LongTextCache.misses, 2, "another width is another layout")
        // Short paragraphs: chunks never measured, never cached.
        _ = LongTextCache.chunks(attributed("ok"), width: width)
        XCTAssertEqual(LongTextCache.misses, 2)
        // One line: no TextKit layout at all.
        XCTAssertTrue(LongText.fitsOnOneLine(attributed("See you soon 👋", metrics: m), width: width))
        XCTAssertFalse(LongText.fitsOnOneLine(text, width: width))
    }

    func testShortTextAndNoWidth() {
        let short = attributed("Hello there")
        XCTAssertEqual(LongText.chunks(short, width: 250).count, 1)
        // Without a width: cut on spaces about every 1 200 characters, never losing text.
        let long = attributed(paragraph(words: 1_000))
        let pieces = LongText.chunks(long, width: nil)
        XCTAssertGreaterThan(pieces.count, 2)
        XCTAssertTrue(pieces.allSatisfy { $0.characters.count <= LongText.fallbackCharacters })
        XCTAssertEqual(pieces.map { String($0.characters) }.joined(), String(long.characters))
    }

    func testSurrogatePairsAreNeverSplit() {
        let emoji = String(repeating: "😀", count: 1_500) // no spaces or newlines at all
        let pieces = LongText.chunks(AttributedString(emoji), width: nil)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.map { String($0.characters) }.joined(), emoji)
    }

    #if os(macOS)
    /// The bubble renders to its very end: the last 200 pt of a ~20 000 px (at 2×) message
    /// hold text pixels, and the bubble is as tall as the whole text.
    func testTheWholeLongBubbleRenders() throws {
        let text = paragraph(words: 3_200) + " THE-END"
        let m = MessageFactory.message(text: text)
        let view = MessageBubble(message: m, position: .single, isGroup: false)
            .padding(.horizontal, 16)
            .environment(\.bubbleMetrics, .mac)
            .environment(\.bubbleMaxWidth, 300)
            .environment(\.mediaLoader, .placeholder)
        let image = try XCTUnwrap(Snapshot.renderHosted(view, width: 400, scheme: .light))
        XCTAssertGreaterThan(image.height, 10_000, "the full height at 2×")
        let rgba = Snapshot.rgba(image)
        func darkPixels(rows: Range<Int>) -> Int {
            var n = 0
            for y in rows { for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                if rgba[i] < 90 && rgba[i + 1] < 90 && rgba[i + 2] < 90 && rgba[i + 3] > 200 { n += 1 }
            } }
            return n
        }
        let bottom = (image.height - 400)..<(image.height - 20)
        XCTAssertGreaterThan(darkPixels(rows: bottom), 200, "text is drawn at the bottom of the bubble")
    }
    #endif
}
