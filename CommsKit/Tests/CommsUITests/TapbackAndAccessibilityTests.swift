@testable import CommsUI
import PrismModels
import SwiftUI
import XCTest

/// Fix round 1: monochrome classic tapbacks, counts, RTL mirroring, VoiceOver labels and the
/// Apple-true Mac scale.
@MainActor
final class TapbackAndAccessibilityTests: XCTestCase {
    typealias M = MessageFactory

    // MARK: Classic tapbacks

    func testClassicKeysMapToMonochromeTapbacks() {
        let cases: [(String, ClassicTapback?)] = [
            ("❤️", .love), ("♥️", .love), ("heart", .love), ("👍", .like), ("👍🏽", .like), ("+1", .like),
            ("👎", .dislike), ("😂", .laugh), ("haha", .laugh), ("HA HA", .laugh), ("‼️", .emphasize),
            ("!!", .emphasize), ("❓", .question), ("?", .question), ("🎉", nil), ("😍", nil),
        ]
        for (key, expected) in cases { XCTAssertEqual(ClassicTapback(key: key), expected, key) }
    }

    /// One snapshot per classic glyph, mine and others', light and dark.
    func testClassicTapbackGlyphs() {
        let keys: [(ClassicTapback, String)] = [(.love, "❤️"), (.like, "👍"), (.dislike, "👎"), (.laugh, "😂"), (.emphasize, "‼️"), (.question, "❓")]
        for (classic, key) in keys {
            for mine in [true, false] {
                let m = M.message(id: "$\(classic)", text: "Tapback", reactions: [.init(key: key, mine: mine)])
                Snapshot.assert(MessageBubble(message: m, position: .single, isGroup: false),
                                named: "classicTapback-\(classic.rawValue)-\(mine ? "mine" : "others")", width: 240)
            }
        }
    }

    func testReactionsWithCounts() {
        let incoming = M.message(id: "$in", text: "Dinner at eight?", reactions: [
            .init(key: "❤️", count: 3, mine: true, names: ["Alex", "Sam"]), .init(key: "😂", count: 2, names: ["Alex", "Sam"]),
        ])
        let outgoing = M.message(id: "$out", outgoing: true, text: "Booked!", reactions: [
            .init(key: "👍", count: 4), .init(key: "🎉", count: 2),
        ])
        let view = VStack(spacing: BubbleMetrics.mac.gapSenderChange) {
            MessageBubble(message: incoming, position: .single, isGroup: false)
            MessageBubble(message: outgoing, position: .single, isGroup: false)
        }
        Snapshot.assert(view, named: "reactionsWithCounts")
    }

    /// A crowded stack never hides a count: back badges with counts are not overlapped, and
    /// reactions beyond four collapse into "+N".
    func testCrowdedTapbackStackShowsEveryCount() {
        let incoming = M.message(id: "$in", text: "Big news", reactions: [
            .init(key: "❤️", mine: true), .init(key: "👍", count: 2), .init(key: "😂", count: 3), .init(key: "‼️", count: 2),
        ])
        let overflow = M.message(id: "$of", text: "Everyone reacted", reactions: [
            .init(key: "❤️"), .init(key: "👍", count: 2), .init(key: "😂"), .init(key: "‼️"), .init(key: "❓"), .init(key: "🎉"),
        ])
        let outgoing = M.message(id: "$out", outgoing: true, text: "Party at mine", reactions: [
            .init(key: "🎉", count: 5), .init(key: "👍", count: 2), .init(key: "❤️", count: 3, mine: true),
        ])
        let view = VStack(spacing: BubbleMetrics.mac.gapSenderChange + 8) {
            MessageBubble(message: incoming, position: .single, isGroup: false)
            MessageBubble(message: overflow, position: .single, isGroup: false)
            MessageBubble(message: outgoing, position: .single, isGroup: false)
        }
        Snapshot.assert(view, named: "crowdedTapbackStackShowsEveryCount")
    }

    /// In a right-to-left layout an incoming bubble sits on the right with its tail at the
    /// bottom-right and its tapback at the top-left.
    func testRtlLayoutMirrorsBubble() {
        let incoming = M.message(id: "$i", text: "Incoming", reactions: [.init(key: "❤️", mine: true)])
        let outgoing = M.message(id: "$o", outgoing: true, text: "Outgoing", reactions: [.init(key: "👍")])
        let view = VStack(spacing: BubbleMetrics.mac.gapSenderChange) {
            MessageBubble(message: incoming, position: .single, isGroup: false)
            MessageBubble(message: outgoing, position: .single, isGroup: false)
        }
        .environment(\.layoutDirection, .rightToLeft)
        Snapshot.assert(view, named: "rtlLayoutMirrorsBubble")
    }

    // MARK: VoiceOver

    func testAccessibilityLabelIncomingTextAndReactions() {
        let m = M.message(sender: "Alex", text: "See you at six", reactions: [
            .init(key: "❤️", count: 2, mine: true, names: ["Alex"]), .init(key: "😂", names: ["Sam"]),
        ])
        XCTAssertEqual(MessageBubble.accessibilityLabel(for: m, selfIDs: [M.selfID]),
                       "Alex: See you at six. Loved by you and Alex. Laughed at by Sam")
    }

    func testAccessibilityLabelCountsLargeGroups() {
        let m = M.message(sender: "Alex", text: "Party!", reactions: [
            .init(key: "❤️", count: 3, mine: true, names: ["Alex", "Sam"]), .init(key: "👍", count: 4),
        ])
        XCTAssertEqual(MessageBubble.accessibilityLabel(for: m, selfIDs: [M.selfID]),
                       "Alex: Party!. Loved by 3 people including you. Liked by 4 people")
    }

    func testAccessibilityLabelOutgoingAttachmentsAndLink() {
        let voice: [String: Any] = ["kind": "voice", "durationMs": 7000, "mediaToken": "tok_v"]
        let m = M.message(outgoing: true, text: "https://example.org/a",
                          attachments: [M.image(w: 4, h: 3), voice],
                          linkPreviews: [["url": "https://example.org/a", "title": "An article"]])
        XCTAssertEqual(MessageBubble.accessibilityLabel(for: m),
                       "You. Photo. Voice message 0:07. Link: An article")
    }

    func testAccessibilityLabelNamesTheQuotedParent() {
        let m = M.message(sender: "Sam", text: "Yes, count me in!", replyTo: ("Alex", "Who is coming on Saturday?"))
        XCTAssertEqual(MessageBubble.accessibilityLabel(for: m),
                       "Sam: Yes, count me in!. Replying to Alex: Who is coming on Saturday?")
        let photoParent = M.message(outgoing: true, text: "Nice", replyTo: ("Alex", "  "))
        XCTAssertEqual(MessageBubble.accessibilityLabel(for: photoParent), "You: Nice. Replying to Alex: Message")
    }

    // MARK: VoiceOver actions (I2)

    func testBubbleExposesOpenPhotoAndOpenLinkActions() {
        let m = M.message(spans: [.text("Notes "), .link(href: "https://example.org/notes", [.text("here")]),
                                  .text(" and "), .link(href: "file:///etc/hosts", [.text("there")]),
                                  .text(" or "), .link(href: "mailto:alex@example.org", [])],
                          attachments: [M.image(w: 4, h: 3), M.image(token: "tok_2", w: 4, h: 3)],
                          linkPreviews: [["url": "https://example.org/article", "title": "An article"],
                                         ["url": "javascript:alert(1)", "title": "Bad"]])
        XCTAssertEqual(MessageBubble.accessibilityActions(for: m).map(\.name),
                       ["Open photo", "Open photo 2", "Open link An article", "Open link example.org", "Open link alex@example.org"])
        XCTAssertTrue(MessageBubble.accessibilityActions(for: M.message(sender: "Alex", text: "", redacted: true)).isEmpty)
    }

    func testPhotoActionOpensQuickLookAndLinkActionOpensURL() throws {
        let m = M.message(text: "x", attachments: [M.image(w: 4, h: 3)], linkPreviews: [["url": "https://example.org/a", "title": "A"]])
        let actions = MessageBubble.accessibilityActions(for: m)
        actions[0].perform()
        XCTAssertEqual(MediaViewer.shared.take()?.attachment.mediaToken, "tok_photo")
        let saved = SafeLinks.opener
        defer { SafeLinks.opener = saved }
        var opened: [URL] = []
        SafeLinks.opener = { opened.append($0) }
        actions[1].perform()
        XCTAssertEqual(opened, [URL(string: "https://example.org/a")!])
    }

    func testAccessibilityLabelRedacted() {
        XCTAssertEqual(MessageBubble.accessibilityLabel(for: M.message(sender: "Alex", text: "", redacted: true)),
                       "Alex unsent a message")
    }

    func testReactionPhraseWithoutKnownSelfFallsBackToCount() {
        let m = M.message(text: "x", reactions: [.init(key: "👎", count: 2, mine: true, names: ["Sam"])])
        // The owner's sender entry cannot be told apart without self ids.
        XCTAssertEqual(ReactionBadges.phrase(m.reactions[0], selfIDs: []), "Disliked by 2 people including you")
        XCTAssertEqual(ReactionBadges.phrase(m.reactions[0], selfIDs: [M.selfID]), "Disliked by you and Sam")
    }

    // MARK: Metrics

    func testMacMetricsUseAppleTrueScale() {
        let m = BubbleMetrics.mac
        XCTAssertEqual(m.minHeight, 28.5)
        XCTAssertEqual(m.radius, 14.25)
        XCTAssertEqual(m.padV, 6.25)
        XCTAssertEqual(m.padH / m.minHeight, 0.43, accuracy: 0.02) // Apple's padH ÷ height
        XCTAssertEqual(m.tapbackBadge, 27)
        XCTAssertEqual(m.groupAvatar, 27)
    }

    func testScaledMultipliesSizesNotRatios() {
        let m = BubbleMetrics.mac.scaled(by: 1.5)
        XCTAssertEqual(m.bodySize, 19.5)
        XCTAssertEqual(m.minHeight, 28.5 * 1.5)
        XCTAssertEqual(m.tapbackBadge, 27 * 1.5)
        XCTAssertEqual(m.maxWidthRatio, BubbleMetrics.mac.maxWidthRatio)
        XCTAssertEqual(m.tailScale, BubbleMetrics.mac.tailScale * 1.5, accuracy: 1e-9)
    }
}
