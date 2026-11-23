import CommsClient
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

/// The window-level outbox: sends outlive a transcript, bytes and temp files are released.
@MainActor
final class OutboxTests: XCTestCase {
    private let base = PrismJSON.parseDate("2026-11-20T14:00:00Z")!

    private func makeBackend() throws -> FixtureBackend {
        let backend = try FixtureBackend()
        var thread = FixtureMessages.thread(id: "th_o", title: "Olu", network: "telegram")
        thread.channels[0].capabilities = CommsChannelCapabilities(reply: true, attachments: true, send: true)
        backend.upsertThread(thread)
        backend.setMessagePages([nil: FixtureMessages.page([
            FixtureMessages.message(id: "m1", threadID: "th_o", network: "telegram", sender: "Olu", at: base, text: "Hi"),
        ], before: nil, hasMore: false)], threadID: "th_o")
        backend.setSendEcho(.none)
        return backend
    }

    private func store(_ backend: FixtureBackend, _ outbox: Outbox) async -> TimelineStore {
        let s = TimelineStore(backend: backend, threadID: "th_o", outbox: outbox, now: { [base] in base.addingTimeInterval(60) })
        await s.loadLatest()
        return s
    }

    private func texts(_ s: TimelineStore) -> [String] {
        s.rows.compactMap { if case .message(let m, _, _, _) = $0 { m.body?.plain } else { nil } }
    }

    private func tempFile(_ bytes: Int = 4096) -> URL {
        let url = OutgoingFiles.newURL(extension: "pdf")
        try? Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func testSentMessageSurvivesLeavingTheConversationUntilTheEcho() async throws {
        let backend = try makeBackend()
        let outbox = Outbox(backend: backend, now: { [base] in base.addingTimeInterval(60) })
        var first: TimelineStore? = await store(backend, outbox)
        await first?.send(text: "Running 10 minutes late")
        XCTAssertEqual(first?.pendingSends.first?.eventID, "$fx_sent_1")
        first = nil // the owner switches to another conversation

        let again = await store(backend, outbox)
        XCTAssertEqual(texts(again), ["Hi", "Running 10 minutes late"], "still on screen: no reason to type it again")
        XCTAssertEqual(again.pendingSends.count, 1)

        var echo = FixtureMessages.message(id: "srv", threadID: "th_o", network: "telegram", outgoing: true, at: base.addingTimeInterval(61), text: "Running 10 minutes late")
        echo.source.eventId = "$fx_sent_1"
        again.apply(FixtureMessages.event(.messageCreated, echo))
        XCTAssertTrue(again.pendingSends.isEmpty)
        XCTAssertTrue(outbox.byThread.isEmpty)
        XCTAssertEqual(texts(again), ["Hi", "Running 10 minutes late"])
    }

    func testFailedMessageKeepsItsClientIDAcrossTranscripts() async throws {
        let backend = try makeBackend()
        let outbox = Outbox(backend: backend)
        backend.setSendHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .sendFailed, maybeSent: true, status: 502)) }
        var first: TimelineStore? = await store(backend, outbox)
        await first?.send(text: "Did it go?")
        first = nil
        let again = await store(backend, outbox)
        let failed = try XCTUnwrap(again.pendingSends.first)
        XCTAssertNotNil(failed.failure, "Not Delivered is still shown")
        backend.setSendHandler(nil)
        await again.retrySend(clientID: failed.clientID)
        XCTAssertEqual(backend.sendCalls.map(\.clientID), [failed.clientID, failed.clientID], "the safe Try Again")
    }

    func testFinalFailuresOfferNoTryAgainAndExpiredOnesSendAsNew() async throws {
        let backend = try makeBackend()
        let outbox = Outbox(backend: backend)
        let s = await store(backend, outbox)
        backend.setSendHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .encryptedRoom, status: 409)) }
        await s.send(text: "secret room")
        let encrypted = try XCTUnwrap(s.pendingSends.last)
        XCTAssertEqual(encrypted.failure?.isFinal, true)
        await s.retrySend(clientID: encrypted.clientID)
        XCTAssertEqual(backend.sendCalls.count, 1, "Try Again cannot work: not offered, not sent")

        backend.setSendHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .sendFailed, message: "This message can no longer be retried safely.", maybeSent: true, status: 502)) }
        await s.send(text: "late one")
        let expired = try XCTUnwrap(s.pendingSends.last)
        XCTAssertEqual(expired.failure?.retryWindowExpired, true)
        XCTAssertEqual(expired.failure?.isFinal, true)
        await s.retrySend(clientID: expired.clientID)
        XCTAssertEqual(backend.sendCalls.count, 2, "no Try Again with the old id")
        backend.setSendHandler(nil)
        await s.resendAsNew(clientID: expired.clientID)
        let last = try XCTUnwrap(backend.sendCalls.last)
        XCTAssertEqual(last.text, "late one")
        XCTAssertNotEqual(last.clientID, expired.clientID, "a NEW message")
        XCTAssertNil(s.pendingSends.first { $0.clientID == expired.clientID })
    }

    func testFileBackedUploadDeletesItsTempFileAndImageBytesBecomeAPreview() async throws {
        let backend = try makeBackend()
        let outbox = Outbox(backend: backend)
        let s = await store(backend, outbox)
        let file = tempFile()
        let doc = OutgoingAttachment(kind: .file, fileURL: file, mime: "application/pdf", filename: "Plan.pdf")
        XCTAssertEqual(doc.byteCount, 4096)
        let photo = OutgoingAttachment(kind: .image, data: FixtureMessages.placeholderPNG, mime: "image/png", filename: "a.png", pixelWidth: 4, pixelHeight: 3)
        await s.send(text: "", attachments: [doc, photo])
        XCTAssertEqual(backend.sendCalls.first?.attachment?.fileURL, file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "uploaded: temp file deleted")
        XCTAssertNil(LocalMedia.data(for: doc.localToken))
        XCTAssertEqual(LocalMedia.data(for: photo.localToken)?.prefix(2), Data([0xFF, 0xD8]), "a preview, not the full bytes")
        for p in s.pendingSends {
            if case .attachment(let a) = p.content { XCTAssertTrue(a.data.isEmpty); XCTAssertNil(a.fileURL) }
        }
    }

    func testDiscardAndOutboxTeardownReleaseEverything() async throws {
        let backend = try makeBackend()
        backend.setSendHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .rateLimited, status: 429)) }
        let fileA = tempFile(), fileB = tempFile()
        let a = OutgoingAttachment(kind: .file, fileURL: fileA, mime: "application/pdf", filename: "A.pdf")
        let b = OutgoingAttachment(kind: .image, data: FixtureMessages.placeholderPNG, fileURL: nil, mime: "image/png", filename: "b.png")
        let c = OutgoingAttachment(kind: .file, fileURL: fileB, mime: "application/pdf", filename: "C.pdf")
        var outbox: Outbox? = Outbox(backend: backend)
        do {
            let s = await store(backend, outbox!)
            await s.send(text: "", attachments: [a, b, c])
            XCTAssertEqual(s.pendingSends.compactMap(\.failure).count, 3, "kept for Try Again")
            XCTAssertNotNil(LocalMedia.data(for: b.localToken))
            s.discardSend(clientID: a.id.uuidString.lowercased())
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileA.path), "Delete removes the temp file")
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileB.path))
        }
        outbox = nil // sign-out / window closed
        XCTAssertNil(LocalMedia.data(for: b.localToken), "the outbox's bytes go with it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileB.path), "and its temp files")
    }

    func testCapsComeFromTheServerAndOversizeFailsWithoutUploading() async throws {
        let backend = try makeBackend()
        let outbox = Outbox(backend: backend)
        let s = await store(backend, outbox)
        XCTAssertEqual(s.maxAttachmentBytes, 25 * 1024 * 1024, "capabilities.send.maxAttachmentBytes")
        s.maxAttachmentBytes = 100
        await s.send(text: "", attachments: [OutgoingAttachment(kind: .file, fileURL: tempFile(4096), mime: "application/pdf", filename: "big.pdf")])
        XCTAssertTrue(backend.sendCalls.isEmpty)
        XCTAssertEqual(s.pendingSends.first?.failure?.reason, .tooLarge)
        XCTAssertEqual(s.pendingSends.first?.failure?.isFinal, true)
    }

    func testStaleSentEntriesAreDropped() async throws {
        let backend = try makeBackend()
        var clock = base
        let outbox = Outbox(backend: backend, now: { clock })
        let s = TimelineStore(backend: backend, threadID: "th_o", outbox: outbox, now: { clock })
        await s.loadLatest()
        await s.send(text: "sent, echo lost")
        XCTAssertEqual(s.pendingSends.count, 1)
        clock = base.addingTimeInterval(31 * 60)
        await s.refreshLatest()
        XCTAssertTrue(s.pendingSends.isEmpty, "the server has it; the transcript reload shows the real one")
    }

    func testSweepRemovesLeftoversOfEarlierRuns() throws {
        let old = OutgoingFiles.newURL(extension: "mov")
        try Data([1]).write(to: old)
        let voice = FileManager.default.temporaryDirectory.appendingPathComponent("comms-voice-\(UUID().uuidString).m4a")
        try Data([1]).write(to: voice)
        let unrelated = FileManager.default.temporaryDirectory.appendingPathComponent("not-ours-\(UUID().uuidString).txt")
        try Data([1]).write(to: unrelated)
        defer { try? FileManager.default.removeItem(at: unrelated) }
        OutgoingFiles.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: voice.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        OutgoingFiles.remove(unrelated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "never deletes a file that isn't ours")
    }
}
