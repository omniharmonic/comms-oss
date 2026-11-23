import CommsClient
import CommsCore
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

/// Sprint Task 8: pinning from the list (optimistic, server-confirmed, max 9, reorder) and the
/// delivery state never moving back on an out-of-order update.
@MainActor
final class PinsAndReceiptsTests: XCTestCase {
    private func backend(_ count: Int = 4) -> FixtureBackend {
        let b = try! FixtureBackend.staging()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var threads: [CommsThread] = []
        for i in 0..<count {
            var t = FixtureMessages.thread(id: "th_\(i)", title: "Person \(i)")
            t.lastActivityAt = now.addingTimeInterval(TimeInterval(-60 * i))
            threads.append(t)
        }
        b.setThreads(threads)
        return b
    }

    func testPinMovesTheThreadIntoTheGridAndBack() async {
        let b = backend()
        let store = ThreadListStore(backend: b)
        await store.load()
        XCTAssertTrue(store.canPin)
        await store.pin("th_2")
        XCTAssertEqual(store.pinned.map(\.id), ["th_2"])
        XCTAssertFalse(store.threads.contains { $0.id == "th_2" })
        await store.pin("th_0")
        XCTAssertEqual(store.pinned.map(\.id), ["th_2", "th_0"], "a new pin goes to the end of the grid")
        XCTAssertEqual(store.pinned.map(\.pinOrder), [0, 1])
        await store.unpin("th_2")
        XCTAssertEqual(store.pinned.map(\.id), ["th_0"])
        XCTAssertEqual(store.threads.map(\.id), ["th_1", "th_2", "th_3"], "back in its activity place")
        XCTAssertEqual(b.pinCalls, ["pin:th_2", "pin:th_0", "unpin:th_2"])
        // A reload keeps the server's order.
        await store.load()
        XCTAssertEqual(store.pinned.map(\.id), ["th_0"])
    }

    func testTenthPinIsRefusedLocally() async {
        let b = backend(10)
        let store = ThreadListStore(backend: b)
        await store.load()
        for i in 0..<9 { await store.pin("th_\(i)") }
        XCTAssertEqual(store.pinned.count, 9)
        await store.pin("th_9")
        XCTAssertEqual(store.pinned.count, 9)
        XCTAssertEqual(store.pinNotice, ThreadListStore.pinLimitText)
        XCTAssertFalse(b.pinCalls.contains("pin:th_9"), "never asked the server")
        store.dismissPinNotice()
        XCTAssertNil(store.pinNotice)
    }

    func testFailedPinRollsBack() async {
        let b = backend()
        let store = ThreadListStore(backend: b)
        await store.load()
        b.setPinError(CommsError.sourceUnavailable(network: .unknown("")))
        await store.pin("th_1")
        XCTAssertTrue(store.pinned.isEmpty)
        XCTAssertTrue(store.threads.contains { $0.id == "th_1" })
        XCTAssertEqual(store.pinNotice, "Couldn't pin “Person 1”.")
    }

    func testReorderSavesTheOrderAndRecoversFromAnotherDevice() async {
        let b = backend()
        let store = ThreadListStore(backend: b)
        await store.load()
        for id in ["th_0", "th_1", "th_2"] { await store.pin(id) }
        await store.movePin("th_2", to: 0)
        XCTAssertEqual(store.pinned.map(\.id), ["th_2", "th_0", "th_1"])
        XCTAssertEqual(b.pinCalls.last, "order:th_2,th_0,th_1")
        // Another device unpinned th_0 meanwhile: the server refuses, the store shows its state.
        _ = try? await b.unpin(threadID: "th_0")
        await store.movePin("th_1", to: 0)
        XCTAssertEqual(Set(store.pinned.map(\.id)), ["th_2", "th_1"])
        XCTAssertNil(store.pinNotice)
    }

    func testPinsOrderedByPinOrder() {
        var a = FixtureMessages.thread(id: "a", title: "A"); a.pinned = true; a.pinOrder = 2
        var b = FixtureMessages.thread(id: "b", title: "B"); b.pinned = true; b.pinOrder = 0
        var c = FixtureMessages.thread(id: "c", title: "C"); c.pinned = true
        XCTAssertEqual(ThreadListStore.pinOrdered([a, c, b]).map(\.id), ["b", "a", "c"])
    }

    func testDeliveryNeverMovesBack() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var read = FixtureMessages.message(id: "$m", outgoing: true, at: at, delivery: "read")
        read.readAt = at.addingTimeInterval(60)
        var late = FixtureMessages.message(id: "$m", outgoing: true, at: at, delivery: "delivered")
        TimelineStore.keepReadState(&late, from: read)
        XCTAssertEqual(late.delivery, .read)
        XCTAssertEqual(late.readAt, read.readAt)
        // A failure is shown as it comes; a forward move is taken.
        var failed = FixtureMessages.message(id: "$m", outgoing: true, at: at, delivery: "failed")
        TimelineStore.keepReadState(&failed, from: read)
        XCTAssertEqual(failed.delivery, .failed)
        var forward = FixtureMessages.message(id: "$m", outgoing: true, at: at, delivery: "read")
        TimelineStore.keepReadState(&forward, from: FixtureMessages.message(id: "$m", outgoing: true, at: at, delivery: "sent"))
        XCTAssertEqual(forward.delivery, .read)
    }
}

@MainActor
final class PinOrderHealingTests: XCTestCase {
    /// Pins made elsewhere carry no order: a new pin still goes LAST, never first.
    func testNewPinGoesAfterUnorderedPins() async throws {
        let b = try FixtureBackend.staging()
        var a = FixtureMessages.thread(id: "th_a", title: "A"); a.pinned = true
        var c = FixtureMessages.thread(id: "th_c", title: "C"); c.pinned = true
        let n = FixtureMessages.thread(id: "th_n", title: "N")
        b.setThreads([a, c, n])
        let store = ThreadListStore(backend: b)
        await store.load()
        await store.pin("th_n")
        XCTAssertEqual(store.pinned.map(\.id), ["th_a", "th_c", "th_n"])
        await store.load()
        XCTAssertEqual(store.pinned.map(\.id), ["th_a", "th_c", "th_n"], "the server's order agrees")
    }
}
