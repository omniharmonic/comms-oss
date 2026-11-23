import CommsClient
import CommsTestSupport
import Foundation
import OmniClient
import PrismModels
@testable import CommsCore
import XCTest

/// Omni in Comms (D9): `@Omni` is private, drafts need Approve & Send of the exact text after the
/// owner proves presence, Edit / Refine / Discard never send.
@MainActor
final class OmniStoreTests: XCTestCase {
    private let th = "th_o"

    private func make(presence: Bool = true) throws -> (OmniStore, FixtureBackend) {
        let backend = try FixtureBackend()
        backend.upsertThread(FixtureMessages.thread(id: th, title: "Alex"))
        backend.setSendEcho(.none)
        backend.omni.setAvailable(true)
        backend.omni.setDelay(.milliseconds(10))
        return (OmniStore(backend: backend, presence: FixedPresence(presence), pollInterval: .milliseconds(10), maxPolls: 50), backend)
    }

    func testAtOmniIsAnInstructionNotAMessage() {
        XCTAssertTrue(OmniStore.addressesOmni("@Omni say yes"))
        XCTAssertTrue(OmniStore.addressesOmni("@omni"))
        XCTAssertFalse(OmniStore.addressesOmni("@Omnibus is late"))
        XCTAssertFalse(OmniStore.addressesOmni("hi @Omni"))
        XCTAssertEqual(OmniStore.instruction(from: "@Omni, say yes to Thursday"), "say yes to Thursday")
        XCTAssertEqual(OmniStore.instruction(from: "draft a reply"), "draft a reply")
    }

    func testAskProducesADraftAndSendsNothing() async throws {
        let (store, backend) = try make()
        store.beginAsk(threadID: th, about: "$m1")
        XCTAssertTrue(store.omniComposer.contains(th))
        await store.ask(threadID: th, text: "@Omni say yes")
        XCTAssertFalse(store.omniComposer.contains(th), "the composer is back to messages")
        XCTAssertEqual(backend.omni.asks.map(\.instruction), ["say yes"])
        XCTAssertEqual(backend.omni.asks.first?.messageIDs, ["$m1"], "the message he pointed at")
        await store.pollSettled(th)
        XCTAssertFalse(store.isDrafting(th))
        XCTAssertEqual(store.drafts(th).count, 1)
        XCTAssertEqual(store.reply(th)?.reply.text, "Here's a draft for you to check.")
        XCTAssertTrue(backend.sendCalls.isEmpty, "Omni never sends")
    }

    func testApproveAndSendNeedsPresenceThenSendsTheExactText() async throws {
        let (store, backend) = try make(presence: false)
        let draft = backend.omni.addDraft(threadID: th, body: "Thursday works")
        await store.load(th)
        let sent = await store.approve(draft, threadID: th)
        XCTAssertFalse(sent)
        XCTAssertTrue(backend.omni.decisions.isEmpty, "no presence, no decision")
        XCTAssertTrue(backend.sendCalls.isEmpty)

        let (store2, backend2) = try make(presence: true)
        let d2 = backend2.omni.addDraft(threadID: th, body: "Thursday works")
        await store2.load(th)
        let ok = await store2.approve(d2, threadID: th)
        XCTAssertTrue(ok)
        XCTAssertEqual(backend2.omni.decisions.map(\.decision), ["send"])
        XCTAssertEqual(backend2.omni.decisions.first?.digest, d2.digest, "the digest of the draft he saw")
        XCTAssertEqual(backend2.sendCalls.map(\.text), ["Thursday works"])
        XCTAssertTrue(store2.drafts(th).isEmpty, "sent: no longer pending")
    }

    func testAChangedDraftIsRefused() async throws {
        let (store, backend) = try make()
        let shown = backend.omni.addDraft(threadID: th, body: "v1")
        await store.load(th)
        // A copy whose text differs from the server's draft (its digest is not the server's):
        // refused, nothing sent.
        let stale = FixtureOmni.approval(id: shown.id, threadID: th, body: "edited locally")
        let ok = await store.approve(stale, threadID: th)
        XCTAssertFalse(ok)
        XCTAssertTrue(backend.sendCalls.isEmpty)
        XCTAssertEqual(store.notices[th]?.text, "This draft changed. Review it again before sending.")
    }

    func testDiscardRefineAndEditNeverSend() async throws {
        let (store, backend) = try make()
        let a = backend.omni.addDraft(threadID: th, body: "One")
        let b = backend.omni.addDraft(threadID: th, body: "Two")
        let c = backend.omni.addDraft(threadID: th, body: "Three")
        await store.load(th)
        await store.discard(a, threadID: th)
        await store.refine(b, threadID: th, feedback: "shorter")
        await store.pollSettled(th)
        await store.edit(c, threadID: th)
        XCTAssertEqual(store.composerInsert[th], "Three", "Edit moves the text into the composer")
        XCTAssertEqual(backend.omni.decisions.map(\.decision), ["cancel", "revise", "cancel"])
        XCTAssertEqual(backend.omni.decisions[1].feedback, "shorter")
        XCTAssertTrue(backend.sendCalls.isEmpty)
        XCTAssertEqual(store.drafts(th).map { CommsDraft($0)?.body }, ["Two (shorter)"], "Refine brought a new draft")
    }

    func testNeedsYouListsPendingProposals() async throws {
        let (store, backend) = try make()
        backend.omni.addDraft(threadID: th, body: "A")
        backend.omni.addDraft(threadID: "th_2", body: "B")
        await store.loadNeedsYou()
        XCTAssertEqual(store.needsYou.count, 2)
    }

    func testUnavailableOffersNothing() async throws {
        let (store, backend) = try make()
        backend.omni.setAvailable(false)
        await store.ask(threadID: th, text: "@Omni hi")
        await store.loadNeedsYou()
        XCTAssertTrue(backend.omni.asks.isEmpty)
        XCTAssertTrue(store.needsYou.isEmpty)
    }

    // MARK: Review fix round 1

    func testEditMovesTextOnlyAfterTheDraftIsTakenBack() async throws {
        let (store, backend) = try make()
        let d = backend.omni.addDraft(threadID: th, body: "Already approved elsewhere")
        await store.load(th)
        // The Omni app approved it a moment earlier.
        _ = try await backend.decide(draft: d, .send, feedback: nil, idempotencyKey: .random())
        await store.edit(d, threadID: th)
        XCTAssertNil(store.composerInsert[th], "no second copy of an already-decided draft in the composer")
        XCTAssertNotNil(store.notices[th])
    }

    func testAtOmniIsNeverSentToTheChat() async throws {
        let backend = try FixtureBackend()
        var thread = FixtureMessages.thread(id: th, title: "Alex")
        thread.channels[0].capabilities = CommsChannelCapabilities(reply: true, attachments: true, send: true)
        backend.upsertThread(thread)
        backend.setMessagePages([nil: FixtureMessages.page([], before: nil, hasMore: false)], threadID: th)
        let timeline = TimelineStore(backend: backend, threadID: th)
        await timeline.loadLatest()
        await timeline.send(text: "@Omni tell him no, politely")
        await timeline.send(text: "  @omni: anything")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(backend.sendCalls.isEmpty, "Omni off or on, @Omni text never reaches the chat")
        await timeline.send(text: "@Omnibus at 6")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(backend.sendCalls.map(\.text), ["@Omnibus at 6"])
    }

    func testAvailabilityIsObservedAndUnknownMeansUnavailable() async throws {
        let backend = try FixtureBackend()
        let store = OmniStore(backend: backend, presence: FixedPresence(true))
        XCTAssertFalse(store.isAvailable, "unknown = unavailable (and @Omni is then blocked, not sent)")
        backend.omni.setAvailable(true)
        await store.loadNeedsYou()
        XCTAssertTrue(store.isAvailable)
    }

    func testAddressesOmniForms() {
        for t in ["@Omni. hi", "@Omni— hi", "@Omni? x", "@Omni! x", "\t@Omni x", "  \n@omni", "@OMNI;x"] {
            XCTAssertTrue(OmniStore.addressesOmni(t), t)
        }
        for t in ["@Omnibus", "@Omni2", "x @Omni", "omni"] { XCTAssertFalse(OmniStore.addressesOmni(t), t) }
        XCTAssertEqual(OmniStore.instruction(from: "@Omni— say yes"), "say yes")
    }

    func testEditRefusesHiddenCharacters() async throws {
        let (store, backend) = try make()
        let d = backend.omni.addDraft(threadID: th, body: "Fine\u{E0100}")
        await store.load(th)
        await store.edit(d, threadID: th)
        XCTAssertNil(store.composerInsert[th], "never moved into the composer")
        XCTAssertTrue(backend.omni.decisions.isEmpty)
    }

    func testApproveRefusesHiddenCharacters() async throws {
        let (store, backend) = try make()
        let d = backend.omni.addDraft(threadID: th, body: "Fine\u{E0100}")
        await store.load(th)
        let ok = await store.approve(d, threadID: th)
        XCTAssertFalse(ok)
        XCTAssertTrue(backend.omni.decisions.isEmpty, "refused before anything is decided")
        XCTAssertTrue(backend.sendCalls.isEmpty)
    }
}
