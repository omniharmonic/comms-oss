@testable import CommsUI
import CommsCore
import PrismModels
import SwiftUI
import XCTest

/// The message interaction menu and reactions UI: the tapback picker, the action menu, the
/// reaction details list, the reply banner, the overlay geometry and what each message offers.
@MainActor
final class ReactionInteractionTests: XCTestCase {
    typealias M = MessageFactory

    // MARK: Snapshots

    func testTapbackPicker() {
        let view = VStack(spacing: 16) {
            TapbackPicker(selected: []) { _ in }
            TapbackPicker(selected: ["❤️"]) { _ in }
            TapbackPicker(selected: ["😂"], recents: ["🔥"]) { _ in }
        }
        .padding(20)
        Snapshot.assertHosted(view, named: "tapbackPicker", width: 420)
    }

    /// The colourful picker glyphs (not the monochrome badges).
    func testTapbackGlyphs() {
        let view = HStack(spacing: 8) {
            ForEach(Tapbacks.keys + ["🔥"], id: \.self) { TapbackGlyph(key: $0, size: 30) }
        }
        Snapshot.assert(view, named: "tapbackGlyphs", width: 360)
    }

    func testMessageActionMenu() {
        let groups: [[MessageMenuItem]] = [[.init(kind: .reply)], [.init(kind: .copy), .init(kind: .translate), .init(kind: .select)]]
        Snapshot.assertHosted(MessageActionMenu(groups: groups) { _ in }.padding(20), named: "messageActionMenu", width: 300)
    }

    func testReactionDetails() {
        let few = [
            ReactionPerson(id: "self", name: "You", isSelf: true, keys: ["❤️"]),
            ReactionPerson(id: "@a", name: "Alex Rivera", isSelf: false, keys: ["😂", "👍"]),
        ]
        Snapshot.assertHosted(ReactionDetailsView(people: few, compact: true).padding(12), named: "reactionDetailsCard", width: 260)
        let many = few + [
            ReactionPerson(id: "@b", name: "Sam Ortiz", isSelf: false, keys: ["‼️"]),
            ReactionPerson(id: "@c", name: "Noor Haddad", isSelf: false, keys: ["❓"]),
            ReactionPerson(id: "others-❤️", name: "2 others", isSelf: false, keys: ["❤️"]),
        ]
        Snapshot.assertHosted(ReactionDetailsView(people: many, compact: false).padding(12), named: "reactionDetailsList", width: 320)
    }

    func testReplyBanner() {
        let m = M.message(sender: "Alex", text: "Who is coming on Saturday?")
        Snapshot.assertHosted(ReplyComposeBanner(message: m) {}.padding(.vertical, 12), named: "replyComposeBanner", width: 380)
    }

    func testReplyBannerWithNote() {
        let m = M.message(sender: "Alex", text: "Who is coming on Saturday?")
        Snapshot.assertHosted(ReplyComposeBanner(message: m, note: "Sent as a normal message — iMessage threaded replies aren't available") {}
            .padding(.vertical, 12), named: "replyComposeBannerNote", width: 380)
    }

    /// The Mac message overlay (right-click / Control-click / Force Touch): lifted bubble,
    /// backdrop, tapback bar above, menu below with Show Reactions…, light and dark.
    func testMacMessageOverlay() {
        let m = M.message(sender: "Alex", text: "Dinner at eight?", reactions: [.init(key: "❤️", mine: true), .init(key: "😂", names: ["Sam"])])
        let interactions = MessageInteractions(message: { _ in m }, canReact: { _ in true }, canReply: { _ in true })
        let ctx = MessageOverlayContext(
            message: m, position: .single, isGroup: false,
            rowFrame: CGRect(x: 16, y: 170, width: 568, height: 70), contentFrame: CGRect(x: 16, y: 170, width: 180, height: 70),
            screen: CGSize(width: 600, height: 420), safeTop: 52, safeBottom: 8, metrics: .mac, maxWidth: 400,
            mediaLoader: .placeholder, avatarLoader: nil, selfSenderIDs: [M.selfID], gradientHeight: 900)
        Snapshot.assertHosted(MessageInteractionOverlay(context: ctx, mode: .menu, interactions: interactions) {}, named: "macMessageOverlay", width: 600)
    }

    func testMacMenuOffersShowReactionsInsteadOfSelect() {
        let text = M.message(text: "Dinner at eight?", reactions: [.init(key: "❤️")])
        let reply = MessageInteractions(canReply: { _ in true })
        XCTAssertEqual(MessageMenuItem.groups(for: text, interactions: reply, platformSelect: false, showReactions: true).map { $0.map(\.kind) },
                       [[.reply], [.copy, .translate], [.showReactions]])
    }

    // MARK: What a message offers

    func testMenuGroupsFollowTheMessageAndCapabilities() {
        let text = M.message(text: "Dinner at eight?")
        let photo = M.message(text: nil, attachments: [M.image(w: 4, h: 3)])
        let reply = MessageInteractions(canReply: { _ in true })
        XCTAssertEqual(MessageMenuItem.groups(for: text, interactions: reply, platformSelect: true).map { $0.map(\.kind) },
                       [[.reply], [.copy, .translate, .select]])
        XCTAssertEqual(MessageMenuItem.groups(for: text, interactions: .none, platformSelect: false).map { $0.map(\.kind) },
                       [[.copy, .translate]], "no Reply where the channel has none; Select is iOS-only")
        XCTAssertEqual(MessageMenuItem.groups(for: photo, interactions: reply, platformSelect: true).map { $0.map(\.kind) }, [[.reply]],
                       "nothing to copy on a photo")
    }

    /// Review M5: keycaps and ©/™ with the emoji selector count; letters and bare digits don't.
    func testEmojiKeyboardAcceptsEveryEmoji() {
        for e in ["😀", "❤️", "1️⃣", "#️⃣", "©️", "™️", "👍🏽", "🏳️‍🌈"] { XCTAssertTrue(RecentReactions.isEmoji(Character(e)), e) }
        for t in ["a", "1", "#", "©"] { XCTAssertFalse(RecentReactions.isEmoji(Character(t)), t) }
    }

    func testSpokenNames() {
        XCTAssertEqual(Tapbacks.keys.compactMap { ClassicTapback(key: $0)?.spokenName },
                       ["Heart", "Thumbs Up", "Thumbs Down", "Ha Ha", "Exclamation Marks", "Question Mark"])
        XCTAssertEqual(ReactionDetailsView.spoken(ReactionPerson(id: "@a", name: "Alex", isSelf: false, keys: ["❤️", "🔥"])), "Alex: Heart, 🔥")
    }

    func testStoreInteractionsReachTheStore() async throws {
        let backend = try FixtureBackendFactory.reacting()
        let store = TimelineStore(backend: backend, threadID: "th_x")
        await store.loadLatest()
        let i = MessageInteractions.store(store)
        let m = try XCTUnwrap(i.message("$x1"))
        XCTAssertTrue(i.canReact(m))
        i.react("👍", "$x1")
        for _ in 0..<100 where backend.reactionCalls.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(backend.reactionCalls.first?.key, "👍")
        XCTAssertEqual(i.people("$x1").first?.name, "You")
    }

    // MARK: Overlay geometry (iPhone 17: 402 × 874, safe 62 / 34)

    let screen = CGSize(width: 402, height: 874)

    func testOverlayKeepsAShortBubbleWhereItIsWhenEverythingFits() {
        let content = CGRect(x: 180, y: 400, width: 206, height: 40)
        let g = MessageOverlayGeometry.layout(content: content, screen: screen, safeTop: 62, safeBottom: 34, outgoing: true,
                                              bar: CGSize(width: 288, height: 58), menu: CGSize(width: 250, height: 200), lifts: true)
        XCTAssertEqual(g.shift, 0)
        XCTAssertEqual(g.barOrigin.y, 400 - 8 - 58, "bar just above the bubble")
        XCTAssertEqual(g.barOrigin.x + 288, 386, accuracy: 0.5, "outgoing: bar ends at the bubble's trailing edge")
        XCTAssertEqual(g.menuOrigin, CGPoint(x: 386 - 250, y: 448), "menu under the bubble, trailing-aligned")
        XCTAssertEqual(g.moreOrigin.x, 180 - 8 - 12 - MessageOverlayGeometry.moreSize, "the smiley beside the bubble, never over its text")
    }

    func testOverlayLiftsABubbleNearTheBottomSoTheMenuFits() {
        let content = CGRect(x: 16, y: 760, width: 200, height: 40)
        let g = MessageOverlayGeometry.layout(content: content, screen: screen, safeTop: 62, safeBottom: 34, outgoing: false,
                                              bar: CGSize(width: 288, height: 58), menu: CGSize(width: 250, height: 200), lifts: true)
        XCTAssertLessThan(g.shift, 0)
        XCTAssertEqual(g.menuOrigin.y + 200, 874 - 34 - 8, accuracy: 0.5)
        XCTAssertEqual(g.barOrigin.x, 16, "incoming: bar starts at the bubble's leading edge")
        XCTAssertEqual(g.moreOrigin.x, 216 + 8 + 12, "incoming: the smiley to the bubble's right")
    }

    func testOverlayPinsTheBarForATallBubbleAndOverlapsTheMenu() {
        let content = CGRect(x: 90, y: 100, width: 296, height: 760)
        let g = MessageOverlayGeometry.layout(content: content, screen: screen, safeTop: 62, safeBottom: 34, outgoing: true,
                                              bar: CGSize(width: 288, height: 58), menu: CGSize(width: 250, height: 200), lifts: true)
        XCTAssertEqual(g.barOrigin.y, 62 + 8, "bar pinned under the status bar")
        XCTAssertEqual(g.menuOrigin.y + 200, 874 - 34 - 8, accuracy: 0.5, "menu pinned at the bottom, over the bubble")
    }

    func testTapbackModeNeverMovesTheBubble() {
        let content = CGRect(x: 16, y: 80, width: 200, height: 40)
        let g = MessageOverlayGeometry.layout(content: content, screen: screen, safeTop: 62, safeBottom: 34, outgoing: false,
                                              bar: CGSize(width: 288, height: 58), menu: nil, lifts: false)
        XCTAssertEqual(g.shift, 0)
        XCTAssertEqual(g.barOrigin.y, 70, "clamped under the status bar")
    }
}

import CommsTestSupport

/// A WhatsApp thread with one incoming message that can take reactions.
enum FixtureBackendFactory {
    static func reacting() throws -> FixtureBackend {
        let backend = try FixtureBackend()
        var thread = FixtureMessages.thread(id: "th_x", title: "Sam")
        thread.channels[0].capabilities = CommsChannelCapabilities(react: true, reply: true, send: true)
        backend.upsertThread(thread)
        backend.setMessagePages([nil: FixtureMessages.page([
            FixtureMessages.message(id: "$x1", threadID: "th_x", sender: "Sam", at: Date(timeIntervalSince1970: 1_800_000_000), text: "Hi"),
        ], before: nil, hasMore: false)], threadID: "th_x")
        backend.setReactionEcho(.none)
        return backend
    }
}
