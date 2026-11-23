import CommsClient
import CommsTestSupport
import Foundation
import SwiftUI
import XCTest
@testable import CommsCore
@testable import CommsUI

/// Telegram forums: the list row (one row, "# 21" topic count), the transcript's topic switcher
/// pill (All Topics / a topic, unread dot), and the "# Dev" label over a run in All Topics.
@MainActor
final class ForumSnapshotTests: XCTestCase {
    override func setUp() async throws { ListSamples.seedAvatars() }

    private var forum: CommsThread {
        var t = ListSamples.thread("f1", title: "Trailhead Collective", kind: .group,
                                   avatar: .monogram("TC", members: []), networks: [.telegram],
                                   preview: "Gear · Eli: I do — I'll leave it at the shop.", minutesAgo: 12, unread: 3)
        t.forum = .init(topicCount: 21)
        return t
    }
    private let topics = [
        CommsTopic(id: "tp_gear", title: "Gear", lastActivityAt: ListSamples.now, unread: 2),
        CommsTopic(id: "tp_general", title: "General", lastActivityAt: ListSamples.now, unread: 0),
        CommsTopic(id: "tp_rides", title: "Rides", lastActivityAt: ListSamples.now, unread: 1),
    ]

    func testForumRow() {
        ListSnapshot.assert(ThreadRow(thread: forum, isSelected: false, now: ListSamples.now), named: "rowForumTopicCount")
        ListSnapshot.assert(ThreadRow(thread: forum, isSelected: true, now: ListSamples.now), named: "rowForumTopicCountSelected")
        XCTAssertEqual(ThreadRow.accessibilityLabel(for: forum, time: nil), "Trailhead Collective, Telegram, 3 unread messages, forum, 21 topics")
    }

    func testTopicSwitcherPill() {
        Snapshot.assertHosted(ForumTopicSwitcher(topics: topics, selected: nil) { _ in }.padding(8), named: "topicSwitcherAll", width: 200)
        Snapshot.assertHosted(ForumTopicSwitcher(topics: topics, selected: topics[1]) { _ in }.padding(8), named: "topicSwitcherGeneralUnreadElsewhere", width: 200)
        XCTAssertEqual(ForumTopicSwitcher.symbol(topics[0], selected: false), "circle.fill", "unread topics carry Messages' dot")
        XCTAssertEqual(ForumTopicSwitcher.symbol(topics[1], selected: false), "number")
        XCTAssertEqual(ForumTopicSwitcher.symbol(topics[1], selected: true), "checkmark")
        XCTAssertEqual(ForumTopicSwitcher.menuTitle(topics[0], selected: false), "Gear (2)")
        XCTAssertEqual(ForumTopicSwitcher.accessibilityTitle(topics[2]), "Rides, 1 unread message")
        XCTAssertEqual(ForumTopicSwitcher.pillLabel(topics, selected: topics[1]), "Topic General, other topics have unread messages")
        XCTAssertEqual(ForumTopicSwitcher.pillLabel(topics, selected: nil), "All Topics")
    }

    func testTopicLabelsOverRuns() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var incoming = FixtureMessages.message(id: "$a", network: "telegram", sender: "Eli Brooks", at: t0, text: "I do — I'll leave it at the shop.")
        incoming.topic = CommsTopicRef(id: "tp_gear", title: "Gear")
        var outgoing = FixtureMessages.message(id: "$b", network: "telegram", outgoing: true, at: t0, text: "Thanks!", delivery: "sent")
        outgoing.topic = CommsTopicRef(id: "tp_rides", title: "Rides")
        Snapshot.assert(MessageBubble(message: incoming, position: .single, isGroup: true), named: "topicLabelIncomingGroup")
        Snapshot.assert(MessageBubble(message: outgoing, position: .single, isGroup: true), named: "topicLabelOutgoing")
        XCTAssertEqual(MessageBubble.accessibilityLabel(for: incoming), "Eli Brooks in Gear: I do — I'll leave it at the shop.")
        var plain = incoming
        plain.topic = nil
        XCTAssertFalse(MessageBubble.accessibilityLabel(for: plain).contains(" in "))
    }

    func testComposeTargetChip() {
        let target = CommsTopicRef(id: "tp_general", title: "General")
        Snapshot.assertHosted(ForumComposeTargetChip(target: target, topics: topics, locked: false) { _ in }.padding(8), named: "composeTopicChip", width: 200)
        Snapshot.assertHosted(ForumComposeTargetChip(target: target, topics: topics, locked: true) { _ in }.padding(8), named: "composeTopicChipLocked", width: 200)
    }

    func testComposerPlaceholderNamesTheTopic() {
        Snapshot.assertHosted(ComposerBar(network: .telegram, canSend: true, placeholder: "Reply in #General").padding(.vertical, 12),
                              named: "composerReplyInTopic", width: 460)
    }
}
