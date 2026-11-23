import CommsClient
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

@MainActor
final class TimelineStoreTests: XCTestCase {
    private let base = PrismJSON.parseDate("2026-11-20T14:00:00Z")!
    private func m(_ id: String, minute: Int, text: String = "Hello", sender: String = "Alex", thread: String = "th_a") -> CommsMessage {
        FixtureMessages.message(id: id, threadID: thread, sender: sender, at: base.addingTimeInterval(Double(minute) * 60), text: text)
    }

    private func messageIDs(_ store: TimelineStore) -> [String] {
        store.rows.compactMap { if case .message(let msg, _, _, _) = $0 { msg.id } else { nil } }
    }

    private func message(_ store: TimelineStore, _ id: String) -> CommsMessage? {
        for case .message(let msg, _, _, _) in store.rows where msg.id == id { return msg }
        return nil
    }

    private func makeStore(_ pages: [String?: CommsMessagePage]) throws -> (TimelineStore, FixtureBackend) {
        let backend = try FixtureBackend()
        backend.setMessagePages(pages, threadID: "th_a")
        return (TimelineStore(backend: backend, threadID: "th_a"), backend)
    }

    func testLoadLatestShowsNewestPageWithTimeHeader() async throws {
        let (store, backend) = try makeStore([nil: FixtureMessages.page([m("m1", minute: 0), m("m2", minute: 1)], before: nil, hasMore: false)])
        await store.loadLatest()
        XCTAssertEqual(messageIDs(store), ["m1", "m2"])
        if case .time = store.rows.first {} else { XCTFail("the first row is a time header") }
        XCTAssertFalse(store.hasMore)
        XCTAssertNil(store.sourceError)
        XCTAssertEqual(backend.messageRequests.map(\.before), [nil])
    }

    func testLoadOlderPrependsWithoutDuplicates() async throws {
        let (store, backend) = try makeStore([
            nil: FixtureMessages.page([m("m3", minute: 3), m("m4", minute: 4), m("m5", minute: 5)], before: "c1", hasMore: true),
            "c1": FixtureMessages.page([m("m1", minute: 1), m("m2", minute: 2), m("m3", minute: 3)], before: "c2", hasMore: true),
            // The server can answer an empty page that still has more (everything in it was
            // folded away): keep paging instead of stopping.
            "c2": FixtureMessages.page([], before: "c3", hasMore: true),
            "c3": FixtureMessages.page([m("m0", minute: 0)], before: nil, hasMore: false),
        ])
        await store.loadLatest()
        XCTAssertEqual(messageIDs(store), ["m3", "m4", "m5"])
        XCTAssertTrue(store.hasMore)

        await store.loadOlder()
        XCTAssertEqual(messageIDs(store), ["m1", "m2", "m3", "m4", "m5"], "the overlapping m3 is not shown twice")
        XCTAssertTrue(store.hasMore)

        await store.loadOlder()
        XCTAssertEqual(messageIDs(store), ["m0", "m1", "m2", "m3", "m4", "m5"], "an empty page with hasMore is paged through")
        XCTAssertFalse(store.hasMore)

        await store.loadOlder()
        XCTAssertEqual(backend.messageRequests.map(\.before), [nil, "c1", "c2", "c3"], "nothing is requested past the end")
    }

    func testConcurrentLoadOlderRequestsOnce() async throws {
        let (store, backend) = try makeStore([
            nil: FixtureMessages.page([m("m2", minute: 2)], before: "c1", hasMore: true),
            "c1": FixtureMessages.page([m("m1", minute: 1)], before: nil, hasMore: false),
        ])
        await store.loadLatest()
        async let a: Void = store.loadOlder()
        async let b: Void = store.loadOlder()
        _ = await (a, b)
        XCTAssertEqual(backend.messageRequests.map(\.before), [nil, "c1"])
        XCTAssertEqual(messageIDs(store), ["m1", "m2"])
    }

    func testMessageUpdatedReplacesInPlace() async throws {
        let (store, _) = try makeStore([nil: FixtureMessages.page([m("m1", minute: 0), m("m2", minute: 1, text: "tpyo"), m("m3", minute: 2)], before: nil, hasMore: false)])
        await store.loadLatest()
        let before = store.rows.map(\.id)

        let edited = FixtureMessages.message(id: "m2", threadID: "th_a", at: base.addingTimeInterval(60), text: "typo", editedAt: base.addingTimeInterval(90))
        store.apply(FixtureMessages.event(.messageUpdated, edited))
        XCTAssertEqual(store.rows.map(\.id), before, "an edit keeps the message's place")
        XCTAssertEqual(message(store, "m2")?.body?.plain, "typo")
        XCTAssertNotNil(message(store, "m2")?.editedAt)

        let reacted = FixtureMessages.message(id: "m2", threadID: "th_a", at: base.addingTimeInterval(60), text: "typo",
                                              editedAt: base.addingTimeInterval(90), reactions: [.init("👍", count: 2)])
        store.apply(FixtureMessages.event(.reactionChanged, reacted))
        XCTAssertEqual(store.rows.map(\.id), before)
        XCTAssertEqual(message(store, "m2")?.reactions.map(\.count), [2])
    }

    func testCreatedAppendsDeletedRedactsAndOtherThreadsAreIgnored() async throws {
        let (store, _) = try makeStore([nil: FixtureMessages.page([m("m1", minute: 0), m("m2", minute: 1)], before: nil, hasMore: false)])
        await store.loadLatest()

        store.apply(FixtureMessages.event(.messageCreated, m("m3", minute: 2)))
        XCTAssertEqual(messageIDs(store), ["m1", "m2", "m3"])
        store.apply(FixtureMessages.event(.messageCreated, m("m3", minute: 2)))
        XCTAssertEqual(messageIDs(store), ["m1", "m2", "m3"], "a repeated create is not shown twice")

        store.apply(FixtureMessages.event(.messageCreated, m("x1", minute: 3, thread: "th_other")))
        XCTAssertEqual(messageIDs(store), ["m1", "m2", "m3"], "another thread's events are ignored")

        // A delete that carries only the id still marks the message unsent.
        store.apply(CommsEvent(id: "e9", kind: .messageDeleted, payload: ["threadId": "th_a", "messageId": "m1"]))
        XCTAssertEqual(message(store, "m1")?.redacted, true)
        XCTAssertEqual(messageIDs(store), ["m1", "m2", "m3"], "an unsent message keeps its row (\"… unsent a message\")")
    }

    func testCreatedOutOfOrderIsPlacedBySendTime() async throws {
        let (store, _) = try makeStore([nil: FixtureMessages.page([m("m1", minute: 0), m("m3", minute: 2)], before: nil, hasMore: false)])
        await store.loadLatest()
        store.apply(FixtureMessages.event(.messageCreated, m("m2", minute: 1)))
        XCTAssertEqual(messageIDs(store), ["m1", "m2", "m3"])
    }

    func testSourceErrorSetOn503AndClearsOnRetry() async throws {
        let (store, backend) = try makeStore([nil: FixtureMessages.page([m("m1", minute: 0)], before: nil, hasMore: false)])
        backend.setMessagesError(CommsError.sourceUnavailable(network: .whatsapp))
        await store.loadLatest()
        XCTAssertEqual(store.sourceError, "Can't reach WhatsApp right now")
        XCTAssertTrue(store.rows.isEmpty)

        backend.setMessagesError(nil)
        await store.retry()
        XCTAssertNil(store.sourceError)
        XCTAssertEqual(messageIDs(store), ["m1"])
    }

    func testSourceErrorOnOlderPageKeepsWhatIsShown() async throws {
        let (store, backend) = try makeStore([
            nil: FixtureMessages.page([m("m2", minute: 2)], before: "c1", hasMore: true),
            "c1": FixtureMessages.page([m("m1", minute: 1)], before: nil, hasMore: false),
        ])
        await store.loadLatest()
        backend.setMessagesError(CommsError.sourceUnavailable(network: .telegram))
        await store.loadOlder()
        XCTAssertEqual(store.sourceError, "Can't reach Telegram right now")
        XCTAssertEqual(messageIDs(store), ["m2"])
        XCTAssertTrue(store.hasMore, "the cursor is kept so a retry can continue")

        backend.setMessagesError(nil)
        await store.retry()
        XCTAssertNil(store.sourceError)
        XCTAssertEqual(messageIDs(store), ["m1", "m2"], "retrying after an older-page failure pages again")
    }

    func testResetReloadsLatest() async throws {
        let (store, backend) = try makeStore([nil: FixtureMessages.page([m("m1", minute: 0)], before: nil, hasMore: false)])
        await store.loadLatest()
        backend.setMessagePages([nil: FixtureMessages.page([m("m1", minute: 0), m("m2", minute: 1)], before: nil, hasMore: false)], threadID: "th_a")
        store.apply(CommsEvent(id: nil, kind: .reset, payload: .null))
        await store.pendingWork?.value
        XCTAssertEqual(messageIDs(store), ["m1", "m2"])
    }

    func testThreadUpdatedBurstRefetchesTheHeaderOnce() async throws {
        let backend = try FixtureBackend()
        backend.setMessagePages([nil: FixtureMessages.page([m("m1", minute: 0)], before: nil, hasMore: false)], threadID: "th_a")
        backend.setThreadDetail(FixtureMessages.detail(FixtureMessages.thread(id: "th_a", title: "Renamed")))
        let store = TimelineStore(backend: backend, threadID: "th_a", refetchDelay: .milliseconds(20))
        await store.loadLatest()
        let before = backend.threadCalls
        for i in 0..<40 { store.apply(CommsEvent(id: "u\(i)", kind: .threadUpdated, payload: ["threadId": "th_a"])) }
        await store.pendingWork?.value
        XCTAssertEqual(backend.threadCalls - before, 1)
        XCTAssertEqual(store.thread?.title, "Renamed")
    }

    func testGroupKindComesFromThreadDetail() async throws {
        let (store, backend) = try makeStore([nil: FixtureMessages.page([
            m("a1", minute: 0, sender: "Alice"), m("a2", minute: 1, sender: "Alice"),
        ], before: nil, hasMore: false)])
        backend.setThreadDetail(FixtureMessages.detail(FixtureMessages.thread(id: "th_a", title: "Trail Crew", kind: "group", network: "telegram")))
        await store.loadLatest()
        XCTAssertEqual(store.thread?.title, "Trail Crew")
        XCTAssertTrue(store.isGroup)
        guard case .message(_, _, let name, _)? = store.rows.dropFirst().first else { return XCTFail("expected a message row") }
        XCTAssertTrue(name, "group runs show the sender's name")
    }

    // MARK: Paging never dead-ends

    /// `count` empty pages with `hasMore`, chained e1 → e2 → …, then `last` at the end.
    private func emptyChain(from start: Int, count: Int, then last: CommsMessagePage) -> [String?: CommsMessagePage] {
        var pages: [String?: CommsMessagePage] = [:]
        for i in start..<(start + count) { pages["e\(i)"] = FixtureMessages.page([], before: "e\(i + 1)", hasMore: true) }
        pages["e\(start + count)"] = last
        return pages
    }

    func testLoadLatestStallsAfterTheEmptyPageCapAndLoadEarlierContinues() async throws {
        var pages = emptyChain(from: 1, count: 25, then: FixtureMessages.page([m("m1", minute: 1)], before: nil, hasMore: false))
        pages[nil] = FixtureMessages.page([], before: "e1", hasMore: true)
        let (store, backend) = try makeStore(pages)

        await store.loadLatest()
        XCTAssertEqual(backend.messageRequests.count, 1 + TimelineStore.maxEmptyPages, "the newest page plus 20 empty follow-ups, then stop")
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertTrue(store.hasMore)
        XCTAssertTrue(store.isStalled, "an empty transcript with more history offers Load Earlier, not No Messages")

        await store.loadOlder() // the Load Earlier button
        XCTAssertEqual(messageIDs(store), ["m1"])
        XCTAssertFalse(store.isStalled)
        XCTAssertFalse(store.hasMore)
        XCTAssertEqual(store.olderLoadCount, 1)
    }

    func testLoadOlderThatAddsNothingStallsAndStillReportsCompletion() async throws {
        var pages: [String?: CommsMessagePage] = [nil: FixtureMessages.page([m("m9", minute: 9)], before: "d0", hasMore: true)]
        // Every older page repeats the message already shown.
        for i in 0..<30 { pages["d\(i)"] = FixtureMessages.page([m("m9", minute: 9)], before: "d\(i + 1)", hasMore: true) }
        let (store, backend) = try makeStore(pages)
        await store.loadLatest()
        let rows = store.rows

        await store.loadOlder()
        XCTAssertEqual(backend.messageRequests.count, 1 + 1 + TimelineStore.maxEmptyPages)
        XCTAssertEqual(store.rows, rows)
        XCTAssertTrue(store.isStalled, "pages of duplicates count as empty")
        XCTAssertEqual(store.olderLoadCount, 1)

        backend.setMessagesError(CommsError.sourceUnavailable(network: .whatsapp))
        await store.loadOlder()
        XCTAssertEqual(store.olderLoadCount, 2, "a failed load also reports completion")
        XCTAssertNotNil(store.sourceError)
    }

    func testALiveMessageOrAFreshLoadClearsTheStall() async throws {
        var pages: [String?: CommsMessagePage] = [nil: FixtureMessages.page([m("m9", minute: 9)], before: "d0", hasMore: true)]
        for i in 0..<30 { pages["d\(i)"] = FixtureMessages.page([m("m9", minute: 9)], before: "d\(i + 1)", hasMore: true) }

        let (live, _) = try makeStore(pages)
        await live.loadLatest()
        await live.loadOlder()
        XCTAssertTrue(live.isStalled)
        live.apply(FixtureMessages.event(.messageCreated, m("m10", minute: 10)))
        XCTAssertFalse(live.isStalled, "a live message drops the stale Load Earlier pill")

        let (reload, backend) = try makeStore(pages)
        await reload.loadLatest()
        await reload.loadOlder()
        XCTAssertTrue(reload.isStalled)
        backend.setMessagePages([nil: FixtureMessages.page([m("m9", minute: 9), m("m10", minute: 10)], before: "d0", hasMore: true)], threadID: "th_a")
        await reload.loadLatest()
        XCTAssertFalse(reload.isStalled, "a fresh newest page clears the stall")
    }

    func testRefreshLatestMergesTheNewestPageAndKeepsOlderHistory() async throws {
        let (store, backend) = try makeStore([
            nil: FixtureMessages.page([m("m3", minute: 3), m("m4", minute: 4)], before: "c1", hasMore: true),
            "c1": FixtureMessages.page([m("m1", minute: 1), m("m2", minute: 2)], before: nil, hasMore: false),
        ])
        await store.loadLatest()
        await store.loadOlder()
        XCTAssertEqual(messageIDs(store), ["m1", "m2", "m3", "m4"])
        // Back from the background: m4 was edited and m5, m6 arrived; the page still holds m4.
        backend.setMessagePages([
            nil: FixtureMessages.page([m("m4", minute: 4, text: "edited"), m("m5", minute: 5), m("m6", minute: 6)], before: "c0", hasMore: true),
            "c1": FixtureMessages.page([m("m1", minute: 1), m("m2", minute: 2)], before: nil, hasMore: false),
        ], threadID: "th_a")
        await store.refreshLatest()
        XCTAssertEqual(messageIDs(store), ["m1", "m2", "m3", "m4", "m5", "m6"], "older pages kept, newer merged")
        XCTAssertEqual(message(store, "m4")?.body?.plain, "edited")
        XCTAssertFalse(store.hasMore, "the older cursor is unchanged: history was already complete")
    }

    func testRefreshLatestResetsWhenTheNewestPageNoLongerOverlaps() async throws {
        let (store, backend) = try makeStore([
            nil: FixtureMessages.page([m("m3", minute: 3), m("m4", minute: 4)], before: "c1", hasMore: true),
        ])
        await store.loadLatest()
        backend.setMessagePages([
            nil: FixtureMessages.page([m("m90", minute: 90), m("m91", minute: 91)], before: "c9", hasMore: true),
        ], threadID: "th_a")
        await store.refreshLatest()
        XCTAssertEqual(messageIDs(store), ["m90", "m91"], "a gap bigger than a page resets to the newest page")
        XCTAssertTrue(store.hasMore)
    }
}
