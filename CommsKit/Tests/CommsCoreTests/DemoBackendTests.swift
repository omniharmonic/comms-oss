import CommsClient
import CommsCore
import CommsTestSupport
import Foundation
import XCTest

/// The demo-mode backend the DEBUG apps launch with (`-CommsDemo YES`).
@MainActor
final class DemoBackendTests: XCTestCase {
    func testListHasTheStagingRoomsFirstAndFiltersByFolder() async throws {
        let backend = try DemoBackend.make()
        let inbox = try await backend.threads(CommsThreadQuery(folder: .inbox)).threads
        XCTAssertEqual(Array(inbox.prefix(3)).map(\.title), ["bob", "Trail Crew", "Alice Example"])
        XCTAssertTrue(inbox.contains { $0.pinned })
        XCTAssertTrue(inbox.allSatisfy { $0.folder == .inbox })
        let archived = try await backend.threads(CommsThreadQuery(folder: .archived)).threads
        XCTAssertEqual(archived.map(\.title), ["Old Roommates"])
    }

    func testEveryDemoThreadLooksReal() async throws {
        let backend = try DemoBackend.make()
        var all: [CommsThread] = []
        for folder in [CommsFolder.inbox, .strangers, .low, .archived, .spam] {
            let page = try await backend.threads(CommsThreadQuery(folder: folder)).threads
            XCTAssertFalse(page.isEmpty, "\(folder) has a thread")
            all += page
        }
        for t in all {
            let preview = try XCTUnwrap(t.lastMessage?.text, "\(t.title) has a preview")
            XCTAssertFalse(preview.isEmpty, t.title)
            XCTAssertFalse(t.title.hasPrefix("Title "), "no placeholder titles")
            // The preview is what the server says for the newest message (or the reaction on it).
            let newest = try XCTUnwrap(backend.newestMessages(threadID: t.id).last, t.title)
            let isGroup = t.kind == .group
            if !preview.contains("loved") {
                XCTAssertEqual(preview, DemoPreview.text(newest, senderFirstName: DemoPreview.firstName(newest.sender.name), isGroup: isGroup), t.title)
            }
        }
        let networks = Set(all.flatMap(\.networks))
        for n in [CommsNetwork.whatsapp, .telegram, .imessage, .matrix, .discord, .messenger, .email] {
            XCTAssertTrue(networks.contains(n), "a \(n.wire) thread")
        }
        XCTAssertTrue(all.contains { t in t.pinned && { if case .token = t.avatar { true } else { false } }() }, "a pinned photo avatar")
        XCTAssertTrue(all.contains { t in t.kind == .group && { if case .monogram(_, let m) = t.avatar { m.count >= 2 } else { false } }() },
                      "a group with a member cluster (D16)")
        XCTAssertTrue(all.contains { $0.unread.count > 0 })
        XCTAssertTrue(all.contains { $0.urgency == .urgent })
        let previews = all.compactMap(\.lastMessage?.text)
        XCTAssertTrue(previews.contains("Priya: 📷 Photo"), "group photo preview")
        XCTAssertTrue(previews.contains("Lena loved “Sending the itinerary no…”"), "tapback phrasing")
        XCTAssertTrue(previews.contains("Voice message 0:42"))
        let (data, _) = try await backend.media(token: "demo-avatar-maya")
        XCTAssertNotEqual(data, FixtureMessages.placeholderPNG, "photo avatars are generated pictures")
    }

    func testAliceHasTwoOlderPages() async throws {
        let store = TimelineStore(backend: try DemoBackend.make(), threadID: DemoBackend.aliceThreadID, thread: nil)
        await store.loadLatest()
        let newest = store.rows.count
        XCTAssertTrue(store.hasMore)
        await store.loadOlder()
        await store.loadOlder()
        XCTAssertFalse(store.hasMore)
        XCTAssertGreaterThanOrEqual(store.rows.count, newest + 2 * DemoBackend.olderPageSize)
    }

    func testSimulatorDeliversAMessageAndAReaction() async throws {
        let backend = try DemoBackend.make()
        let sim = DemoSimulator(backend: backend)
        let store = TimelineStore(backend: backend, threadID: DemoBackend.aliceThreadID, thread: nil)
        await store.loadLatest()
        var events = backend.events(lastEventID: nil).makeAsyncIterator()

        let text = try XCTUnwrap(sim.injectMessage(threadID: DemoBackend.aliceThreadID, text: "Hello from the demo"))
        let created = try await XCTUnwrapAsync(try await events.next())
        XCTAssertEqual(created.kind, .messageCreated)
        store.apply(created)
        XCTAssertEqual(messages(store).last?.body?.plain, text)
        let updated = try await XCTUnwrapAsync(try await events.next())
        XCTAssertEqual(updated.kind, .threadUpdated)
        let thread = try await backend.thread(id: DemoBackend.aliceThreadID).thread
        XCTAssertEqual(thread.lastMessage?.text, text)
        XCTAssertEqual(thread.unread.count, 1)

        let reacted = try XCTUnwrap(sim.injectReaction(threadID: DemoBackend.aliceThreadID))
        let reaction = try await XCTUnwrapAsync(try await events.next())
        XCTAssertEqual(reaction.kind, .reactionChanged)
        store.apply(reaction)
        XCTAssertEqual(messages(store).first { $0.id == reacted }?.reactions.first { $0.key == "😂" }?.count, 1)
    }

    private func messages(_ store: TimelineStore) -> [CommsMessage] {
        store.rows.compactMap { if case .message(let m, _, _, _) = $0 { m } else { nil } }
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}
