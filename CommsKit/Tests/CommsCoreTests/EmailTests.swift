import CommsClient
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

/// Email in Comms (PRD §5.8, D11): a reply carries the header the composer showed; a thread
/// without a reply header cannot send; a new email needs an address, Email and a subject.
@MainActor
final class EmailTests: XCTestCase {
    private let base = PrismJSON.parseDate("2026-11-20T14:00:00Z")!
    private let header = CommsEmailDetail.Reply(to: ["ann@x.test"], cc: [], subject: "Re: Plan")

    private let all = CommsEmailDetail.Reply(to: ["ann@x.test"], cc: ["bob@x.test"], subject: "Re: Plan")
    private func makeStore(reply: CommsEmailDetail.Reply?, replyAll: CommsEmailDetail.Reply? = nil) async throws -> (TimelineStore, FixtureBackend) {
        let backend = try FixtureBackend()
        var thread = FixtureMessages.thread(id: "th_e", title: "Ann Lee", network: "email")
        thread.channels[0].capabilities = CommsChannelCapabilities(reply: false, attachments: false, send: true)
        backend.upsertThread(thread)
        backend.setThreadDetail(CommsThreadDetail(thread: thread, capabilities: thread.channels[0].capabilities,
                                                  email: CommsEmailDetail(account: "owner@x.test", reply: reply, replyAll: replyAll, replyUnavailable: reply == nil ? "account" : nil)))
        var m = FixtureMessages.message(id: "n1", threadID: "th_e", network: "email", sender: "Ann Lee", at: base, text: "Here's the plan.")
        m.email = CommsMessage.Email(subject: "Plan", from: "Ann Lee <ann@x.test>", to: ["owner@x.test"], cc: ["bob@x.test"])
        backend.setMessagePages([nil: FixtureMessages.page([m], before: nil, hasMore: false)], threadID: "th_e")
        backend.setSendEcho(.none)
        let store = TimelineStore(backend: backend, threadID: "th_e", now: { [base] in base.addingTimeInterval(60) })
        await store.loadLatest()
        return (store, backend)
    }

    func testReplySendsTheShownHeaderAndNoAttachments() async throws {
        let (store, backend) = try await makeStore(reply: header)
        XCTAssertTrue(store.isEmail)
        XCTAssertEqual(store.emailReply, header)
        XCTAssertTrue(store.canSend)
        XCTAssertFalse(store.canReply, "no per-message reply on email: the reply answers the thread")
        let file = OutgoingAttachment(kind: .file, data: Data(count: 10), mime: "application/pdf", filename: "a.pdf")
        await store.send(text: "Works for me.", attachments: [file])
        XCTAssertEqual(backend.sendCalls.count, 1, "attachments are not sent by email")
        XCTAssertEqual(backend.sendCalls[0].email, header)
        XCTAssertEqual(backend.sendCalls[0].text, "Works for me.")
        let pending = try XCTUnwrap(store.pendingSends.first { $0.email != nil })
        XCTAssertEqual(pending.email, header)
        // M8: the attachment is never dropped silently: a "Not Delivered" bubble with the reason.
        let refused = try XCTUnwrap(store.pendingSends.first { if case .attachment = $0.content { true } else { false } })
        XCTAssertEqual(refused.failure?.reason, .unsupportedNetwork)
        XCTAssertEqual(refused.failure?.isFinal, true)
    }

    func testPendingEmailBubbleShowsTheSubject() async throws {
        let (store, backend) = try await makeStore(reply: header)
        backend.setSendDelay(.milliseconds(200))
        let t = Task { await store.send(text: "On it") }
        let end = Date().addingTimeInterval(2)
        while store.pendingSends.isEmpty, Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        let pending = store.rows.compactMap { if case .message(let m, _, _, _) = $0, m.sender.isSelf { m } else { nil } }.last
        XCTAssertEqual(pending?.email?.subject, "Re: Plan")
        XCTAssertEqual(pending?.email?.to, ["ann@x.test"])
        await t.value
    }

    func testNoReplyHeaderMeansNoSend() async throws {
        let (store, backend) = try await makeStore(reply: nil)
        XCTAssertFalse(store.canSend, "never a reply to recipients the composer can't show")
        await store.send(text: "hello")
        XCTAssertTrue(backend.sendCalls.isEmpty)
    }

    func testFailureSurfacesTheServerSentence() async throws {
        let (store, backend) = try await makeStore(reply: header)
        backend.setSendHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .other("target_changed"), message: "The recipients changed.")) }
        await store.send(text: "hi")
        let f = try XCTUnwrap(store.pendingSends.first?.failure)
        XCTAssertEqual(f.message, "The recipients changed.")
        XCTAssertFalse(f.maybeSent)
    }

    func testNewEmailNeedsEmailAndASubject() async throws {
        let backend = try FixtureBackend()
        let compose = ComposeStore(backend: backend, outbox: Outbox(backend: backend), lookupDelay: .zero)
        _ = compose.choose(typed: CommsRecipientHandle(kind: .email, value: "dana@example.test"))
        compose.messageText = "Hi Dana"
        XCTAssertFalse(compose.isEmail, "iMessage by default for an email address")
        compose.network = .email
        XCTAssertTrue(compose.isEmail)
        XCTAssertFalse(compose.canSend, "a subject first")
        compose.subject = "Hello"
        XCTAssertTrue(compose.canSend)
        let outcome = await compose.send()
        XCTAssertEqual(backend.emailCalls.count, 1)
        XCTAssertEqual(backend.emailCalls[0].handle, "dana@example.test\nHello")
        XCTAssertEqual(backend.emailCalls[0].text, "Hi Dana")
        XCTAssertTrue(backend.conversationCalls.isEmpty, "not an iMessage")
        guard case .open(let id)? = outcome else { return XCTFail("opens the new conversation") }
        XCTAssertTrue(id.hasPrefix("th_email_"))
        XCTAssertEqual(compose.subject, "")
    }

    func testPhoneRecipientNeverSendsEmail() async throws {
        let backend = try FixtureBackend()
        let compose = ComposeStore(backend: backend, outbox: Outbox(backend: backend), lookupDelay: .zero)
        _ = compose.choose(typed: CommsRecipientHandle(kind: .phone, value: "+15550001"))
        compose.network = .email
        compose.messageText = "hi"
        XCTAssertFalse(compose.isEmail)
        _ = await compose.send()
        XCTAssertTrue(backend.emailCalls.isEmpty)
        XCTAssertEqual(backend.conversationCalls.first?.network, "imessage")
    }

    // MARK: Fix round 1 (I1)

    func testReplyIsTheDefaultAndReplyAllIsAnExplicitChoice() async throws {
        let (store, backend) = try await makeStore(reply: header, replyAll: all)
        XCTAssertTrue(store.canReplyAll)
        XCTAssertEqual(store.emailReply, header, "Mail's default: the sender only")
        await store.send(text: "Only Ann")
        store.setEmailReplyAll(true)
        XCTAssertEqual(store.emailReply, all)
        await store.send(text: "Everyone")
        store.setEmailReplyAll(false)
        XCTAssertEqual(backend.sendCalls.map(\.email), [header, all], "each send carries the set the header showed")
    }

    func testNoReplyAllWhenItAddsNobody() async throws {
        let (store, _) = try await makeStore(reply: header, replyAll: nil)
        XCTAssertFalse(store.canReplyAll)
        store.setEmailReplyAll(true)
        XCTAssertFalse(store.emailReplyAll)
        XCTAssertEqual(store.emailReply, header)
    }

    func testTargetChangedIsFinalAndRefetchesTheHeader() async throws {
        let (store, backend) = try await makeStore(reply: header, replyAll: all)
        backend.setSendHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .other("target_changed"), message: "The recipients changed.")) }
        let before = backend.threadCalls
        await store.send(text: "hi")
        XCTAssertEqual(store.pendingSends.first?.failure?.isFinal, true, "Try Again would echo the old header")
        let end = Date().addingTimeInterval(3)
        while backend.threadCalls == before, Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(backend.threadCalls, before, "the header is fetched again")
    }
}
