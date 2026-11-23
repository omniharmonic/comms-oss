import CommsClient
import CommsCore
import Foundation
import PrismModels
import PrismTransport
@testable import CommsUI
import XCTest

/// Owner-testing round 4: voice messages play in place, through the server's playable rendition,
/// and say why when they cannot.
@MainActor
final class VoicePlayerTests: XCTestCase {
    /// A real, tiny WAV (16-bit mono, 8 kHz, 0.5 s of a tone) — playable by AVAudioPlayer.
    nonisolated static func wav(seconds: Double = 0.5) -> Data {
        let rate = 8_000, n = Int(Double(rate) * seconds)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        for i in 0..<n { u16(UInt16(bitPattern: Int16(sin(Double(i) * 0.3) * 8_000))) }
        return d
    }

    private func attachment(_ token: String) throws -> CommsAttachment {
        let json = #"{"kind":"voice","mediaToken":"\#(token)","durationMs":500}"#
        return try PrismJSON.decoder().decode(CommsAttachment.self, from: Data(json.utf8))
    }

    private func settle(_ p: VoicePlayer) async {
        for _ in 0..<200 where p.isLoading { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testTapPlaysThePlayableRenditionPausesAndResumes() async throws {
        let asked = LockedList()
        let p = VoicePlayer()
        p.fetcher = MediaFetcher(fetch: { _ in XCTFail("the ORIGINAL bytes are never played"); return (Data(), "audio/ogg") },
                                 playableAudio: { token in asked.append(token); return (Self.wav(), "audio/wav") })
        let a = try attachment("tok_voice")
        p.toggle(a)
        XCTAssertTrue(p.isCurrent(a))
        await settle(p)
        XCTAssertEqual(asked.items, ["tok_voice"])
        XCTAssertNil(p.failure)
        XCTAssertTrue(p.isPlaying)
        XCTAssertEqual(p.remaining ?? 0, 0.5, accuracy: 0.1)
        p.toggle(a)
        XCTAssertFalse(p.isPlaying, "tap again pauses")
        XCTAssertTrue(p.isCurrent(a))
        p.toggle(a)
        XCTAssertTrue(p.isPlaying, "and resumes")
        // Another message stops the first.
        let b = try attachment("tok_other")
        p.toggle(b)
        XCTAssertFalse(p.isCurrent(a))
        p.stop()
        XCTAssertNil(p.currentToken)
    }

    func testAFailureAlwaysSaysWhy() async throws {
        let p = VoicePlayer()
        let refused = PrismError.rejected(ServerFailure(status: 503, code: "transcode_unavailable", detail: nil, body: Data()))
        p.fetcher = MediaFetcher(fetch: { _ in (Data(), "") }, playableAudio: { _ in throw refused })
        p.toggle(try attachment("tok_a"))
        await settle(p)
        XCTAssertEqual(p.failure, "Your Prism server can't convert this audio message yet (ffmpeg isn't installed).")
        XCTAssertNil(p.currentToken)
        XCTAssertFalse(p.isPlaying)

        // Bytes AVFoundation cannot read (an Ogg that slipped through) → "can't be played", never silence.
        p.failure = nil
        p.fetcher = MediaFetcher(fetch: { _ in (Data(), "") }, playableAudio: { _ in (Data("OggS\0\u{2}garbage".utf8), "audio/ogg") })
        p.toggle(try attachment("tok_b"))
        await settle(p)
        XCTAssertEqual(p.failure, "This audio message can't be played.")
        XCTAssertEqual(VoicePlayer.message(for: PrismError.rejected(ServerFailure(status: 422, code: "transcode_failed", detail: nil, body: Data()))), "This audio message can't be played.")
        XCTAssertEqual(VoicePlayer.message(for: CommsError.mediaExpired), "This audio message is no longer available.")
        XCTAssertEqual(VoicePlayer.message(for: URLError(.notConnectedToInternet)), "Couldn't load this audio message. Check your connection and try again.")
    }

    func testAnExpiredTokenIsRefreshedOnce() async throws {
        let p = VoicePlayer()
        let asked = LockedList()
        p.fetcher = MediaFetcher(fetch: { _ in (Data(), "") }, refresh: { _ in ["tok_old": "tok_new"] },
                                 playableAudio: { t in
                                     asked.append(t)
                                     if t == "tok_old" { throw CommsError.mediaExpired }
                                     return (Self.wav(), "audio/wav")
                                 })
        p.toggle(try attachment("tok_old"))
        await settle(p)
        XCTAssertEqual(asked.items, ["tok_old", "tok_new"])
        XCTAssertNil(p.failure)
        p.stop()
    }

    func testFileExtensionFollowsTheBytes() {
        XCTAssertEqual(VoicePlayer.fileExtension(for: Data([0, 0, 0, 0x20] + Array("ftypM4A ".utf8)), contentType: "application/octet-stream"), "m4a")
        XCTAssertEqual(VoicePlayer.fileExtension(for: Data("caff".utf8), contentType: ""), "caf")
        XCTAssertEqual(VoicePlayer.fileExtension(for: Self.wav(), contentType: "audio/mp4"), "wav")
        XCTAssertEqual(VoicePlayer.fileExtension(for: Data("ID3".utf8), contentType: ""), "mp3")
        XCTAssertEqual(VoicePlayer.fileExtension(for: Data([1, 2]), contentType: "audio/mpeg"), "mp3")
    }

    func testVoiceOverOffersPlayForAudioMessages() throws {
        let json = #"{"id":"m1","threadId":"t","channel":{"network":"whatsapp","accountLabel":null},"source":{"network":"whatsapp","eventId":"m1","ref":"m1"},"sender":{"id":"s","name":"Sam","avatar":null,"isSelf":false,"isOmni":false},"sentAt":"2026-11-22T10:00:00.000Z","body":null,"attachments":[{"kind":"voice","mediaToken":"tok","durationMs":3000}],"linkPreviews":[],"reactions":[],"delivery":null,"redacted":false}"#
        let m = try PrismJSON.decoder().decode(CommsMessage.self, from: Data(json.utf8))
        XCTAssertEqual(MessageBubble.accessibilityActions(for: m).map(\.name), ["Play audio message"])
    }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String] = []
    func append(_ s: String) { lock.lock(); _items.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return _items }
}
