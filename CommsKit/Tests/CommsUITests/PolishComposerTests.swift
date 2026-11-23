import CommsClient
import CommsCore
import CommsTestSupport
@testable import CommsUI
import SwiftUI
import XCTest

/// Task 5 composer pieces: the merged conversation's "WhatsApp ⌄", `@` suggestions, mention
/// bubbles and the Mac emoji circle.
@MainActor
final class PolishComposerTests: XCTestCase {
    static let width: CGFloat = 460
    static let caps = CommsChannelCapabilities(send: true)
    static let channels = [CommsChannelRef(network: .whatsapp, capabilities: caps), CommsChannelRef(network: .telegram, accountLabel: "Work", capabilities: caps)]
    static let members = [CommsMember(id: "@wa_1:hs", name: "Sam Rivera"), CommsMember(id: "@wa_2:hs", name: "Samira Patel"), CommsMember(id: "@wa_3:hs", name: "Ana Diaz")]

    func testChannelPickerPlaceholder() {
        let bar = ComposerBar(network: .whatsapp, canSend: true, channelChoices: Self.channels, selectedChannel: Self.channels[0])
        XCTAssertTrue(bar.showsChannelPicker)
        XCTAssertEqual(ComposerBar.channelName(Self.channels[1]), "Telegram (Work)")
        XCTAssertEqual(ComposerBar.channelName(CommsChannelRef(network: .imessage)), "iMessage")
        Snapshot.assertHosted(bar.padding(.vertical, 12), named: "composerChannelPicker", width: Self.width)
        // One channel: the plain placeholder.
        XCTAssertFalse(ComposerBar(network: .whatsapp, canSend: true, channelChoices: [Self.channels[0]]).showsChannelPicker)
        // Typing hides it (the text takes the field).
        XCTAssertFalse(ComposerBar(network: .whatsapp, canSend: true, draft: "hi", channelChoices: Self.channels).showsChannelPicker)
    }

    func testMentionSuggestionsAppearForAnAtQuery() {
        let candidates: @MainActor (String) -> [CommsMember] = { MentionText.candidates(Self.members, query: $0, excluding: []) }
        let typing = ComposerBar(network: .whatsapp, canSend: true, draft: "Lunch @sa", mentionCandidates: candidates)
        XCTAssertEqual(typing.suggestions.map(\.name), ["Sam Rivera", "Samira Patel"])
        XCTAssertTrue(ComposerBar(network: .whatsapp, canSend: true, draft: "Lunch sa", mentionCandidates: candidates).suggestions.isEmpty)
        XCTAssertTrue(ComposerBar(network: .whatsapp, canSend: true, draft: "Lunch @sa").suggestions.isEmpty, "no mentions offered")
        Snapshot.assertHosted(typing.padding(.vertical, 12), named: "composerMentionSuggestions", width: Self.width)
    }

    func testMentionBubbleIsBold() {
        let text = "Sam Rivera are you coming?"
        let m = MessageFactory.message(network: "whatsapp", outgoing: true, spans: MentionText.richText(text, mentions: [CommsMention(userId: "@wa_1:hs", start: 0, length: 10)]).spans)
        Snapshot.assert(MessageBubble(message: m, position: .single, isGroup: true), named: "bubbleMention")
    }

    func testMacEmojiCircleOpensTheCharacterPalette() {
        var opened = 0
        let saved = ComposerBar.openEmojiPalette
        ComposerBar.openEmojiPalette = { opened += 1 }
        defer { ComposerBar.openEmojiPalette = saved }
        #if os(macOS)
        XCTAssertTrue(ComposerBar.showsEmojiButton, "the Mac composer has the emoji circle")
        #endif
        ComposerBar.emojiCircleTapped()
        XCTAssertEqual(opened, 1, "the circle opens the Character Viewer")
    }

    #if os(macOS)
    static func find(in elements: [Any], id: String) -> NSObject? {
        for case let e as NSObject in elements {
            if (e.value(forKey: "accessibilityIdentifier") as? String) == id { return e }
            if let children = e.value(forKey: "accessibilityChildren") as? [Any], let found = find(in: children, id: id) { return found }
        }
        return nil
    }
    #endif
}
