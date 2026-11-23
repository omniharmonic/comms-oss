import CommsClient
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

@MainActor
final class SendingTests: XCTestCase {
    private let base = PrismJSON.parseDate("2026-11-20T14:00:00Z")!

    /// A WhatsApp thread whose channel declares `send` (or not), with one incoming message.
    private func makeStore(canSend: Bool = true, network: String = "whatsapp") async throws -> (TimelineStore, FixtureBackend) {
        let backend = try FixtureBackend()
        var thread = FixtureMessages.thread(id: "th_s", title: "Sam", network: network)
        thread.channels[0].capabilities = CommsChannelCapabilities(reply: true, attachments: true, send: canSend)
        backend.upsertThread(thread)
        backend.setMessagePages([nil: FixtureMessages.page([
            FixtureMessages.message(id: "m1", threadID: "th_s", network: network, sender: "Sam", at: base, text: "Hi"),
        ], before: nil, hasMore: false)], threadID: "th_s")
        backend.setSendEcho(.none)
        let store = TimelineStore(backend: backend, threadID: "th_s", now: { [base] in base.addingTimeInterval(120) })
        await store.loadLatest()
        return (store, backend)
    }

    private func messages(_ store: TimelineStore) -> [CommsMessage] {
        store.rows.compactMap { if case .message(let m, _, _, _) = $0 { m } else { nil } }
    }

    /// The server's echo of a send: from the owner, `source.eventId` = the send's event id.
    private func echo(_ eventID: String, text: String?, id: String = "srv_1") -> CommsEvent {
        var m = FixtureMessages.message(id: id, threadID: "th_s", outgoing: true, at: base.addingTimeInterval(121), text: text, delivery: "sent")
        m.source.eventId = eventID
        return FixtureMessages.event(.messageCreated, m)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 2) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testCanSendFollowsTheChannelFlag() async throws {
        let (yes, _) = try await makeStore(canSend: true)
        XCTAssertTrue(yes.canSend)
        let (no, backend) = try await makeStore(canSend: false, network: "imessage")
        XCTAssertFalse(no.canSend)
        await no.send(text: "hello")
        XCTAssertTrue(backend.sendCalls.isEmpty, "nothing is sent where the server does not declare send")
        XCTAssertTrue(no.pendingSends.isEmpty)
    }

    func testTextShowsPendingThenSentThenReconcilesWithTheEcho() async throws {
        let (store, backend) = try await makeStore()
        backend.setSendDelay(.milliseconds(150))
        let task = Task { await store.send(text: "  On my way  \n") }
        await waitUntil { !store.pendingSends.isEmpty }
        let pending = try XCTUnwrap(messages(store).last)
        XCTAssertTrue(pending.sender.isSelf)
        XCTAssertEqual(pending.delivery, .pending, "Sending…")
        XCTAssertEqual(pending.body?.plain, "On my way", "trimmed as Messages does")
        XCTAssertNotNil(store.pendingSend(for: pending))
        await task.value

        let call = try XCTUnwrap(backend.sendCalls.first)
        XCTAssertEqual(call.text, "On my way")
        XCTAssertNotNil(UUID(uuidString: call.clientID), "clientId is a UUID")
        XCTAssertEqual(store.pendingSends.first?.state, .sent(eventID: "$fx_sent_1"))
        XCTAssertEqual(messages(store).last?.delivery, .sent)

        store.apply(echo("$fx_sent_1", text: "On my way"))
        XCTAssertTrue(store.pendingSends.isEmpty, "the echo replaces the pending bubble")
        XCTAssertEqual(messages(store).map(\.id), ["m1", "srv_1"], "one bubble, not two")
    }

    func testEchoBeforeTheHTTPAnswerStillEndsWithOneBubble() async throws {
        let (store, backend) = try await makeStore()
        backend.setSendDelay(.milliseconds(150))
        let task = Task { await store.send(text: "Quick") }
        await waitUntil { !backend.sendCalls.isEmpty }
        store.apply(echo("$fx_sent_1", text: "Quick"))
        await task.value
        XCTAssertTrue(store.pendingSends.isEmpty)
        XCTAssertEqual(messages(store).map(\.id), ["m1", "srv_1"])
    }

    func testEchoCarryingTheClientIDReconcilesEvenBeforeTheAnswer() async throws {
        let (store, backend) = try await makeStore()
        backend.setSendDelay(.milliseconds(150))
        let task = Task { await store.send(text: "By client id") }
        await waitUntil { !backend.sendCalls.isEmpty }
        var m = FixtureMessages.message(id: "srv_c", threadID: "th_s", outgoing: true, at: base.addingTimeInterval(121), text: "By client id")
        m.source.eventId = "$other"
        m.clientId = backend.sendCalls[0].clientID.uppercased()
        store.apply(FixtureMessages.event(.messageCreated, m))
        XCTAssertTrue(store.pendingSends.isEmpty, "matched by clientId while the send is still in flight")
        await task.value
        XCTAssertTrue(store.pendingSends.isEmpty, "the late answer does not bring the bubble back")
        XCTAssertEqual(messages(store).map(\.id), ["m1", "srv_c"])
    }

    func testServerSentenceShownForSendFailed() async throws {
        let (store, backend) = try await makeStore()
        backend.setSendHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .sendFailed, message: "This message can no longer be retried safely.", maybeSent: true, status: 502)) }
        await store.send(text: "x")
        XCTAssertEqual(messages(store).last?.deliveryError, "This message can no longer be retried safely.")
    }

    func testReloadedPageAlsoReconciles() async throws {
        let (store, backend) = try await makeStore()
        backend.setSendEcho(.immediate) // the newest page now holds the echo
        await store.send(text: "Via reload")
        XCTAssertEqual(store.pendingSends.count, 1)
        await store.refreshLatest()
        XCTAssertTrue(store.pendingSends.isEmpty)
        XCTAssertEqual(messages(store).filter { $0.body?.plain == "Via reload" }.count, 1)
    }

    func testFailureIsNotDeliveredAndNeverRetriedAutomatically() async throws {
        let (store, backend) = try await makeStore()
        backend.setSendHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .sendFailed, maybeSent: true, status: 502)) }
        await store.send(text: "Did it go?")
        let failed = try XCTUnwrap(messages(store).last)
        XCTAssertEqual(failed.delivery, .failed)
        XCTAssertEqual(failed.deliveryError, "This message may have been sent. Check before trying again.")
        XCTAssertEqual(store.pendingSend(for: failed)?.failure?.maybeSent, true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(backend.sendCalls.count, 1, "maybeSent: never resent on its own")

        // Try Again reuses the same clientId.
        backend.setSendHandler(nil)
        let clientID = backend.sendCalls[0].clientID
        await store.retrySend(clientID: clientID)
        XCTAssertEqual(backend.sendCalls.map(\.clientID), [clientID, clientID])
        XCTAssertEqual(store.pendingSends.first?.state, .sent(eventID: "$fx_sent_2"))
        XCTAssertEqual(messages(store).last?.delivery, .sent)
    }

    func testOtherErrorsMapToNotDelivered() async throws {
        let (store, backend) = try await makeStore()
        backend.setSendHandler { _ in throw CommsError.clientScope }
        await store.send(text: "a")
        XCTAssertEqual(store.pendingSends.last?.failure?.reason, .other("client_scope"))
        XCTAssertEqual(store.pendingSends.last?.failure?.maybeSent, false)
        backend.setSendHandler { _ in throw URLError(.badServerResponse) }
        await store.send(text: "b")
        XCTAssertEqual(store.pendingSends.last?.failure?.maybeSent, true, "unknown errors are treated as maybe sent")
        XCTAssertEqual(backend.sendCalls.count, 2)
    }

    func testRetryOnlyForFailedAndDiscardRemoves() async throws {
        let (store, backend) = try await makeStore()
        await store.send(text: "fine")
        let id = try XCTUnwrap(store.pendingSends.first?.clientID)
        await store.retrySend(clientID: id)
        XCTAssertEqual(backend.sendCalls.count, 1, "a sent message is not resent")

        backend.setSendHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .rateLimited, status: 429)) }
        await store.send(text: "nope")
        let failedID = try XCTUnwrap(store.pendingSends.last?.clientID)
        store.discardSend(clientID: id)
        XCTAssertEqual(store.pendingSends.count, 2, "only failed sends can be deleted")
        store.discardSend(clientID: failedID)
        XCTAssertEqual(store.pendingSends.map(\.clientID), [id])
        XCTAssertFalse(messages(store).contains { $0.body?.plain == "nope" })
    }

    func testAttachmentsGoFirstEachWithItsOwnClientIDThenTheText() async throws {
        let (store, backend) = try await makeStore()
        let photo = OutgoingAttachment(kind: .image, data: FixtureMessages.placeholderPNG, mime: "image/png", filename: "a.png", pixelWidth: 4, pixelHeight: 3)
        let voice = OutgoingAttachment(kind: .voice, data: Data([1, 2, 3]), mime: "audio/mp4", filename: "Audio.m4a", durationMs: 3000, waveform: [0, 512, 1024])
        await store.send(text: "caption", attachments: [photo, voice])
        let calls = backend.sendCalls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].attachment?.id, photo.id)
        XCTAssertEqual(calls[0].clientID, photo.id.uuidString.lowercased())
        XCTAssertEqual(calls[1].attachment?.kind, .voice)
        XCTAssertEqual(calls[1].attachment?.waveform, [0, 512, 1024])
        XCTAssertEqual(calls[2].text, "caption")
        XCTAssertEqual(Set(calls.map(\.clientID)).count, 3)

        let shown = messages(store).suffix(3)
        XCTAssertEqual(shown.map { $0.attachments.first?.kind }, [.image, .voice, nil])
        let picture = try XCTUnwrap(shown.first?.attachments.first)
        XCTAssertEqual(picture.mediaToken, photo.localToken, "the local picture shows while pending")
        let preview = try XCTUnwrap(LocalMedia.data(for: photo.localToken), "a preview stays for the bubble")
        XCTAssertEqual(preview.prefix(2), Data([0xFF, 0xD8]), "uploaded: the full bytes became a small JPEG preview")
        XCTAssertNil(LocalMedia.data(for: voice.localToken), "uploaded voice: bytes released")
        if case .attachment(let a)? = store.pendingSends.first?.content { XCTAssertTrue(a.data.isEmpty) } else { XCTFail() }
        XCTAssertEqual(picture.w, 4)
        XCTAssertEqual(shown.dropFirst().first?.attachments.first?.durationMs, 3000)

        // The echo of the photo drops its local bytes.
        var echoed = FixtureMessages.message(id: "srv_p", threadID: "th_s", outgoing: true, at: base.addingTimeInterval(130), text: nil,
                                             attachments: [FixtureMessages.image(token: "tok_p", w: 4, h: 3)])
        echoed.source.eventId = "$fx_sent_1"
        store.apply(FixtureMessages.event(.messageCreated, echoed))
        XCTAssertNil(LocalMedia.data(for: photo.localToken))
        XCTAssertEqual(store.pendingSends.count, 2)
    }

    func testTooLargeFailsLocallyWithoutUploading() async throws {
        let (store, backend) = try await makeStore()
        store.maxAttachmentBytes = 2
        await store.send(text: "", attachments: [OutgoingAttachment(kind: .file, data: Data([1, 2, 3]), mime: "application/pdf", filename: "x.pdf")])
        XCTAssertTrue(backend.sendCalls.isEmpty)
        XCTAssertEqual(store.pendingSends.first?.failure?.reason, .tooLarge)
        XCTAssertEqual(messages(store).last?.deliveryError, "The attachment is too large to send.")
    }

    func testEmptySendDoesNothingAndRepliesCarryTheParent() async throws {
        let (store, backend) = try await makeStore()
        await store.send(text: "   \n ")
        XCTAssertTrue(backend.sendCalls.isEmpty)
        let parent = try XCTUnwrap(messages(store).first)
        await store.send(text: "Agreed", replyTo: parent)
        XCTAssertEqual(backend.sendCalls.first?.replyTo, "m1")
        XCTAssertEqual(messages(store).last?.replyTo?.messageId, "m1")
        XCTAssertEqual(messages(store).last?.replyTo?.senderName, "Sam")
    }

    func testSendsRunInOrder() async throws {
        let (store, backend) = try await makeStore()
        backend.setSendDelay(.milliseconds(150))
        let a = Task { await store.send(text: "one") }
        await waitUntil { backend.sendCalls.count == 1 }
        // "two" is made while "one" is still in flight: it waits its turn.
        let b = Task { await store.send(text: "two") }
        await waitUntil { store.pendingSends.count == 2 }
        XCTAssertEqual(backend.sendCalls.map(\.text), ["one"])
        await a.value
        await b.value
        XCTAssertEqual(backend.sendCalls.map(\.text), ["one", "two"])
        XCTAssertEqual(messages(store).suffix(2).map { $0.body?.plain }, ["one", "two"])
    }

    func testIMessageGetsCAFVoiceNotesAndNoReplies() async throws {
        XCTAssertEqual(VoiceNoteFormat.for(.imessage), .opusCAF)
        XCTAssertEqual(VoiceNoteFormat.for(.sms), .opusCAF)
        XCTAssertEqual(VoiceNoteFormat.opusCAF.mime, "audio/x-caf")
        XCTAssertEqual(VoiceNoteFormat.opusCAF.filename, "Audio Message.caf")
        XCTAssertTrue(VoiceNoteFormat.accepts(.imessage, mime: "audio/x-caf"))
        XCTAssertFalse(VoiceNoteFormat.accepts(.whatsapp, mime: "audio/x-caf"), "CAF never goes to a bridge")
        XCTAssertEqual(VoiceNoteFormat.for(.whatsapp), .oggOpus)
        XCTAssertEqual(VoiceNoteFormat.for(.telegram), .oggOpus)
        XCTAssertEqual(VoiceNoteFormat.aacM4A.mime, "audio/mp4")
        XCTAssertFalse(VoiceNoteFormat.accepts(.imessage, mime: "audio/ogg"))
        XCTAssertTrue(VoiceNoteFormat.accepts(.imessage, mime: "audio/mp4"))
        XCTAssertTrue(VoiceNoteFormat.accepts(.whatsapp, mime: "audio/ogg"))

        let (store, backend) = try await makeStore(canSend: true, network: "imessage")
        XCTAssertTrue(store.canSend)
        XCTAssertFalse(store.canReply, "BlueBubbles refuses replyTo (422): no reply offered")
        XCTAssertEqual(store.voiceNoteFormat, .opusCAF)
        let parent = try XCTUnwrap(messages(store).first)
        await store.send(text: "On my way", replyTo: parent)
        XCTAssertNil(backend.sendCalls.last?.replyTo, "sent as a plain message")
        XCTAssertNil(messages(store).last?.replyTo)

        let ogg = OutgoingAttachment(kind: .voice, data: Data([1]), mime: "audio/ogg", filename: "Audio Message.ogg", durationMs: 900)
        let m4a = OutgoingAttachment(kind: .voice, data: Data([2]), mime: "audio/mp4", filename: "Audio Message.m4a", durationMs: 900)
        let caf = OutgoingAttachment(kind: .voice, data: Data([3]), mime: "audio/x-caf", filename: "Audio Message.caf", durationMs: 900)
        await store.send(text: "", attachments: [ogg, m4a, caf])
        XCTAssertEqual(backend.sendCalls.compactMap(\.attachment?.mime), ["audio/mp4", "audio/x-caf"], "Ogg never goes to iMessage")

        let (wa, _) = try await makeStore(canSend: true, network: "whatsapp")
        XCTAssertTrue(wa.canReply)
        XCTAssertEqual(wa.voiceNoteFormat, .oggOpus)
    }

    func testJumboEmojiAndWaveform() {
        XCTAssertTrue(TimelineStore.isJumboEmoji("😂👍"))
        XCTAssertFalse(TimelineStore.isJumboEmoji("ok 👍"))
        XCTAssertFalse(TimelineStore.isJumboEmoji("1"))
        XCTAssertFalse(TimelineStore.isJumboEmoji("😂😂😂😂"))

        XCTAssertEqual(VoiceWaveform.samples(fromLinear: [0, 0.5, 1]), [0, 512, 1024])
        let long = VoiceWaveform.samples(fromLinear: (0..<1000).map { Double($0 % 10) / 9 })
        XCTAssertEqual(long.count, 200)
        XCTAssertTrue(long.allSatisfy { (0...1024).contains($0) })
        XCTAssertEqual(VoiceWaveform.samples(fromDecibels: [-160, -50, -25, 0, .nan, 5]), [0, 0, 512, 1024, 0, 1024])
        XCTAssertEqual(VoiceWaveform.samples(fromLinear: []), [])
    }
}
