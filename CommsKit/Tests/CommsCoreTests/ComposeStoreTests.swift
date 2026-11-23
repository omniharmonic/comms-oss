import CommsClient
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

/// Phase 2b C3: the New Message To: field and starting an iMessage/SMS conversation.
@MainActor
final class ComposeStoreTests: XCTestCase {
    private func backend() throws -> FixtureBackend {
        let b = try FixtureBackend(capabilities: .success(FixtureBackend.validCapabilities))
        b.setThreads([])
        var ann = FixtureMessages.thread(id: "th_ann_wa", title: "Ann Lee", network: "whatsapp")
        ann.personId = "ann"
        var bob = FixtureMessages.thread(id: "th_bob_im", title: "Bob Stone", network: "imessage")
        bob.personId = "bob"
        b.upsertThread(ann)
        b.upsertThread(bob)
        b.setThreadDetail(FixtureMessages.detail(bob, contact: CommsContact(phones: [.init(value: "+15550002")])))
        b.setPerson(CommsPerson(id: "ann", name: "Ann Lee", contact: CommsContact(phones: [.init(value: "+15550001")], emails: [.init(value: "ann@example.test")])))
        b.setPerson(CommsPerson(id: "bob", name: "Bob Stone", contact: CommsContact(phones: [.init(value: "+15550002")])))
        b.setPerson(CommsPerson(id: "cy", name: "Cy Telegram", contact: CommsContact()))
        return b
    }

    func testTypingIsDebouncedAndSuggestsPeopleAndConversations() async throws {
        let b = try backend()
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(40))
        for t in ["a", "an", "ann"] { store.toText = t }
        XCTAssertTrue(store.isLooking)
        await store.lookupWork?.value
        XCTAssertEqual(store.lookups, ["ann"], "one lookup for the last text")
        XCTAssertEqual(store.addressSuggestions.map(\.value), ["+15550001", "ann@example.test"])
        XCTAssertEqual(store.conversationSuggestions.map(\.id), ["th_ann_wa"], "her WhatsApp chat, any network")
        XCTAssertNil(store.hint)
        store.toText = ""
        XCTAssertNil(store.results)
    }

    func testStaleLookupIsDropped() async throws {
        let b = try backend()
        b.setRecipientsDelay(.milliseconds(120))
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(1))
        store.toText = "ann"
        try await Task.sleep(for: .milliseconds(30))
        let stale = store.lookupWork
        store.toText = "bob"
        await stale?.value
        XCTAssertNil(store.results, "the 'ann' answer never lands")
        await store.lookupWork?.value
        XCTAssertEqual(store.addressSuggestions.map(\.value), ["+15550002"])
    }

    func testPickingAConversationOrAnAddressWithOneOpensIt() async throws {
        let b = try backend()
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(1))
        store.toText = "bob"
        await store.lookupWork?.value
        let bobPhone = try XCTUnwrap(store.addressSuggestions.first)
        XCTAssertEqual(bobPhone.threadID, "th_bob_im")
        XCTAssertEqual(store.choose(bobPhone), .open(threadID: "th_bob_im"))
        XCTAssertEqual(store.choose(thread: store.conversationSuggestions[0]), .open(threadID: "th_bob_im"))
        XCTAssertTrue(b.conversationCalls.isEmpty, "opening sends nothing")
    }

    func testNewConversationStartsWithTheMessage() async throws {
        let b = try backend()
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(1))
        store.toText = "ann"
        await store.lookupWork?.value
        let phone = try XCTUnwrap(store.addressSuggestions.first)
        XCTAssertEqual(store.choose(phone), .chosen)
        XCTAssertEqual(store.recipient?.title, "Ann Lee")
        XCTAssertFalse(store.canSend, "no text yet")
        store.network = .sms
        store.messageText = "  Hi Ann  "
        let outcome = await store.send()
        XCTAssertEqual(outcome, .open(threadID: "th_new_1"))
        XCTAssertEqual(b.conversationCalls.map(\.handle), ["+15550001"])
        XCTAssertEqual(b.conversationCalls.first?.network, "sms")
        XCTAssertEqual(b.conversationCalls.first?.text, "Hi Ann")
        XCTAssertEqual(store.messageText, "")
    }

    func testEmailAlwaysGoesAsIMessage() async throws {
        let b = try backend()
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(1))
        store.toText = "ann"
        await store.lookupWork?.value
        _ = store.choose(store.addressSuggestions[1])
        store.network = .sms
        store.messageText = "hello"
        _ = await store.send()
        XCTAssertEqual(b.conversationCalls.first?.network, "imessage")
    }

    func testExistingAnswerSendsThroughTheOutboxInstead() async throws {
        let b = try backend()
        b.setSendEcho(.none)
        b.setConversationHandler { _ in CommsNewConversation(existing: true, threadId: "th_bob_im") }
        let outbox = Outbox(backend: b)
        let store = ComposeStore(backend: b, outbox: outbox, lookupDelay: .milliseconds(1))
        store.toText = "+1 555 000 0009"
        await store.lookupWork?.value
        let typed = try XCTUnwrap(store.typedAddress)
        XCTAssertEqual(typed.value, "+15550000009")
        XCTAssertEqual(store.choose(typed: typed), .chosen)
        store.messageText = "Are you there?"
        let outcome = await store.send()
        XCTAssertEqual(outcome, .open(threadID: "th_bob_im"))
        let deadline = Date().addingTimeInterval(2)
        while b.sendCalls.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(b.sendCalls.map(\.threadID), ["th_bob_im"])
        XCTAssertEqual(b.sendCalls.first?.text, "Are you there?", "the existing conversation gets the message, once")
    }

    func testFailureKeepsTextAndTryAgainReusesTheClientID() async throws {
        let b = try backend()
        let fails = OneShotFlag(true)
        b.setConversationHandler { _ in
            if fails.take() { throw CommsError.sendFailed(CommsSendFailure(reason: .sendFailed, message: nil, maybeSent: true, status: 502)) }
            return nil
        }
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(1))
        store.toText = "ann"
        await store.lookupWork?.value
        _ = store.choose(store.addressSuggestions[0])
        store.messageText = "Hi"
        let first = await store.send()
        XCTAssertNil(first)
        XCTAssertEqual(store.failure?.reason, .sendFailed)
        XCTAssertEqual(store.messageText, "Hi", "the text stays")
        let second = await store.send()
        XCTAssertNotNil(second)
        let ids = b.conversationCalls.map(\.clientID)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1], "Try Again: the same clientId")
    }

    func testPendingConversationIsWaitedForThenOpened() async throws {
        let b = try backend()
        b.setConversationHandler { _ in CommsNewConversation(existing: false, threadId: "th_later", pending: true) }
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(1))
        store.pendingPoll = (.milliseconds(5), 3)
        store.toText = "ann"
        await store.lookupWork?.value
        _ = store.choose(store.addressSuggestions[0])
        store.messageText = "Hi"
        let outcome = await store.send()
        XCTAssertEqual(outcome, .open(threadID: "th_later"))
    }

    func testHintsForOtherNetworksAndNumbersWithoutCountryCode() async throws {
        let b = try backend()
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(1))
        store.toText = "cy"
        await store.lookupWork?.value
        XCTAssertEqual(store.hint, "New conversations can be started with iMessage or SMS. Cy Telegram’s other chats are listed here.")
        store.toText = "555 123 4567"
        await store.lookupWork?.value
        XCTAssertEqual(store.hint, "Include the country code, like +1 555 123 4567.")
        XCTAssertNil(store.typedAddress)
    }

    /// Review I4: Return in To: never takes a suggestion for older text.
    func testReturnWhileLookingTakesNothing() async throws {
        let b = try backend()
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(40))
        store.toText = "bo"
        await store.lookupWork?.value
        XCTAssertEqual(store.addressSuggestions.first?.name, "Bob Stone")
        store.toText = "ann"
        XCTAssertTrue(store.isLooking, "the list on screen still answers 'bo'")
        // Return now waits for the answer to what is typed: never Bob.
        let outcome = await store.commitTo()
        XCTAssertEqual(outcome, .chosen)
        XCTAssertEqual(store.recipient?.name, "Ann Lee")
    }

    /// "Send to <handle>" only on a commit: the typed address is not a live suggestion row,
    /// Return takes it (and opens its conversation when one exists).
    func testTypedAddressIsTakenOnlyOnCommit() async throws {
        let b = try backend()
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(1))
        store.toText = "+1 555 000 0009"
        await store.lookupWork?.value
        XCTAssertTrue(store.addressSuggestions.isEmpty, "no live 'Send to' row")
        XCTAssertNil(store.recipient)
        let first = await store.commitTo()
        XCTAssertEqual(first, .chosen)
        XCTAssertEqual(store.recipient?.value, "+15550000009")
        store.clearRecipient()
        store.toText = "+1 555 000 2"
        let second = await store.commitTo()
        XCTAssertEqual(second, .open(threadID: "th_bob_im"), "an address with a conversation opens it")
    }

    func testInProgressSaysAConversationWasJustStarted() async throws {
        let b = try backend()
        b.setConversationHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .inProgress, maybeSent: true, status: 409)) }
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(1))
        store.toText = "ann"
        await store.lookupWork?.value
        _ = store.choose(store.addressSuggestions[0])
        store.messageText = "Hi"
        let outcome = await store.send()
        XCTAssertNil(outcome)
        XCTAssertEqual(store.failureText, "A conversation with this address was just started. Try again in a moment.")
    }

    /// Review m1: removing the chip and choosing the same address again keeps the clientId,
    /// so a Try Again after "may have been sent" never starts the conversation twice.
    func testReaddingTheSameRecipientKeepsTheClientID() async throws {
        let b = try backend()
        let fails = OneShotFlag(true)
        b.setConversationHandler { _ in
            if fails.take() { throw CommsError.sendFailed(CommsSendFailure(reason: .outcomeUnknown, maybeSent: true)) }
            return nil
        }
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(1))
        store.toText = "ann"
        await store.lookupWork?.value
        _ = store.choose(store.addressSuggestions[0])
        store.messageText = "Hi"
        _ = await store.send()
        store.clearRecipient()
        await store.lookupWork?.value
        _ = store.choose(store.addressSuggestions[0])
        _ = await store.send()
        let ids = b.conversationCalls.map(\.clientID)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1])
    }

    /// A conversation opened before the server projected it (404): the transcript loads it
    /// when its `thread.updated` arrives.
    func testTranscriptLoadsWhenThePendingConversationAppears() async throws {
        let b = try backend()
        b.setMessagesError(CommsError.threadUnavailable)
        let timeline = TimelineStore(backend: b, threadID: "th_later")
        await timeline.loadLatest()
        XCTAssertNotNil(timeline.loadError)
        b.setMessagesError(nil)
        var t = FixtureMessages.thread(id: "th_later", title: "+15550009", network: "imessage")
        t.lastActivityAt = Date()
        b.upsertThread(t)
        b.setMessagePages([nil: FixtureMessages.page([FixtureMessages.message(id: "m_first", threadID: "th_later", outgoing: true, at: Date(), text: "Hi")], before: nil, hasMore: false)], threadID: "th_later")
        timeline.apply(CommsEvent(id: "e1", kind: .threadUpdated, payload: ["threadId": "th_later"]))
        await timeline.pendingWork?.value
        XCTAssertNil(timeline.loadError)
        XCTAssertEqual(timeline.rows.compactMap { if case .message(let m, _, _, _) = $0 { m.id } else { nil } }, ["m_first"])
    }

    func testClearingTheChipLooksUpAgain() async throws {
        let b = try backend()
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(1))
        store.toText = "ann"
        await store.lookupWork?.value
        _ = store.choose(store.addressSuggestions[0])
        XCTAssertNil(store.results)
        store.clearRecipient()
        await store.lookupWork?.value
        XCTAssertNil(store.recipient)
        XCTAssertFalse(store.addressSuggestions.isEmpty)
    }
}

/// A one-shot flag usable from a `@Sendable` handler.
final class OneShotFlag: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    init(_ v: Bool) { value = v }
    /// The value, then false.
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let v = value
        value = false
        return v
    }
}
