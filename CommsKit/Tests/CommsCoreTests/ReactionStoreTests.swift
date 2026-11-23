import CommsClient
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

/// Optimistic reactions in `TimelineStore`: instant badge, rollback + notice on failure,
/// reconcile with the echo, no auto-retry, Messages' toggle/replace, `capabilities.react`.
@MainActor
final class ReactionStoreTests: XCTestCase {
    private let base = PrismJSON.parseDate("2026-11-20T14:00:00Z")!
    private var clock = PrismJSON.parseDate("2026-11-20T14:02:00Z")!

    private func makeStore(react: Bool = true, reply: Bool = true, send: Bool = true, network: String = "whatsapp",
                           reactions: [FixtureMessages.Reaction] = []) async throws -> (TimelineStore, FixtureBackend) {
        let backend = try FixtureBackend()
        var thread = FixtureMessages.thread(id: "th_r", title: "Sam", network: network)
        thread.channels[0].capabilities = CommsChannelCapabilities(react: react, reply: reply, attachments: true, send: send)
        backend.upsertThread(thread)
        backend.setMessagePages([nil: FixtureMessages.page([
            FixtureMessages.message(id: "$m1", threadID: "th_r", network: network, sender: "Sam", at: base, text: "Dinner?", reactions: reactions),
            FixtureMessages.message(id: "$m2", threadID: "th_r", network: network, outgoing: true, at: base.addingTimeInterval(60), text: "Yes!"),
        ], before: nil, hasMore: false)], threadID: "th_r")
        backend.setReactionEcho(.none)
        let store = TimelineStore(backend: backend, threadID: "th_r", now: { [unowned self] in self.clock })
        await store.loadLatest()
        return (store, backend)
    }

    private func message(_ store: TimelineStore, _ id: String) -> CommsMessage? {
        store.rows.lazy.compactMap { if case .message(let m, _, _, _) = $0, m.id == id { m } else { nil } }.first
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 2) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testAddShowsAtOnceThenStaysUntilTheEchoAgrees() async throws {
        let (store, backend) = try await makeStore()
        backend.setReactionDelay(.milliseconds(150))
        let task = Task { await store.toggleReaction("❤️", on: "$m1") }
        await waitUntil { self.message(store, "$m1")?.reactions.isEmpty == false }
        let shown = try XCTUnwrap(message(store, "$m1")?.reactions.first)
        XCTAssertEqual(shown.key, "❤️")
        XCTAssertTrue(shown.mine, "drawn as mine before the server answers")
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(store.isReactionInFlight("❤️", on: "$m1"))
        await task.value

        let call = try XCTUnwrap(backend.reactionCalls.first)
        XCTAssertEqual(call, .init(threadID: "th_r", messageID: "$m1", key: "❤️", clientID: call.clientID))
        XCTAssertNotNil(UUID(uuidString: call.clientID ?? ""), "clientId is a UUID")
        XCTAssertTrue(message(store, "$m1")?.reactions.first?.mine == true, "accepted: still drawn while the echo is on its way")
        XCTAssertNil(store.reactionNotice)

        // The echo: the server now shows it; the change is done (drawn once, not twice).
        var echoed = try XCTUnwrap(backend.newestMessages(threadID: "th_r").first)
        echoed.reactions = [CommsReaction(key: "❤️", count: 1, mine: true, senders: [.init(id: FixtureMessages.selfID, name: "Me")])]
        store.apply(FixtureMessages.event(.reactionChanged, echoed))
        XCTAssertEqual(message(store, "$m1")?.reactions.map(\.count), [1])
        XCTAssertTrue(store.reactionOps.isEmpty, "reconciled")
    }

    func testFailureRollsBackWithANoticeAndIsNeverRetried() async throws {
        let (store, backend) = try await makeStore(reactions: [.init("👍", names: ["Sam"])])
        backend.setReactionHandler { _ in
            throw CommsError.sendFailed(CommsSendFailure(reason: .sendFailed, message: "x", maybeSent: false, status: 502))
        }
        await store.toggleReaction("❤️", on: "$m1")
        XCTAssertEqual(message(store, "$m1")?.reactions.map(\.key), ["👍"], "rolled back to the server's state")
        XCTAssertEqual(store.reactionNotice?.text, "Couldn't send your reaction.")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(backend.reactionCalls.count, 1, "no automatic retry")
        store.dismissReactionNotice()
        XCTAssertNil(store.reactionNotice)
    }

    func testTappingMyReactionRemovesIt() async throws {
        let (store, backend) = try await makeStore(reactions: [.init("❤️", count: 2, mine: true, names: ["Sam"])])
        await store.toggleReaction("❤️", on: "$m1")
        XCTAssertEqual(backend.reactionCalls.map(\.isAdd), [false])
        let r = try XCTUnwrap(message(store, "$m1")?.reactions.first)
        XCTAssertFalse(r.mine)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.senders.map(\.name), ["Sam"], "my entry left the senders")
    }

    func testRemoveOfAPhoneReactionRollsBackWithItsOwnExplanation() async throws {
        let (store, backend) = try await makeStore(reactions: [.init("❤️", mine: true)])
        backend.setReactionHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .notFound, status: 404)) }
        await store.toggleReaction("❤️", on: "$m1")
        XCTAssertEqual(message(store, "$m1")?.reactions.first?.mine, true, "put back")
        XCTAssertEqual(store.reactionNotice?.text, "This reaction was added from another device, so it can't be removed here.")
    }

    func testAnotherTapbackReplacesMine() async throws {
        let (store, backend) = try await makeStore(reactions: [.init("👍", mine: true)])
        await store.toggleReaction("😂", on: "$m1")
        XCTAssertEqual(calls(backend), ["+😂", "-👍"], "the add first, then the remove it replaces")
        XCTAssertEqual(message(store, "$m1")?.reactions.filter(\.mine).map(\.key), ["😂"])
    }

    private func calls(_ backend: FixtureBackend) -> [String] {
        backend.reactionCalls.map { "\($0.isAdd ? "+" : "-")\($0.key)" }
    }

    private func mine(_ store: TimelineStore) -> [String] {
        message(store, "$m1")?.reactions.filter(\.mine).map(\.key) ?? []
    }

    /// Review I1: a second tapback while the first is still on its way replaces it (one per person).
    func testRapidSecondTapbackWhileTheFirstIsInFlightReplacesIt() async throws {
        let (store, backend) = try await makeStore()
        backend.setReactionDelay(.milliseconds(120))
        let first = Task { await store.toggleReaction("❤️", on: "$m1") }
        await waitUntil { store.isReactionInFlight("❤️", on: "$m1") && !backend.reactionCalls.isEmpty }
        let second = Task { await store.toggleReaction("👍", on: "$m1") }
        await waitUntil { self.mine(store) == ["👍"] }
        XCTAssertEqual(mine(store), ["👍"], "drawn at once, before the first request answers")
        await first.value
        await second.value
        XCTAssertEqual(calls(backend), ["+❤️", "+👍", "-❤️"], "strictly one after another")
        XCTAssertEqual(mine(store), ["👍"])
    }

    func testTheSameTapbackTwiceQuicklyEndsWithNone() async throws {
        let (store, backend) = try await makeStore()
        backend.setReactionDelay(.milliseconds(80))
        let first = Task { await store.toggleReaction("❤️", on: "$m1") }
        await waitUntil { self.mine(store) == ["❤️"] }
        await store.toggleReaction("❤️", on: "$m1")
        await first.value
        XCTAssertEqual(calls(backend), ["+❤️", "-❤️"])
        XCTAssertEqual(mine(store), [])
    }

    /// Review I2: when the new tapback is refused, the old one stays (its remove is never sent).
    func testReplaceWhoseAddFailsKeepsTheOldReaction() async throws {
        let (store, backend) = try await makeStore(reactions: [.init("👍", mine: true)])
        backend.setReactionHandler { call in
            if call.isAdd { throw CommsError.sendFailed(CommsSendFailure(reason: .rateLimited, status: 429)) }
        }
        await store.toggleReaction("😂", on: "$m1")
        XCTAssertEqual(calls(backend), ["+😂"], "the remove of 👍 was dropped")
        XCTAssertEqual(mine(store), ["👍"], "the old tapback stays")
        XCTAssertEqual(store.reactionNotice?.text, "Too many reactions. Try again in a moment.")
    }

    func testReplaceWhoseRemoveIsRefusedSaysSo() async throws {
        let (store, backend) = try await makeStore(reactions: [.init("👍", mine: true)])
        backend.setReactionHandler { call in
            if !call.isAdd { throw CommsError.sendFailed(CommsSendFailure(reason: .notFound, status: 404)) }
        }
        await store.toggleReaction("😂", on: "$m1")
        XCTAssertEqual(Set(mine(store)), ["👍", "😂"], "both stand: the phone's 👍 can't be removed from here")
        XCTAssertEqual(store.reactionNotice?.text, "Your earlier reaction was added from another device, so it couldn't be replaced here.")
    }

    /// Review M4: in a thread over several networks, the message's own channel decides.
    func testMessageChannelDecidesInAMultiNetworkThread() async throws {
        let backend = try FixtureBackend()
        var thread = FixtureMessages.thread(id: "th_mix", title: "Sam")
        thread.channels = [CommsChannelRef(network: .whatsapp, capabilities: CommsChannelCapabilities(react: true, send: true)),
                           CommsChannelRef(network: .imessage, capabilities: CommsChannelCapabilities(react: false, send: true))]
        backend.upsertThread(thread)
        backend.setMessagePages([nil: FixtureMessages.page([
            FixtureMessages.message(id: "$wa", threadID: "th_mix", network: "whatsapp", sender: "Sam", at: base, text: "WA"),
            FixtureMessages.message(id: "$im", threadID: "th_mix", network: "imessage", sender: "Sam", at: base.addingTimeInterval(1), text: "iM"),
        ], before: nil, hasMore: false)], threadID: "th_mix")
        let store = TimelineStore(backend: backend, threadID: "th_mix")
        await store.loadLatest()
        let wa = try XCTUnwrap(store.rows.lazy.compactMap { if case .message(let m, _, _, _) = $0, m.id == "$wa" { m } else { nil } }.first)
        let im = try XCTUnwrap(store.rows.lazy.compactMap { if case .message(let m, _, _, _) = $0, m.id == "$im" { m } else { nil } }.first)
        XCTAssertTrue(store.canReact(to: wa))
        XCTAssertFalse(store.canReact(to: im))
    }

    /// Owner ruling: Reply on iMessage / SMS quotes the message and sends WITHOUT replyTo.
    func testIMessageReplyQuotesAndSendsAsANormalMessage() async throws {
        for (network, name) in [("imessage", "iMessage"), ("sms", "SMS")] {
            let (store, backend) = try await makeStore(react: false, network: network)
            backend.setSendEcho(.none)
            let m = try XCTUnwrap(message(store, "$m1"))
            XCTAssertFalse(store.canReply(to: m), "no threaded reply on \(network)")
            XCTAssertTrue(store.offersReply(to: m), "Reply is still offered")
            store.beginReply(to: m)
            XCTAssertEqual(store.replyTarget?.id, "$m1")
            XCTAssertEqual(store.replyNote, "Sent as a normal message — \(name) threaded replies aren't available")
            await store.sendComposed(text: "Sure")
            XCTAssertEqual(backend.sendCalls.first?.text, "Sure")
            XCTAssertNil(backend.sendCalls.first?.replyTo, "sent without replyTo")
            XCTAssertNil(store.replyTarget)
        }
        let (wa, backend) = try await makeStore()
        backend.setSendEcho(.none)
        wa.beginReply(to: try XCTUnwrap(message(wa, "$m1")))
        XCTAssertNil(wa.replyNote, "threaded where the network has replies")
        await wa.sendComposed(text: "Yes")
        XCTAssertEqual(backend.sendCalls.first?.replyTo, "$m1")
        let (readOnly, _) = try await makeStore(send: false, network: "imessage")
        XCTAssertFalse(readOnly.offersReply(to: try XCTUnwrap(message(readOnly, "$m1"))), "no Reply where nothing can be sent")
    }

    func testAlreadyReactedStands() async throws {
        let (store, backend) = try await makeStore()
        backend.setReactionHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .alreadyReacted, status: 409)) }
        await store.toggleReaction("👍", on: "$m1")
        XCTAssertEqual(message(store, "$m1")?.reactions.first?.mine, true)
        XCTAssertNil(store.reactionNotice)
    }

    func testAcceptedChangeGivesWayToTheServerAfterTheWindow() async throws {
        let (store, _) = try await makeStore()
        await store.toggleReaction("👍", on: "$m1")
        XCTAssertEqual(message(store, "$m1")?.reactions.count, 1)
        clock = clock.addingTimeInterval(ReactionOverlay.confirmedTTL + 1)
        await store.refreshLatest()
        XCTAssertEqual(message(store, "$m1")?.reactions.count, 0, "the server never showed it: its state wins")
    }

    func testCapabilitiesGateReactions() async throws {
        let (store, backend) = try await makeStore(react: false, network: "imessage")
        XCTAssertFalse(store.canReact)
        let m = try XCTUnwrap(message(store, "$m1"))
        XCTAssertFalse(store.canReact(to: m))
        await store.toggleReaction("❤️", on: "$m1")
        XCTAssertTrue(backend.reactionCalls.isEmpty, "nothing sent where the channel can't react")
        XCTAssertFalse(store.canReply(to: m), "iMessage refuses sent replies (BlueBubbles 422)")
    }

    func testPendingAndSystemMessagesCannotTakeReactions() async throws {
        let (store, backend) = try await makeStore()
        backend.setSendEcho(.none)
        await store.send(text: "On my way")
        let pending = try XCTUnwrap(store.rows.lazy.compactMap { if case .message(let m, _, _, _) = $0, m.id.hasPrefix("pending-") { m } else { nil } }.first)
        XCTAssertFalse(store.canReact(to: pending))
        XCTAssertFalse(store.canReply(to: pending))
    }

    func testReplyGoesOutWithTheComposedText() async throws {
        let (store, backend) = try await makeStore()
        backend.setSendEcho(.none)
        let m = try XCTUnwrap(message(store, "$m1"))
        store.beginReply(to: m)
        XCTAssertEqual(store.replyTarget?.id, "$m1")
        await store.sendComposed(text: "Yes please")
        XCTAssertEqual(backend.sendCalls.first?.replyTo, "$m1")
        XCTAssertNil(store.replyTarget, "cleared once sent")
        let (noReply, _) = try await makeStore(reply: false)
        noReply.beginReply(to: m)
        XCTAssertNil(noReply.replyTarget, "no Reply where the channel has none")
    }

    func testPeopleListsEveryoneOnceYouFirst() {
        let reactions = [
            CommsReaction(key: "❤️", count: 3, mine: true, senders: [.init(id: "@a", name: "Alex"), .init(id: "@me", name: "Me")]),
            CommsReaction(key: "😂", count: 1, mine: false, senders: [.init(id: "@a", name: "Alex")]),
        ]
        let people = ReactionOverlay.people(reactions, selfIDs: ["@me"])
        XCTAssertEqual(people.map(\.name), ["You", "Alex", "1 other"])
        XCTAssertEqual(people[1].keys, ["❤️", "😂"])
        XCTAssertTrue(people[0].isSelf)
    }

    func testReactionPeopleOnTheStoreIncludesPendingChanges() async throws {
        let (store, _) = try await makeStore(reactions: [.init("👍", names: ["Sam"])])
        await store.toggleReaction("❤️", on: "$m1")
        XCTAssertEqual(store.reactionPeople(on: "$m1").map(\.name), ["You", "Sam"])
    }
}
