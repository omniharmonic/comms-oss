import CommsClient
import CommsCore
import CommsTestSupport
import Foundation
import os
@testable import CommsCore
import XCTest

// MARK: Synthetic threads

/// Builds a `CommsThread` from wire JSON (the model has no public memberwise initialiser).
private func makeThread(
    _ id: String,
    at seconds: TimeInterval,
    pinned: Bool = false,
    folder: String = "inbox",
    networks: [String] = ["telegram"],
    unread: Int = 0,
    title: String? = nil
) -> CommsThread {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let json: [String: Any] = [
        "id": id, "title": title ?? "Title \(id)", "titleSource": "contact",
        "avatar": ["monogram": "T"], "kind": "dm", "networks": networks,
        "lastActivityAt": iso.string(from: Date(timeIntervalSince1970: 1_795_000_000 + seconds)),
        "unread": ["count": unread, "trusted": false], "folder": folder,
        "pinned": pinned, "muted": false, "channels": [[String: Any]](),
    ]
    return try! PrismJSON.decoder().decode(CommsThread.self, from: JSONSerialization.data(withJSONObject: json))
}

private func page(_ threads: [CommsThread], next: String? = nil) -> CommsThreadPage {
    let encoded = try! JSONSerialization.jsonObject(with: PrismJSON.encoder().encode(threads))
    var body: [String: Any] = ["threads": encoded]
    if let next { body["next"] = next }
    return try! PrismJSON.decoder().decode(CommsThreadPage.self, from: JSONSerialization.data(withJSONObject: body))
}

private func threadUpdated(_ id: String, eventID: String = "e1") -> CommsEvent {
    CommsEvent(id: eventID, kind: .threadUpdated, payload: ["threadId": .string(id)])
}

/// A backend that records every `threads` query and serves programmable pages by cursor.
private final class SpyBackend: ChatBackend, @unchecked Sendable {
    private struct State {
        var pages: [String: CommsThreadPage] = [:]   // "" = first page
        var details: [String: CommsThread] = [:]
        var queries: [CommsThreadQuery] = []
        var failThreads = false
        var threadDelays: [Duration] = []
        var threadCalls: [String] = []
        var inFlight = 0
        var maxInFlight = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var queries: [CommsThreadQuery] { state.withLock { $0.queries } }
    /// Every `thread(id:)` call's id, in order.
    var threadCalls: [String] { state.withLock { $0.threadCalls } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }
    func setPage(_ p: CommsThreadPage, cursor: String? = nil) { state.withLock { $0.pages[cursor ?? ""] = p } }
    func setThread(_ t: CommsThread) { state.withLock { $0.details[t.id] = t } }
    func removeThread(_ id: String) { state.withLock { _ = $0.details.removeValue(forKey: id) } }
    func setFailThreads(_ fail: Bool) { state.withLock { $0.failThreads = fail } }
    /// Delays for the next `thread(id:)` calls (the answer is captured before the delay).
    func queueThreadDelay(_ d: Duration) { state.withLock { $0.threadDelays.append(d) } }

    func capabilities() async throws -> CommsCapabilities { FixtureBackend.validCapabilities }
    func threads(_ q: CommsThreadQuery) async throws -> CommsThreadPage {
        let (result, fail) = state.withLock { s in
            s.queries.append(q)
            return (s.pages[q.cursor ?? ""] ?? page([]), s.failThreads)
        }
        if fail { throw CommsError.sourceUnavailable(network: .telegram) }
        return result
    }
    func thread(id: String) async throws -> CommsThreadDetail {
        let (snapshot, delay) = state.withLock { s in
            s.threadCalls.append(id)
            s.inFlight += 1
            s.maxInFlight = max(s.maxInFlight, s.inFlight)
            return (s.details[id], s.threadDelays.isEmpty ? nil : s.threadDelays.removeFirst())
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        if let delay { try await Task.sleep(for: delay) }
        guard let t = snapshot else { throw CommsError.threadUnavailable }
        let encoded = try JSONSerialization.jsonObject(with: PrismJSON.encoder().encode(t))
        let body = try JSONSerialization.data(withJSONObject: ["thread": encoded, "members": [Any]()] as [String: Any])
        return try PrismJSON.decoder().decode(CommsThreadDetail.self, from: body)
    }
    func messages(threadID: String, before: String?, limit: Int) async throws -> CommsMessagePage { throw CommsError.threadUnavailable }
    func mediaURL(token: String) -> URL { URL(string: "https://fixture.invalid/\(token)")! }
    func media(token: String) async throws -> (Data, String) { throw CommsError.mediaExpired }
    func events(lastEventID: String?) -> AsyncThrowingStream<CommsEvent, Error> { AsyncThrowingStream { $0.finish() } }
}

// MARK: Tests

@MainActor
final class ThreadListStoreTests: XCTestCase {
    private func loadedStore(_ threads: [CommsThread], next: String? = nil) async -> (ThreadListStore, SpyBackend) {
        let backend = SpyBackend()
        backend.setPage(page(threads, next: next))
        for t in threads { backend.setThread(t) }
        let store = ThreadListStore(backend: backend, refetchDelay: .milliseconds(20))
        await store.load()
        return (store, backend)
    }

    func testLoadSplitsPinnedFromRowsInServerOrder() async {
        let (store, _) = await loadedStore([
            makeThread("a", at: 50), makeThread("p1", at: 40, pinned: true), makeThread("b", at: 30),
        ])
        XCTAssertEqual(store.pinned.map(\.id), ["p1"])
        XCTAssertEqual(store.threads.map(\.id), ["a", "b"])
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.error)
    }

    func testTheOpenConversationReadsAsReadEvenWhenALiveMessageArrives() async {
        let (store, backend) = await loadedStore([makeThread("a", at: 50, unread: 2), makeThread("b", at: 40, unread: 1)])
        store.openThreadID = "a"
        XCTAssertEqual(store.threads.first { $0.id == "a" }?.unread.count, 0, "opening clears the dot")
        // A live message arrives in the open conversation; the server still counts it unread.
        backend.setThread(makeThread("a", at: 60, unread: 3))
        await store.apply(threadUpdated("a")).value
        XCTAssertEqual(store.threads.first { $0.id == "a" }?.unread.count, 0, "seen while open")
        // Other conversations keep their counts; a closed one counts again.
        XCTAssertEqual(store.threads.first { $0.id == "b" }?.unread.count, 1)
        store.openThreadID = nil
        backend.setThread(makeThread("a", at: 70, unread: 1))
        await store.apply(threadUpdated("a")).value
        XCTAssertEqual(store.threads.first { $0.id == "a" }?.unread.count, 1)
    }

    func testThreadUpdatedMovesThreadToTopUnlessPinned() async {
        let (store, backend) = await loadedStore([
            makeThread("p1", at: 10, pinned: true), makeThread("p2", at: 5, pinned: true),
            makeThread("a", at: 50), makeThread("b", at: 40), makeThread("c", at: 30),
        ])

        backend.setThread(makeThread("c", at: 100, unread: 1))
        await store.apply(threadUpdated("c")).value
        XCTAssertEqual(store.threads.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(store.threads.first?.unread.count, 1, "the refetched thread replaces the stale one")

        backend.setThread(makeThread("p2", at: 200, pinned: true, unread: 3))
        await store.apply(threadUpdated("p2")).value
        XCTAssertEqual(store.pinned.map(\.id), ["p1", "p2"], "pins keep their place")
        XCTAssertEqual(store.pinned.last?.unread.count, 3)
        XCTAssertEqual(store.threads.map(\.id), ["c", "a", "b"], "a pinned thread never enters the rows")
    }

    func testThreadUpdatedWithoutNewActivityKeepsItsPlace() async {
        let (store, backend) = await loadedStore([makeThread("a", at: 50), makeThread("b", at: 40), makeThread("c", at: 30)])
        backend.setThread(makeThread("b", at: 40, unread: 0, title: "Renamed"))
        await store.apply(threadUpdated("b")).value
        XCTAssertEqual(store.threads.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(store.threads[1].title, "Renamed", "titles come from the server")
    }

    func testThreadUpdatedOutsideTheFilterIsDroppedAndUnavailableIsRemoved() async {
        let (store, backend) = await loadedStore([makeThread("a", at: 50), makeThread("b", at: 40)])
        backend.setThread(makeThread("a", at: 60, folder: "archived"))
        await store.apply(threadUpdated("a")).value
        XCTAssertEqual(store.threads.map(\.id), ["b"], "a thread that left the folder leaves the list")

        backend.setThread(makeThread("new", at: 70, folder: "spam"))
        await store.apply(threadUpdated("new")).value
        XCTAssertEqual(store.threads.map(\.id), ["b"], "a thread from another folder is not inserted")

        backend.removeThread("b")
        await store.apply(threadUpdated("b")).value
        XCTAssertEqual(store.threads.map(\.id), [], "thread_unavailable removes the row")
    }

    func testStateUpdateOfLastLoadedRowKeepsItWhileMorePagesExist() async {
        let (store, backend) = await loadedStore([makeThread("a", at: 50), makeThread("b", at: 40), makeThread("c", at: 30)], next: "c1")
        backend.setThread(makeThread("c", at: 30, unread: 0, title: "Read now"))
        await store.apply(threadUpdated("c")).value
        XCTAssertEqual(store.threads.map(\.id), ["a", "b", "c"], "a shown row never vanishes on a state-only update")
        XCTAssertEqual(store.threads.last?.title, "Read now")

        backend.setThread(makeThread("old", at: 10))
        await store.apply(threadUpdated("old")).value
        XCTAssertEqual(store.threads.map(\.id), ["a", "b", "c"], "an unseen older thread waits for its page")
    }

    func testOlderRefetchCannotOverwriteANewerOne() async {
        let (store, backend) = await loadedStore([makeThread("a", at: 50), makeThread("b", at: 40)])
        backend.setThread(makeThread("b", at: 60, unread: 1))
        backend.queueThreadDelay(.milliseconds(150))
        let first = store.apply(threadUpdated("b", eventID: "e1"))
        try? await Task.sleep(for: .milliseconds(20))
        backend.setThread(makeThread("b", at: 70, unread: 5))
        let second = store.apply(threadUpdated("b", eventID: "e2"))
        await second.value
        await first.value
        XCTAssertEqual(store.threads.first?.unread.count, 5, "the slow, older answer is dropped")
    }

    // MARK: Refetch coalescing (I5)

    func testABurstOfThreadUpdatedCostsOneRequest() async {
        let (store, backend) = await loadedStore([makeThread("a", at: 50), makeThread("b", at: 40)])
        backend.setThread(makeThread("b", at: 60, unread: 3))
        var tasks: [Task<Void, Never>] = []
        for i in 0..<50 { tasks.append(store.apply(threadUpdated("b", eventID: "e\(i)"))) }
        for t in tasks { await t.value }
        XCTAssertLessThanOrEqual(backend.threadCalls.count, 2)
        XCTAssertEqual(backend.threadCalls, ["b"])
        XCTAssertEqual(store.threads.first?.id, "b")
        XCTAssertEqual(store.threads.first?.unread.count, 3)
    }

    func testAnEventDuringAFetchRefetchesOnceMoreAfterIt() async {
        let (store, backend) = await loadedStore([makeThread("a", at: 50), makeThread("b", at: 40)])
        backend.setThread(makeThread("b", at: 60, unread: 1))
        backend.queueThreadDelay(.milliseconds(150))
        let first = store.apply(threadUpdated("b", eventID: "e1"))
        try? await Task.sleep(for: .milliseconds(60)) // the first fetch is in flight
        backend.setThread(makeThread("b", at: 70, unread: 5))
        var tasks: [Task<Void, Never>] = []
        for i in 2..<20 { tasks.append(store.apply(threadUpdated("b", eventID: "e\(i)"))) }
        await first.value
        for t in tasks { await t.value }
        XCTAssertEqual(backend.threadCalls, ["b", "b"], "one in flight, one follow-up for everything that arrived meanwhile")
        XCTAssertEqual(store.threads.first?.unread.count, 5)
    }

    func testAReplayNamingManyThreadsBecomesOneListReload() async {
        let threads = (0..<30).map { makeThread("t\($0)", at: TimeInterval($0)) }
        let (store, backend) = await loadedStore(threads)
        let before = backend.queries.count
        var tasks: [Task<Void, Never>] = []
        for (i, t) in threads.enumerated() { tasks.append(store.apply(threadUpdated(t.id, eventID: "r\(i)"))) }
        for t in tasks { await t.value }
        XCTAssertEqual(backend.queries.count - before, 1, "one GET /threads")
        XCTAssertTrue(backend.threadCalls.isEmpty, "no per-thread GETs")
    }

    func testFewDistinctThreadsAreFetchedOnceEachWithBoundedConcurrency() async {
        let threads = (0..<8).map { makeThread("t\($0)", at: TimeInterval($0)) }
        let (store, backend) = await loadedStore(threads)
        for _ in 0..<8 { backend.queueThreadDelay(.milliseconds(30)) }
        var tasks: [Task<Void, Never>] = []
        for round in 0..<5 { for t in threads { tasks.append(store.apply(threadUpdated(t.id, eventID: "\(round)\(t.id)"))) } }
        for t in tasks { await t.value }
        XCTAssertEqual(backend.threadCalls.count, 8)
        XCTAssertEqual(Set(backend.threadCalls).count, 8)
        XCTAssertLessThanOrEqual(backend.maxInFlight, 4)
    }

    func testFilterChangeRetiresTheOldListSynchronously() async {
        let (store, backend) = await loadedStore([makeThread("a", at: 50), makeThread("b", at: 40)], next: "c1")
        store.filter = FilterState(folder: .spam)
        XCTAssertEqual(store.threads.map(\.id), [], "old folder's rows are gone at once")
        XCTAssertFalse(store.hasMore, "the old cursor is gone")
        XCTAssertTrue(store.isLoading)
        await store.loadMore()
        await store.loadTask?.value
        XCTAssertFalse(backend.queries.contains { $0.cursor == "c1" }, "the old cursor is never sent with the new query")

        backend.setFailThreads(true)
        store.filter = FilterState(folder: .archived)
        await store.loadTask?.value
        XCTAssertEqual(store.threads.map(\.id), [], "a failed reload leaves no wrong-folder rows")
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.isLoading)
    }

    func testPinToggleMovesBetweenGridAndRows() async {
        let (store, backend) = await loadedStore([makeThread("a", at: 50), makeThread("b", at: 40)])
        backend.setThread(makeThread("b", at: 40, pinned: true))
        await store.apply(threadUpdated("b")).value
        XCTAssertEqual(store.pinned.map(\.id), ["b"])
        XCTAssertEqual(store.threads.map(\.id), ["a"])
    }

    func testResetEventReloads() async {
        let (store, backend) = await loadedStore([makeThread("a", at: 50)])
        XCTAssertEqual(backend.queries.count, 1)
        backend.setPage(page([makeThread("x", at: 90), makeThread("a", at: 50)]))
        await store.apply(CommsEvent(id: nil, kind: .reset, payload: .null)).value
        XCTAssertEqual(backend.queries.count, 2)
        XCTAssertEqual(store.threads.map(\.id), ["x", "a"])
    }

    func testFilterChangeReloadsWithQuery() async {
        let (store, backend) = await loadedStore([makeThread("a", at: 50)])
        backend.setPage(page([makeThread("z", at: 10, folder: "archived")]))
        store.filter = FilterState(folder: .archived, unread: true, networks: [.telegram])
        await store.loadTask?.value
        XCTAssertEqual(backend.queries.last, CommsThreadQuery(folder: .archived, unreadOnly: true, networks: [.telegram]))
        XCTAssertEqual(store.threads.map(\.id), ["z"])

        let count = backend.queries.count
        store.filter = FilterState(folder: .archived, unread: true, networks: [.telegram])
        await store.loadTask?.value
        XCTAssertEqual(backend.queries.count, count, "setting an equal filter does not reload")
    }

    func testFilterStateIsFilteringAndQuery() {
        XCTAssertFalse(FilterState().isFiltering)
        XCTAssertFalse(FilterState(folder: .spam).isFiltering, "a folder is not a Filter By toggle")
        XCTAssertTrue(FilterState(unread: true).isFiltering)
        XCTAssertTrue(FilterState(networks: [.whatsapp]).isFiltering)
        XCTAssertEqual(
            FilterState(folder: .strangers, networks: [.whatsapp, .imessage, .telegram]).query(cursor: "c2"),
            CommsThreadQuery(folder: .strangers, networks: [.imessage, .telegram, .whatsapp], cursor: "c2"),
            "networks are sent in a stable order"
        )
    }

    func testLoadMoreAppendsWithoutDuplicates() async {
        let (store, backend) = await loadedStore([makeThread("a", at: 50), makeThread("b", at: 40)], next: "c1")
        backend.setPage(page([makeThread("b", at: 40), makeThread("c", at: 30), makeThread("p", at: 20, pinned: true)]), cursor: "c1")
        XCTAssertTrue(store.hasMore)
        await store.loadMore()
        XCTAssertEqual(store.threads.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(store.pinned.map(\.id), ["p"])
        XCTAssertEqual(backend.queries.last?.cursor, "c1")
        XCTAssertFalse(store.hasMore)

        await store.loadMore()
        XCTAssertEqual(backend.queries.count, 2, "no next cursor, no request")
    }

    func testLoadFailureSetsError() async {
        final class Failing: ChatBackend, @unchecked Sendable {
            func capabilities() async throws -> CommsCapabilities { FixtureBackend.validCapabilities }
            func threads(_ q: CommsThreadQuery) async throws -> CommsThreadPage { throw CommsError.sourceUnavailable(network: .whatsapp) }
            func thread(id: String) async throws -> CommsThreadDetail { throw CommsError.threadUnavailable }
            func messages(threadID: String, before: String?, limit: Int) async throws -> CommsMessagePage { throw CommsError.threadUnavailable }
            func mediaURL(token: String) -> URL { URL(string: "https://fixture.invalid/x")! }
            func media(token: String) async throws -> (Data, String) { throw CommsError.mediaExpired }
            func events(lastEventID: String?) -> AsyncThrowingStream<CommsEvent, Error> { AsyncThrowingStream { $0.finish() } }
        }
        let store = ThreadListStore(backend: Failing())
        await store.load()
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.isLoading)
    }
}

// MARK: Live event pump

@MainActor
final class LiveEventPumpTests: XCTestCase {
    func testBackoffDoublesFromOneToThirtySeconds() {
        let b = EventBackoff()
        XCTAssertEqual((1...7).map { b.delay(attempt: $0) }, [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
    }

    func testReconnectsWithLastEventIDAfterADrop() async throws {
        struct Drop: Error {}
        let backend = try FixtureBackend()
        let sleeps = OSAllocatedUnfairLock(initialState: [Duration]())
        var seen: [String?] = []
        let pump = LiveEventPump(backend: backend, sleep: { d in sleeps.withLock { $0.append(d) } }) { seen.append($0.id) }
        let task = Task { await pump.run() }

        try await waitUntil { backend.requestedEventIDs.count == 1 }
        backend.push(CommsEvent(id: "e1", kind: .threadUpdated, payload: ["threadId": "a"]))
        backend.push(CommsEvent(id: "e2", kind: .threadUpdated, payload: ["threadId": "b"]))
        try await waitUntil { seen.count == 2 }
        backend.finishStreams(throwing: Drop())
        try await waitUntil { backend.requestedEventIDs.count == 2 }
        XCTAssertEqual(backend.requestedEventIDs, [nil, "e2"])

        backend.finishStreams(throwing: Drop())
        try await waitUntil { backend.requestedEventIDs.count == 3 }
        XCTAssertEqual(sleeps.withLock { $0 }, [.seconds(1), .seconds(2)], "consecutive drops back off")

        backend.push(CommsEvent(id: nil, kind: .reset, payload: .null))
        try await waitUntil { seen.count == 3 }
        backend.finishStreams()
        try await waitUntil { backend.requestedEventIDs.count == 4 }
        XCTAssertEqual(backend.requestedEventIDs.last, .some(nil), "after a reset the stale cursor is dropped")
        XCTAssertEqual(sleeps.withLock { $0 }.last, .seconds(1), "an event resets the backoff")

        task.cancel()
        await task.value
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
