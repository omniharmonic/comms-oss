import CommsClient
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

/// Phase 2b C4 (+ fix round 1): search answers at once from the loaded list, asks the server
/// after a pause for EVERY conversation (all folders, no filters — one request per folder),
/// keeps the previous answer's rows until replaced, merges without moving rows, and pages.
@MainActor
final class SearchTests: XCTestCase {
    private let base = PrismJSON.parseDate("2026-11-20T14:00:00Z")!

    private func thread(_ id: String, _ title: String, preview: String = "", minutesAgo: Double, folder: String = "inbox", unread: Int = 0) -> CommsThread {
        var t = FixtureMessages.thread(id: id, title: title)
        t.lastActivityAt = base.addingTimeInterval(-minutesAgo * 60)
        t.folder = CommsFolder(wire: folder)
        t.unread.count = unread
        if !preview.isEmpty { t.lastMessage = FixtureMessages.preview(text: preview, senderName: nil, isSelf: false, at: t.lastActivityAt) }
        return t
    }

    private func makeStore(debounce: Duration = .milliseconds(150)) async throws -> (ThreadListStore, FixtureBackend) {
        let backend = try FixtureBackend(capabilities: .success(FixtureBackend.validCapabilities))
        backend.setFiltersThreadQuery(true)
        backend.setThreads([])
        for t in [thread("t_alice", "Alice", preview: "See you at the climbing gym", minutesAgo: 1),
                  thread("t_jose", "José Ruiz", preview: "Gracias", minutesAgo: 5),
                  thread("t_team", "Design Guild", preview: "alice shared a file", minutesAgo: 10),
                  thread("t_bob", "Bob", preview: "Lunch?", minutesAgo: 20)] {
            backend.upsertThread(t)
        }
        let store = ThreadListStore(backend: backend, refetchDelay: .milliseconds(1), searchDebounce: debounce)
        await store.load()
        return (store, backend)
    }

    private func searchQueries(_ backend: FixtureBackend) -> [CommsThreadQuery] {
        backend.threadQueries.filter { $0.search != nil }
    }

    func testLocalMatchesAreInstantAndFoldCaseAndDiacritics() async throws {
        let (store, backend) = try await makeStore()
        store.searchText = "ALICE"
        // Synchronously, before any request: title or preview, newest first.
        XCTAssertEqual(store.searchResults?.map(\.id), ["t_alice", "t_team"])
        XCTAssertTrue(store.isSearchingServer)
        XCTAssertTrue(searchQueries(backend).isEmpty, "the server is asked only after the pause")
        store.searchText = "jose"
        XCTAssertEqual(store.searchResults?.map(\.id), ["t_jose"], "jose finds José")
        store.searchText = "  "
        XCTAssertNil(store.searchResults, "blank = the list again")
        XCTAssertFalse(store.isSearchingServer)
    }

    func testTypingQuicklyAsksTheServerOnceForEveryFolderWithoutFilters() async throws {
        let (store, backend) = try await makeStore(debounce: .milliseconds(80))
        store.filter = FilterState(unread: true, networks: [.telegram], statuses: [.urgent])
        await store.loadTask?.value
        for prefix in ["a", "al", "ali", "alic"] {
            store.searchText = prefix
            try await Task.sleep(for: .milliseconds(10))
        }
        await store.searchWork?.value
        XCTAssertEqual(store.searchRequests, ["alic"], "one search, for the last text")
        let qs = searchQueries(backend)
        XCTAssertEqual(Set(qs.map(\.folder)), Set(FilterState.folders), "every folder")
        for q in qs {
            XCTAssertEqual(q.search, "alic")
            XCTAssertFalse(q.unreadOnly, "Filter By does not apply to search")
            XCTAssertTrue(q.networks.isEmpty)
            XCTAssertTrue(q.statuses.isEmpty)
            XCTAssertFalse(q.attention)
            XCTAssertEqual(q.limit, 30)
        }
        XCTAssertEqual(store.searchResults?.map(\.id), ["t_alice", "t_team"], "found despite the Unread/Telegram/Urgent filter")
    }

    func testFindsConversationsInOtherFolders() async throws {
        let (store, backend) = try await makeStore(debounce: .milliseconds(1))
        backend.upsertThread(thread("t_arch", "Ann (archived)", minutesAgo: 30, folder: "archived"))
        backend.upsertThread(thread("t_spam", "Ann spam", minutesAgo: 40, folder: "spam"))
        store.searchText = "ann"
        await store.searchWork?.value
        XCTAssertEqual(store.searchResults?.map(\.id), ["t_arch", "t_spam"])
    }

    func testStaleAnswerIsDroppedWhenTheTextChanges() async throws {
        let (store, backend) = try await makeStore(debounce: .milliseconds(10))
        backend.setThreadsDelay(.milliseconds(150))
        store.searchText = "b"
        try await Task.sleep(for: .milliseconds(40)) // "b" is now in flight
        let stale = store.searchWork
        store.searchText = "bob"
        await stale?.value
        XCTAssertEqual(store.searchResults?.map(\.id), ["t_bob"], "the 'b' answer never lands")
        await store.searchWork?.value
        XCTAssertEqual(store.searchResults?.map(\.id), ["t_bob"])
        XCTAssertEqual(store.searchRequests, ["b", "bob"])
    }

    func testServerMatchesMergeWithoutMovingShownRows() async throws {
        let (store, backend) = try await makeStore(debounce: .milliseconds(10))
        // Threads the list never loaded (another page / folder) that the server finds.
        backend.upsertThread(thread("t_old", "Alice (old phone)", minutesAgo: 600, folder: "low"))
        backend.upsertThread(thread("t_mid", "Club", preview: "alice says hi", minutesAgo: 7, folder: "archived"))
        store.searchText = "alice"
        let instant = try XCTUnwrap(store.searchResults).map(\.id)
        XCTAssertEqual(instant, ["t_alice", "t_team"])
        await store.searchWork?.value
        let merged = try XCTUnwrap(store.searchResults).map(\.id)
        XCTAssertEqual(merged, ["t_alice", "t_mid", "t_team", "t_old"], "newest activity first")
        XCTAssertEqual(merged.filter(instant.contains), instant, "rows shown at once keep their order")
    }

    /// Review I3: rows only the server found stay on screen across keystrokes (narrowed to the
    /// new text) until the new answer replaces them — no vanish-and-return per keystroke.
    func testServerOnlyRowsStayWhileTheNextAnswerIsOnItsWay() async throws {
        let (store, backend) = try await makeStore(debounce: .milliseconds(10))
        backend.upsertThread(thread("t_arch", "Alice archive", minutesAgo: 30, folder: "archived"))
        backend.upsertThread(thread("t_alfa", "Alfa", minutesAgo: 35, folder: "archived"))
        store.searchText = "al"
        await store.searchWork?.value
        XCTAssertTrue(store.searchResults!.map(\.id).contains("t_arch"))
        XCTAssertTrue(store.searchResults!.map(\.id).contains("t_alfa"))
        backend.setThreadsDelay(.milliseconds(200))
        store.searchText = "ali"
        // Synchronously: the archived match is still there; "Alfa" no longer matches "ali".
        XCTAssertTrue(store.searchResults!.map(\.id).contains("t_arch"), "kept until replaced")
        XCTAssertFalse(store.searchResults!.map(\.id).contains("t_alfa"), "narrowed to the new text")
        await store.searchWork?.value
        XCTAssertTrue(store.searchResults!.map(\.id).contains("t_arch"))
    }

    func testPagesPastTheFirstThirty() async throws {
        let (store, backend) = try await makeStore(debounce: .milliseconds(1))
        for i in 0..<45 { backend.upsertThread(thread("t_p\(i)", "Person \(i)", minutesAgo: Double(100 + i), folder: "archived")) }
        store.searchLimit = 30
        store.searchText = "person"
        await store.searchWork?.value
        XCTAssertEqual(store.searchResults?.count, 30)
        XCTAssertTrue(store.searchHasMore)
        await store.loadMoreSearchResults()
        XCTAssertEqual(store.searchResults?.count, 45, "the next page is appended")
        XCTAssertFalse(store.searchHasMore)
        let ids = store.searchResults!.map(\.id)
        XCTAssertEqual(ids, (0..<45).map { "t_p\($0)" }, "still newest first")
    }

    /// Paging across folders only ever adds at the end: a folder with more pages hides the
    /// other folders' older rows until its next page is in.
    func testPagingAcrossFoldersOnlyAppends() async throws {
        let (store, backend) = try await makeStore(debounce: .milliseconds(1))
        for i in 0..<4 { backend.upsertThread(thread("t_a\(i)", "Zed A\(i)", minutesAgo: Double(10 + 10 * i), folder: "archived")) } // 10,20,30,40
        backend.upsertThread(thread("t_s0", "Zed S0", minutesAgo: 35, folder: "spam"))
        store.searchLimit = 2
        store.searchText = "zed"
        await store.searchWork?.value
        let first = store.searchResults!.map(\.id)
        XCTAssertEqual(first, ["t_a0", "t_a1"], "spam's older row waits for archived's next page")
        await store.loadMoreSearchResults()
        let second = store.searchResults!.map(\.id)
        XCTAssertEqual(Array(second.prefix(2)), first, "appended, never inserted above")
        XCTAssertEqual(second, ["t_a0", "t_a1", "t_a2", "t_s0", "t_a3"])
    }

    func testFilterChangeKeepsTheSearchAndOfflineKeepsShownMatches() async throws {
        let (store, backend) = try await makeStore(debounce: .milliseconds(10))
        backend.upsertThread(thread("t_arch", "Alice archive", minutesAgo: 30, folder: "archived"))
        store.searchText = "alice"
        await store.searchWork?.value
        let before = store.searchResults?.map(\.id)
        let requests = store.searchRequests.count
        store.filter = FilterState(folder: .spam)
        XCTAssertEqual(store.searchResults?.map(\.id).contains("t_arch"), true, "no empty flash while the list reloads")
        await store.loadTask?.value
        XCTAssertEqual(store.searchRequests.count, requests, "folders/filters do not restart search")
        XCTAssertEqual(store.searchResults?.map(\.id), before)

        backend.setThreadsError(CommsError.sourceUnavailable(network: .whatsapp))
        store.searchText = "alice archive"
        await store.searchWork?.value
        XCTAssertEqual(store.searchResults?.map(\.id), ["t_arch"], "a failed request keeps what is shown")
        XCTAssertFalse(store.isSearchingServer)
    }

    func testLiveUpdateRefreshesOrAddsASearchRow() async throws {
        let (store, backend) = try await makeStore(debounce: .milliseconds(10))
        store.searchText = "late"
        await store.searchWork?.value
        XCTAssertEqual(store.searchResults?.map(\.id), [])
        backend.upsertThread(thread("t_bob", "Bob", preview: "Running late", minutesAgo: 0))
        await store.apply(CommsEvent(id: "e1", kind: .threadUpdated, payload: ["threadId": "t_bob"])).value
        XCTAssertEqual(store.searchResults?.first?.lastMessage?.text, "Running late", "now matches: added")
        // A conversation in another folder that newly matches joins too.
        backend.upsertThread(thread("t_x", "Xavier", preview: "late again", minutesAgo: 0.5, folder: "archived"))
        await store.apply(CommsEvent(id: "e2", kind: .threadUpdated, payload: ["threadId": "t_x"])).value
        XCTAssertEqual(store.searchResults?.map(\.id), ["t_bob", "t_x"])
    }

    /// Before/after, printed (not asserted on the clock: the suite runs on a busy machine).
    /// Before (phase 2a) every SwiftUI body pass ran `localizedStandardContains` on each title
    /// and preview; now a keystroke is one byte scan of a cached index, narrowed as typing goes.
    func testLocalFilterOn6000ThreadsIsCorrectAndMeasured() async throws {
        let backend = try FixtureBackend(capabilities: .success(FixtureBackend.validCapabilities))
        backend.setFiltersThreadQuery(true)
        var all: [CommsThread] = []
        for i in 0..<6000 {
            all.append(thread("t\(i)", "Person \(i) Ñandú", preview: "Message body number \(i) with café", minutesAgo: Double(i)))
        }
        backend.setThreads(all)
        let store = ThreadListStore(backend: backend, searchDebounce: .seconds(60))
        await store.load()
        XCTAssertEqual(store.threads.count, 6000)

        let keystrokes = ["p", "pe", "per", "pers", "perso", "person", "person 5", "person 59"]
        let clock = ContinuousClock()
        let before = clock.measure {
            for k in keystrokes {
                _ = all.filter { $0.title.localizedStandardContains(k) || ($0.lastMessage?.text.localizedStandardContains(k) ?? false) }
            }
        }
        let after = clock.measure { for k in keystrokes { store.searchText = k } }
        XCTAssertEqual(store.searchResults?.count, 111, "Person 59, 590…599, 5900…5999")
        store.searchText = "nandu cafe"
        XCTAssertEqual(store.searchResults?.count, 0, "title and preview are separate texts")
        store.searchText = "nandu"
        XCTAssertEqual(store.searchResults?.count, 6000, "diacritics folded")
        store.searchText = ""
        print("[search-perf] 6000 threads, per keystroke: before \(before / keystrokes.count), after \(after / keystrokes.count)")
    }
}
