import CommsClient
import CommsTestSupport
import Foundation
import os
@testable import CommsCore
import XCTest

/// Phase 2b C1: a sent message is ONE bubble at every frame, whatever order the HTTP answer
/// and the server's echo arrive in, with or without the echo carrying the clientId — and the
/// row keeps one identity (`diffID`) from the pending bubble to the echo, so the transcripts
/// update it in place (no insert + delete pair that could draw two bubbles).
@MainActor
final class SendEchoTests: XCTestCase {
    private let base = PrismJSON.parseDate("2026-11-20T14:00:00Z")!
    /// The store's clock (moved by the tests).
    private var clock: Date!

    override func setUp() async throws {
        clock = base.addingTimeInterval(120)
    }

    private func makeStore(network: String = "whatsapp", history: [CommsMessage] = []) async throws -> (TimelineStore, FixtureBackend, Recorder) {
        let backend = try FixtureBackend()
        var thread = FixtureMessages.thread(id: "th_e", title: "Sam", network: network)
        thread.channels[0].capabilities = CommsChannelCapabilities(reply: true, attachments: true, send: true)
        backend.upsertThread(thread)
        backend.setMessagePages([nil: FixtureMessages.page([
            FixtureMessages.message(id: "m1", threadID: "th_e", network: network, sender: "Sam", at: base, text: "Hi"),
        ] + history, before: nil, hasMore: false)], threadID: "th_e")
        backend.setSendEcho(.none)
        let store = TimelineStore(backend: backend, threadID: "th_e", now: { [unowned self] in self.clock })
        await store.loadLatest()
        let recorder = Recorder()
        store.rowsObserver = { recorder.frames.append($0) }
        return (store, backend, recorder)
    }

    final class Recorder {
        var frames: [[TranscriptRow]] = []
    }

    private func echo(_ eventID: String, text: String? = nil, clientID: String? = nil, id: String = "srv_1",
                      at offset: TimeInterval = 121, attachments: [[String: Any]] = []) -> CommsEvent {
        var m = FixtureMessages.message(id: id, threadID: "th_e", outgoing: true, at: base.addingTimeInterval(offset),
                                        text: text, attachments: attachments, delivery: "sent")
        if text == nil { m.body = nil }
        m.source.eventId = eventID
        m.clientId = clientID
        return FixtureMessages.event(.messageCreated, m)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 2) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private static func messages(_ rows: [TranscriptRow]) -> [(row: TranscriptRow, message: CommsMessage)] {
        rows.compactMap { if case .message(let m, _, _, _) = $0 { ($0, m) } else { nil } }
    }

    /// Every recorded frame (after the bubble first appeared) shows exactly one copy of the
    /// sent message, and its row identity never changes. Returns that identity.
    @discardableResult
    private func assertOneBubbleEveryFrame(_ recorder: Recorder, matching: (CommsMessage) -> Bool,
                                           file: StaticString = #filePath, line: UInt = #line) -> String? {
        var identity: String?
        var seen = false
        for (n, frame) in recorder.frames.enumerated() {
            let ids = frame.map(\.diffID)
            XCTAssertEqual(Set(ids).count, ids.count, "frame \(n): row identities are unique", file: file, line: line)
            let copies = Self.messages(frame).filter { matching($0.message) }
            if copies.isEmpty {
                XCTAssertFalse(seen, "frame \(n): the bubble never disappears once shown", file: file, line: line)
                continue
            }
            seen = true
            XCTAssertEqual(copies.count, 1, "frame \(n): exactly one bubble, never two", file: file, line: line)
            let id = copies[0].row.diffID
            if let identity { XCTAssertEqual(id, identity, "frame \(n): one row identity from pending to echo", file: file, line: line) }
            identity = id
        }
        XCTAssertTrue(seen, "the bubble was shown", file: file, line: line)
        return identity
    }

    private func isText(_ text: String) -> (CommsMessage) -> Bool { { $0.body?.plain == text } }

    // MARK: Orderings (text)

    func test200ThenEchoWithClientID() async throws {
        let (store, backend, rec) = try await makeStore()
        await store.send(text: "One")
        let cid = try XCTUnwrap(backend.sendCalls.first?.clientID)
        store.apply(echo("$fx_sent_1", text: "One", clientID: cid))
        XCTAssertTrue(store.pendingSends.isEmpty)
        let identity = assertOneBubbleEveryFrame(rec, matching: isText("One"))
        XCTAssertEqual(identity, PendingSend.messageID(for: cid))
        XCTAssertEqual(Self.messages(store.rows).last?.message.id, "srv_1", "the server's message, with its own id")
    }

    func test200ThenEchoWithoutClientID() async throws {
        let (store, backend, rec) = try await makeStore()
        await store.send(text: "Two")
        let cid = try XCTUnwrap(backend.sendCalls.first?.clientID)
        store.apply(echo("$fx_sent_1", text: "Two"))
        XCTAssertTrue(store.pendingSends.isEmpty)
        XCTAssertEqual(assertOneBubbleEveryFrame(rec, matching: isText("Two")), PendingSend.messageID(for: cid))
    }

    func testEchoWithClientIDThen200() async throws {
        let (store, backend, rec) = try await makeStore()
        backend.setSendDelay(.milliseconds(150))
        let task = Task { await store.send(text: "Three") }
        await waitUntil { !backend.sendCalls.isEmpty }
        store.apply(echo("$fx_sent_1", text: "Three", clientID: backend.sendCalls[0].clientID.uppercased()))
        XCTAssertTrue(store.pendingSends.isEmpty)
        await task.value
        assertOneBubbleEveryFrame(rec, matching: isText("Three"))
        XCTAssertEqual(Self.messages(store.rows).map(\.message.id), ["m1", "srv_1"])
    }

    /// The owner's case: a sync / BlueBubbles webhook beats the server's ledger, so the echo
    /// carries no clientId and the send's event id is not known yet.
    func testEchoWithoutClientIDThen200() async throws {
        let (store, backend, rec) = try await makeStore()
        backend.setSendDelay(.milliseconds(150))
        let task = Task { await store.send(text: "Four") }
        await waitUntil { !backend.sendCalls.isEmpty }
        store.apply(echo("$fx_sent_1", text: "Four"))
        XCTAssertEqual(Self.messages(store.rows).filter { $0.message.body?.plain == "Four" }.count, 1,
                       "the echo stands in for the in-flight bubble at once")
        await task.value
        XCTAssertTrue(store.pendingSends.isEmpty, "the answer's event id confirms the echo")
        let cid = backend.sendCalls[0].clientID
        XCTAssertEqual(assertOneBubbleEveryFrame(rec, matching: isText("Four")), PendingSend.messageID(for: cid))
        XCTAssertEqual(Self.messages(store.rows).last?.message.delivery, .sent)
    }

    func testFixtureEchoWithoutClientIDBeforeTheAnswer() async throws {
        let (store, backend, rec) = try await makeStore()
        backend.setSendEchoCarriesClientID(false)
        backend.setSendEcho(.immediate)
        let feed = Task { @MainActor in
            do { for try await e in backend.events(lastEventID: nil) { store.apply(e) } } catch {}
        }
        defer { feed.cancel() }
        await store.send(text: "Five")
        await waitUntil { store.pendingSends.isEmpty }
        XCTAssertTrue(store.pendingSends.isEmpty)
        assertOneBubbleEveryFrame(rec, matching: isText("Five"))
    }

    // MARK: Voice (the owner saw it most there)

    func testVoiceEchoWithoutClientIDBeforeTheAnswer() async throws {
        let (store, backend, rec) = try await makeStore(network: "imessage")
        backend.setSendDelay(.milliseconds(150))
        backend.setSendHandler { c in CommsSendResult(clientId: c.clientID, eventId: "$bb_guid") }
        let voice = OutgoingAttachment(kind: .voice, data: Data(repeating: 1, count: 64), mime: "audio/mp4", filename: "Audio Message.m4a", durationMs: 2300, waveform: [10, 200, 30])
        let task = Task { await store.send(text: "", attachments: [voice]) }
        await waitUntil { !backend.sendCalls.isEmpty }
        let isVoice: (CommsMessage) -> Bool = { $0.attachments.first.map { $0.kind == .voice || $0.kind == .audio } ?? false }
        // BlueBubbles may project it as plain audio.
        store.apply(echo("$bb_guid", attachments: [["kind": "audio", "mime": "audio/mp4", "mediaToken": "tok_v", "durationMs": 2300]]))
        XCTAssertEqual(Self.messages(store.rows).filter { isVoice($0.message) }.count, 1)
        await task.value
        XCTAssertTrue(store.pendingSends.isEmpty)
        XCTAssertEqual(assertOneBubbleEveryFrame(rec, matching: isVoice), PendingSend.messageID(for: voice.id.uuidString.lowercased()))
    }

    func testVoice200ThenEchoKeepsTheRowIdentity() async throws {
        let (store, backend, rec) = try await makeStore()
        let voice = OutgoingAttachment(kind: .voice, data: Data(repeating: 1, count: 64), mime: "audio/ogg", filename: "Audio Message.ogg", durationMs: 1200)
        await store.send(text: "", attachments: [voice])
        store.apply(echo("$fx_sent_1", attachments: [["kind": "voice", "mime": "audio/ogg", "mediaToken": "tok_v", "durationMs": 1200]]))
        let isVoice: (CommsMessage) -> Bool = { $0.attachments.first?.kind == .voice }
        XCTAssertNotNil(assertOneBubbleEveryFrame(rec, matching: isVoice))
        XCTAssertNil(backend.sendCalls.first?.text)
    }

    // MARK: Guards

    /// An identical message already in the conversation (sent from the phone a moment ago) is
    /// not taken for this send's echo.
    func testOlderIdenticalMessageIsNotMistakenForTheEcho() async throws {
        var earlier = FixtureMessages.message(id: "old_ok", threadID: "th_e", outgoing: true, at: base.addingTimeInterval(110), text: "ok", delivery: "sent")
        earlier.source.eventId = "$old"
        let (store, backend, _) = try await makeStore(history: [earlier])
        backend.setSendDelay(.milliseconds(100))
        clock = base.addingTimeInterval(130)
        let task = Task { await store.send(text: "ok") }
        await waitUntil { !backend.sendCalls.isEmpty }
        XCTAssertEqual(Self.messages(store.rows).filter { $0.message.body?.plain == "ok" }.count, 2,
                       "the earlier ok and the new pending one")
        await task.value
        XCTAssertEqual(store.pendingSends.count, 1, "still waiting for its own echo")
    }

    /// A content match the server then contradicts (the send was refused, nothing sent): the
    /// bubble comes back as Not Delivered; the other message stays, each with its own row.
    func testContentMatchUndoneWhenTheSendFails() async throws {
        let (store, backend, rec) = try await makeStore()
        backend.setSendDelay(.milliseconds(120))
        backend.setSendHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .sendFailed, maybeSent: false, status: 502)) }
        let task = Task { await store.send(text: "Six") }
        await waitUntil { !backend.sendCalls.isEmpty }
        store.apply(echo("$phone", text: "Six", id: "srv_phone"))
        await task.value
        let sixes = Self.messages(store.rows).filter { $0.message.body?.plain == "Six" }
        XCTAssertEqual(sixes.count, 2)
        XCTAssertEqual(Set(sixes.map(\.message.delivery)), [.failed, .sent], "Not Delivered next to the phone's message")
        for frame in rec.frames {
            XCTAssertEqual(Set(frame.map(\.diffID)).count, frame.count, "row identities stay unique")
        }
    }

    /// "Not Delivered — may have been sent", then the echo shows it was: one bubble, delivered.
    func testMaybeSentFailureThenEchoIsDelivered() async throws {
        let (store, backend, rec) = try await makeStore()
        backend.setSendHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .outcomeUnknown, maybeSent: true)) }
        await store.send(text: "Seven")
        XCTAssertEqual(Self.messages(store.rows).last?.message.delivery, .failed)
        store.apply(echo("$late", text: "Seven"))
        XCTAssertTrue(store.pendingSends.isEmpty)
        assertOneBubbleEveryFrame(rec, matching: isText("Seven"))
        XCTAssertEqual(Self.messages(store.rows).last?.message.delivery, .sent)
    }

    /// Review I2: once the 200 named the event, only that event (or the clientId) is the
    /// echo. An identical message from another device meanwhile is its own bubble, and the
    /// real echo then takes over the pending row in place — no identity jumps.
    func testAfterThe200OnlyTheEventIDMatches() async throws {
        let (store, backend, rec) = try await makeStore()
        await store.send(text: "ok")
        let cid = try XCTUnwrap(backend.sendCalls.first?.clientID)
        XCTAssertEqual(store.pendingSends.first?.eventID, "$fx_sent_1")
        clock = clock.addingTimeInterval(2)
        store.apply(echo("$phone", text: "ok", id: "srv_phone", at: 122))
        let oks = Self.messages(store.rows).filter { $0.message.body?.plain == "ok" }
        XCTAssertEqual(oks.count, 2, "the phone's ok is not taken for this send's echo")
        XCTAssertEqual(oks.first { $0.message.id == "srv_phone" }?.row.diffID, "srv_phone", "it keeps its own identity")
        store.apply(echo("$fx_sent_1", text: "ok", id: "srv_mine", at: 121))
        XCTAssertTrue(store.pendingSends.isEmpty)
        let final = Self.messages(store.rows).filter { $0.message.body?.plain == "ok" }
        XCTAssertEqual(final.map(\.message.id), ["srv_mine", "srv_phone"])
        XCTAssertEqual(final.first?.row.diffID, PendingSend.messageID(for: cid), "the real echo took over the pending row")
        // The phone's row never changed identity across the frames.
        for frame in rec.frames {
            if let row = Self.messages(frame).first(where: { $0.message.id == "srv_phone" }) { XCTAssertEqual(row.row.diffID, "srv_phone") }
        }
    }

    /// Two quick identical sends and their echoes: two bubbles, each matched once.
    func testTwoIdenticalSendsEachMatchOneEcho() async throws {
        let (store, backend, _) = try await makeStore()
        backend.setSendDelay(.milliseconds(80))
        let n = OSAllocatedUnfairLock(initialState: 0)
        backend.setSendHandler { c in
            let i = n.withLock { v -> Int in v += 1; return v }
            return CommsSendResult(clientId: c.clientID, eventId: "$e\(i)")
        }
        let first = Task { await store.send(text: "ha") }
        let second = Task { await store.send(text: "ha") }
        await waitUntil { store.pendingSends.count == 2 && !backend.sendCalls.isEmpty }
        clock = clock.addingTimeInterval(1) // the echoes arrive after both Sends
        store.apply(echo("$e1", text: "ha", id: "s1", at: 121))
        store.apply(echo("$e2", text: "ha", id: "s2", at: 122))
        XCTAssertEqual(Self.messages(store.rows).filter { $0.message.body?.plain == "ha" }.count, 2)
        await first.value
        await second.value
        let rows = Self.messages(store.rows).filter { $0.message.body?.plain == "ha" }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.row.diffID)).count, 2)
    }
}
