import CommsUI
import PrismModels
import SwiftUI
import XCTest

/// Bubble snapshots at Mac sizes (body 13 pt), light and dark. References live in
/// `__Snapshots__`; record with `RECORD_SNAPSHOTS=1`.
@MainActor
final class BubbleSnapshotTests: XCTestCase {
    typealias M = MessageFactory

    func testIncomingSingleTextHasTail() {
        let m = M.message(text: "Are we still on for tomorrow?")
        Snapshot.assert(MessageBubble(message: m, position: .single, isGroup: false), named: "incomingSingleTextHasTail")
    }

    func testOutgoingRunMiddleHasNoTail() {
        let m = M.message(outgoing: true, text: "Yes! I'll bring the snacks")
        Snapshot.assert(MessageBubble(message: m, position: .middle, isGroup: false), named: "outgoingRunMiddleHasNoTail")
    }

    func testRichTextBoldLinkQuote() {
        let m = M.message(spans: [
            .quote([.text("Did you see the plan?")]),
            .text("Yes, it is "), .bold([.text("really")]), .text(" good. Notes are "),
            .link(href: "https://example.org/notes", [.text("here")]), .text(", and "),
            .italic([.text("this")]), .text(" is "), .strike([.text("wrong")]), .text(" "), .code([.text("fixed()")]),
        ])
        Snapshot.assert(MessageBubble(message: m, position: .single, isGroup: false), named: "richTextBoldLinkQuote")
    }

    func testJumboEmojiHasNoBubble() {
        let m = M.message(outgoing: true, text: "😂👍", jumboEmoji: true)
        Snapshot.assert(MessageBubble(message: m, position: .single, isGroup: false), named: "jumboEmojiHasNoBubble")
    }

    func testImageBubbleAspect4x3() {
        let m = M.message(attachments: [M.image(w: 800, h: 600)])
        Snapshot.assert(MessageBubble(message: m, position: .single, isGroup: false), named: "imageBubbleAspect4x3")
    }

    func testLinkPreviewCard() {
        let m = M.message(outgoing: true, text: "https://example.org/article", linkPreviews: [[
            "url": "https://example.org/article", "title": "A synthetic article title for the card",
            "siteName": "example.org", "imageToken": "tok_og",
        ]])
        Snapshot.assert(MessageBubble(message: m, position: .single, isGroup: false), named: "linkPreviewCard")
    }

    func testReactionsStackMineBlue() {
        let m = M.message(text: "We got the tickets!", reactions: [
            .init(key: "❤️", mine: true), .init(key: "👍", count: 2), .init(key: "😂"),
        ])
        Snapshot.assert(MessageBubble(message: m, position: .single, isGroup: false), named: "reactionsStackMineBlue")
    }

    func testRedactedShowsSystemCaption() {
        let m = M.message(sender: "Alex", text: "", redacted: true)
        Snapshot.assert(MessageBubble(message: m, position: .single, isGroup: false), named: "redactedShowsSystemCaption")
    }

    func testRtlTextAlignsTrailing() {
        let m = M.message(text: "שלום! מה שלומך היום? אני מקווה שהכול טוב אצלך ושנתראה בקרוב מאוד")
        Snapshot.assert(MessageBubble(message: m, position: .single, isGroup: false), named: "rtlTextAlignsTrailing")
    }

    func testVeryLongWordWraps() {
        let m = M.message(outgoing: true, text: String(repeating: "abcdefghij", count: 12))
        Snapshot.assert(MessageBubble(message: m, position: .single, isGroup: false), named: "veryLongWordWraps")
    }

    func testOutgoingWhatsAppVsTelegramShades() {
        let wa = M.message(id: "$wa", network: "whatsapp", outgoing: true, text: "Sent over WhatsApp")
        let tg = M.message(id: "$tg", network: "telegram", outgoing: true, text: "Sent over Telegram")
        let view = VStack(alignment: .trailing, spacing: BubbleMetrics.mac.gapSenderChange) {
            MessageBubble(message: wa, position: .single, isGroup: false)
            MessageBubble(message: tg, position: .single, isGroup: false)
        }
        Snapshot.assert(view, named: "outgoingWhatsAppVsTelegramShades")
    }

    /// A reply draws its quoted parent as an outline bubble above it (UX spec §5), incoming
    /// in a group (under the sender name) and outgoing.
    func testReplyQuoteAboveReply() {
        let incoming = M.message(id: "$in", sender: "Sam", text: "Yes, count me in!",
                                 replyTo: ("Alex", "Who is coming to the trail day on Saturday? Bring water and snacks."))
        let outgoing = M.message(id: "$out", outgoing: true, text: "Same here", replyTo: ("Sam", "Yes, count me in!"))
        let view = VStack(spacing: BubbleMetrics.mac.gapSenderChange) {
            MessageBubble(message: incoming, position: .single, isGroup: true)
            MessageBubble(message: outgoing, position: .single, isGroup: true)
        }
        Snapshot.assert(view, named: "replyQuoteAboveReply")
    }

    /// F1 / I7: a parent offering less height than a bubble needs must not squeeze it (the
    /// gallery's fixed 480 pt panel clipped the blockquote bubble). The squeezed render is
    /// exactly as tall as the free one.
    func testRichTextQuoteBubbleIsNotCompressible() throws {
        let m = M.message(outgoing: true, spans: [
            .quote([.text("Did you see the plan for the trail day on Saturday morning?")]),
            .text("Yes, it is "), .bold([.text("really")]), .text(" good. Notes are "),
            .link(href: "https://example.org/notes", [.text("here")]),
        ], reactions: [.init(key: "❤️")])
        let view = MessageBubble(message: m, position: .single, isGroup: false)
            .environment(\.bubbleMetrics, .mac)
            .environment(\.bubbleMaxWidth, 260)
        func height(_ proposal: CGFloat?) throws -> Int {
            let r = ImageRenderer(content: view)
            r.proposedSize = ProposedViewSize(width: 420, height: proposal)
            return try XCTUnwrap(r.cgImage).height
        }
        let free = try height(nil)
        XCTAssertGreaterThan(free, 60)
        XCTAssertEqual(try height(20), free)
        XCTAssertEqual(try height(CGFloat(free) / 2), free)
    }
}
