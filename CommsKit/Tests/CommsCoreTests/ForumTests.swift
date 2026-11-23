import CommsClient
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

/// Telegram forums: one thread, All Topics (labelled, runs split by topic) and one-topic views,
/// sends that always name a concrete topic (the selected one, else the newest message's), the
/// composer's "Reply in #…", live messages of other topics kept out of a topic view.
@MainActor
final class ForumTests: XCTestCase {
    private func makeStore() async throws -> (TimelineStore, FixtureBackend) {
        let backend = try FixtureBackend()
        DemoForum.install(on: backend, before: PrismJSON.parseDate("2026-11-20T14:00:00Z")!)
        backend.setSendEcho(.none)
        let store = TimelineStore(backend: backend, threadID: DemoForum.threadID, thread: backend.currentThread(id: DemoForum.threadID))
        await store.loadLatest()
        return (store, backend)
    }

    private func messages(_ store: TimelineStore) -> [CommsMessage] {
        store.rows.compactMap { if case .message(let m, _, _, _) = $0 { m } else { nil } }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 2) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testAllTopicsLabelsEveryMessageAndOneTopicShowsOnlyItsOwn() async throws {
        let (store, backend) = try await makeStore()
        XCTAssertTrue(store.isForum)
        XCTAssertEqual(store.topics.map(\.title), ["Gear", "General", "Rides"])
        XCTAssertNil(store.selectedTopicID, "a forum opens on All Topics")
        XCTAssertEqual(backend.messageRequests.last?.topic, nil)
        let all = messages(store)
        XCTAssertEqual(all.count, 6)
        XCTAssertTrue(all.allSatisfy { $0.topic != nil }, "All Topics: every message keeps its topic (the label)")

        store.selectTopic("tp_gear")
        await store.pendingWork?.value
        XCTAssertEqual(backend.messageRequests.last?.topic, "tp_gear")
        let gear = messages(store)
        XCTAssertEqual(gear.map(\.id), ["forum_m3", "forum_m5"])
        XCTAssertTrue(gear.allSatisfy { $0.topic == nil }, "one topic on screen: no labels")
        XCTAssertEqual(store.selectedTopic?.title, "Gear")

        store.selectTopic(nil)
        await store.pendingWork?.value
        XCTAssertEqual(messages(store).count, 6)
    }

    func testSendNamesTheSelectedTopicElseTheNewestMessagesTopic() async throws {
        let (store, backend) = try await makeStore()
        // All Topics: the newest message is in Gear.
        XCTAssertEqual(store.sendTopic, CommsTopicRef(id: "tp_gear", title: "Gear"))
        XCTAssertEqual(store.composerPlaceholder, "Reply in #Gear")
        XCTAssertTrue(store.canSend)
        await store.send(text: "On it")
        XCTAssertEqual(backend.sendCalls.last?.topic, "tp_gear")

        store.selectTopic("tp_rides")
        await store.pendingWork?.value
        XCTAssertEqual(store.composerPlaceholder, "Reply in #Rides")
        await store.send(text: "See you at 8")
        XCTAssertEqual(backend.sendCalls.last?.topic, "tp_rides")
        // The pending bubble carries its topic (labelled in All Topics).
        XCTAssertEqual(store.pendingSends.last?.topic?.title, "Rides")
    }

    func testAForumNeverSendsWithoutATopic() async throws {
        let backend = try FixtureBackend()
        DemoForum.install(on: backend, before: Date())
        // A server forum whose topics are not known yet: nothing to name, nothing is sent.
        var detail = try await backend.thread(id: DemoForum.threadID)
        detail.topics = []
        backend.setThreadDetail(detail)
        backend.setMessagePages([nil: FixtureMessages.page([], before: nil, hasMore: false)], threadID: DemoForum.threadID)
        let store = TimelineStore(backend: backend, threadID: DemoForum.threadID, thread: backend.currentThread(id: DemoForum.threadID))
        await store.loadLatest()
        XCTAssertTrue(store.isForum)
        XCTAssertNil(store.sendTopic)
        XCTAssertFalse(store.canSend)
        await store.send(text: "hello")
        XCTAssertTrue(backend.sendCalls.isEmpty)
        // And the backend refuses a forum send without a topic (as the server: topic_required).
        backend.setThreadDetail(CommsThreadDetail(thread: detail.thread, topics: [CommsTopic(id: "tp_a", title: "A", lastActivityAt: Date())]))
        do {
            _ = try await backend.sendText(threadID: DemoForum.threadID, clientID: UUID().uuidString, text: "x", replyTo: nil, mentions: [], channel: nil, topic: nil)
            XCTFail("a forum send without a topic is refused")
        } catch CommsError.sendFailed(let f) {
            XCTAssertEqual(f.reason, .topicRequired)
        }
    }

    func testLiveMessagesOfAnotherTopicStayOutOfATopicView() async throws {
        let (store, _) = try await makeStore()
        store.selectTopic("tp_general")
        await store.pendingWork?.value
        let before = messages(store).count
        var other = FixtureMessages.message(id: "live_gear", threadID: DemoForum.threadID, network: "telegram", sender: "Ivy Moreno", at: Date(), text: "new gear")
        other.topic = CommsTopicRef(id: "tp_gear", title: "Gear")
        store.apply(FixtureMessages.event(.messageCreated, other))
        XCTAssertEqual(messages(store).count, before)
        var mine = other
        mine.id = "live_general"
        mine.topic = CommsTopicRef(id: "tp_general", title: "General")
        store.apply(FixtureMessages.event(.messageCreated, mine, id: "e2"))
        XCTAssertEqual(messages(store).count, before + 1)
    }

    func testRunsSplitAtATopicChange() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func m(_ id: String, _ topic: String, _ s: Double) -> CommsMessage {
            var x = FixtureMessages.message(id: id, sender: "Ann", at: t0.addingTimeInterval(s))
            x.topic = CommsTopicRef(id: topic, title: topic)
            return x
        }
        let rows = TranscriptLayout.rows(for: [m("a", "dev", 0), m("b", "dev", 10), m("c", "gen", 20)], isGroup: true, gapMinutes: 60, calendar: .current)
        let positions = rows.compactMap { if case .message(_, let p, _, _) = $0 { p } else { nil } }
        XCTAssertEqual(positions, [.first, .last, .single], "same sender, new topic: a new run (with its own label)")
    }
}

/// Fix round 1 (forums-review.md C-1, I-2, I-4).
@MainActor
final class ForumComposeTargetTests: XCTestCase {
    private func makeStore() async throws -> (TimelineStore, FixtureBackend) {
        let backend = try FixtureBackend()
        DemoForum.install(on: backend, before: PrismJSON.parseDate("2026-11-20T14:00:00Z")!)
        backend.setSendEcho(.none)
        let store = TimelineStore(backend: backend, threadID: DemoForum.threadID, thread: backend.currentThread(id: DemoForum.threadID))
        await store.loadLatest()
        return (store, backend)
    }
    private func live(_ id: String, topic: String, title: String) -> CommsEvent {
        var m = FixtureMessages.message(id: id, threadID: DemoForum.threadID, network: "telegram", sender: "Ivy Moreno", at: Date(), text: "new")
        m.topic = CommsTopicRef(id: topic, title: title)
        return FixtureMessages.event(.messageCreated, m, id: "e_\(id)")
    }

    func testTheTargetIsFrozenWhenComposingStartsAndNeverMovesWithLiveMessages() async throws {
        let (store, backend) = try await makeStore()
        XCTAssertEqual(store.composeTopic?.id, "tp_gear", "the newest message's topic while nothing is typed")
        store.composingChanged(true) // the owner starts typing
        store.apply(live("live_rides", topic: "tp_rides", title: "Rides"))
        XCTAssertEqual(store.composeTopic?.id, "tp_gear", "the chip does not move while he types")
        XCTAssertEqual(store.composerPlaceholder, "Reply in #Gear")
        await store.send(text: "Yes, approved")
        XCTAssertEqual(backend.sendCalls.last?.topic, "tp_gear", "sent where it said, not where the last message arrived")
        store.composingChanged(false)
        XCTAssertEqual(store.composeTopic?.id, "tp_rides", "an empty composer follows the conversation again")
    }

    func testTheChipPicksTheTopicAndAReplyAnswersInItsMessagesTopic() async throws {
        let (store, backend) = try await makeStore()
        store.pickComposeTopic("tp_general")
        store.composingChanged(true)
        store.apply(live("live_gear", topic: "tp_gear", title: "Gear"))
        await store.send(text: "picked")
        XCTAssertEqual(backend.sendCalls.last?.topic, "tp_general")
        // Reply to a Rides message (forum_m4) while the chip says General: the reply's topic wins.
        let rides = store.rows.compactMap { if case .message(let m, _, _, _) = $0, m.id == "forum_m4" { m } else { nil } }.first!
        store.beginReply(to: rides)
        XCTAssertEqual(store.composeTopic?.id, "tp_rides")
        await store.send(text: "count me in", replyTo: rides)
        XCTAssertEqual(backend.sendCalls.last?.topic, "tp_rides")
        // An unknown topic can't be picked.
        store.pickComposeTopic("tp_nope")
        XCTAssertEqual(store.pickedTopicID, "tp_general")
    }

    func testTheForumIsReadUpToWhatIsShownAndOneTopicAtATime() async throws {
        let (store, backend) = try await makeStore()
        let list = ThreadListStore(backend: backend)
        list.forumReadPoint = { id in store.threadID == id ? store.forumReadPoint : nil }
        store.onReadPointChange = { list.forumReadPointChanged(store.threadID) }
        list.openThreadID = DemoForum.threadID
        await list.readWork?.value
        let newest = store.rows.compactMap { if case .message(let m, _, _, _) = $0 { m.sentAt } else { nil } }.max()
        XCTAssertEqual(backend.forumReads.last?.topic, nil, "All Topics")
        XCTAssertEqual(backend.forumReads.last?.upTo, newest, "up to the newest message shown, not the forum's latest")
        store.selectTopic("tp_rides")
        await store.pendingWork?.value
        await list.readWork?.value
        XCTAssertEqual(backend.forumReads.last?.topic, "tp_rides", "a topic view reads that topic only")
        // The owner's explicit Mark as Read reads the whole forum.
        list.markRead(DemoForum.threadID)
        await list.readWork?.value
        XCTAssertTrue(backend.readCalls.last?.hasSuffix(":explicit") ?? false)
    }
}

@MainActor
final class ForumOpenReadTests: XCTestCase {
    func testOpeningAForumBeforeItsTranscriptShowsAnythingReadsNothing() async throws {
        let backend = try FixtureBackend()
        DemoForum.install(on: backend, before: Date())
        let list = ThreadListStore(backend: backend)
        await list.load()
        list.forumReadPoint = { _ in nil } // no transcript yet
        list.openThreadID = DemoForum.threadID
        await list.readWork?.value
        XCTAssertTrue(backend.forumReads.isEmpty, "nothing marked read before anything was shown")
        XCTAssertFalse(backend.readCalls.contains { $0.hasPrefix("read:\(DemoForum.threadID)") })
    }
}
