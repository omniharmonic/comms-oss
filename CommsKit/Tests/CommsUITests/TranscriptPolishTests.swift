import CommsCore
@testable import CommsUI
import PrismModels
import SwiftUI
import XCTest

/// Task 5 transcript fixes: a group run's avatar and tail inside the row (the Mac table clips
/// rows), light reply quotes ("You" for the owner), Omni's own accounts as incoming "Omni".
@MainActor
final class TranscriptPolishTests: XCTestCase {
    private func rows(_ messages: [(CommsMessage, RunPosition)], group: Bool = true) -> some View {
        let r: [TranscriptRow] = messages.map { .message($0.0, $0.1, showSenderName: group && $0.1.startsRun && !$0.0.sender.isSelf, showAvatar: group) }
        return VStack(spacing: 0) {
            ForEach(Array(r.enumerated()), id: \.offset) { i, row in
                TranscriptRowView(row: row, context: TranscriptRowContext(isGroup: group, spacingAbove: TranscriptRowView.spacingAbove(row, after: i > 0 ? r[i - 1] : nil, metrics: .mac)))
            }
        }
    }

    func testGroupRunAvatarAndTailFitTheRow() {
        let a = MessageFactory.message(id: "$a", network: "signal", sender: "Priya Natarajan", text: "Who's in for Saturday?")
        let b = MessageFactory.message(id: "$b", network: "signal", sender: "Priya Natarajan", text: "ok")
        let c = MessageFactory.message(id: "$c", network: "signal", outgoing: true, text: "Me!")
        #if os(macOS)
        let tailed = TranscriptRow.message(b, .last, showSenderName: false, showAvatar: true)
        XCTAssertEqual(TranscriptRowView.overhang(tailed, metrics: .mac), BubbleMetrics.mac.tailDrop)
        XCTAssertGreaterThan(BubbleMetrics.mac.tailDrop, 0)
        // The next row gives the overhang back: the visible gap is the calibrated one.
        let next = TranscriptRow.message(c, .single, showSenderName: false, showAvatar: true)
        XCTAssertEqual(TranscriptRowView.spacingAbove(next, after: tailed, metrics: .mac) + BubbleMetrics.mac.tailDrop, BubbleMetrics.mac.gapSenderChange, accuracy: 0.01)
        #endif
        Snapshot.assert(rows([(a, .first), (b, .last), (c, .single)]), named: "groupRunAvatarSingleLine")
    }

    func testReplyQuoteIsLightAndNamesTheOwnerYou() {
        let m = MessageFactory.message(id: "$r", network: "signal", sender: "Priya Natarajan", text: "Sounds good", replyTo: (sender: "You", snippet: "Shall we meet at 7?"))
        XCTAssertEqual(ReplyQuote.name(m.replyTo!), "You")
        XCTAssertEqual(ReplyQuote.name(.init(messageId: "$x", snippet: "", senderName: " ")), "Message")
        let mine = MessageFactory.message(id: "$s", network: "signal", outgoing: true, text: "Perfect", replyTo: (sender: "Priya Natarajan", snippet: "Sounds good"))
        Snapshot.assert(rows([(m, .single), (mine, .single)]), named: "replyQuoteLight")
    }

    func testOmniAgentSenderIsIncomingOmni() throws {
        var m = MessageFactory.message(id: "$o", network: "telegram", sender: "Omni Bot", text: "Your morning brief is ready")
        m.sender.isOmni = true
        XCTAssertFalse(m.sender.isSelf)
        XCTAssertEqual(m.sender.shownName, "Omni")
        XCTAssertTrue(m.sender.isOmniAgent)
        XCTAssertEqual(BubbleFill(message: m), .incoming, "never the owner's blue")
        XCTAssertTrue(MessageBubble.accessibilityLabel(for: m, selfIDs: []).hasPrefix("Omni"))
        Snapshot.assert(rows([(m, .single)]), named: "omniAgentIncoming")
    }
}
