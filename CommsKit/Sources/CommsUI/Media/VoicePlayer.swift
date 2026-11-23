import AVFoundation
import CommsClient
import CommsCore
import Foundation
import Observation
import PrismTransport

/// Plays voice and audio messages in place, as Messages does: tap the bubble's play button, the
/// waveform fills as it plays, the time counts down, tap again to pause. One message plays at a
/// time. Bytes come from the server's PLAYABLE rendition (`ChatBackend.playableAudio`): WhatsApp /
/// Telegram / Signal voice notes are Ogg/Opus, which AVFoundation cannot decode, so the server
/// transcodes them to AAC (owner-testing round 4: "I can't play voice messages anywhere").
///
/// Bubbles live in AppKit / UIKit cells that do not inherit the SwiftUI environment, so this is a
/// shared object; `.mediaViewer()` (on the transcript) hands it the signed-in backend's fetcher and
/// shows its error alert.
@MainActor @Observable
public final class VoicePlayer {
    public static let shared = VoicePlayer()

    /// The media token of the message playing (or paused, or loading).
    public private(set) var currentToken: String?
    public private(set) var isPlaying = false
    public private(set) var isLoading = false
    /// 0 … 1 through the current message.
    public private(set) var progress: Double = 0
    /// Seconds left in the current message (nil = unknown).
    public private(set) var remaining: TimeInterval?
    /// Why the last message could not be played (the transcript shows an alert); nil = fine.
    public var failure: String?

    /// Set by `.mediaViewer()`: the playable-audio fetch of the signed-in backend.
    @ObservationIgnored public var fetcher: MediaFetcher = .none
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var delegate: Delegate?

    init() {}

    public func isCurrent(_ a: CommsAttachment) -> Bool { a.mediaToken != nil && a.mediaToken == currentToken }

    /// Play, pause or resume this message.
    public func toggle(_ a: CommsAttachment) {
        guard let token = a.mediaToken else { return }
        if token == currentToken, let player {
            if player.isPlaying { pause() } else { resume() }
            return
        }
        if token == currentToken, isLoading { stop(); return }
        stop()
        currentToken = token
        isLoading = true
        remaining = a.durationMs.map { TimeInterval($0) / 1000 }
        let fetcher = self.fetcher
        loading = Task { [weak self] in
            do {
                let (data, type) = try await Self.fetchPlayable(token: token, fetcher: fetcher)
                guard let self, !Task.isCancelled, self.currentToken == token else { return }
                try self.start(data: data, contentType: type)
            } catch is CancellationError {
            } catch {
                guard let self, self.currentToken == token else { return }
                self.stop()
                self.failure = Self.message(for: error)
            }
        }
    }

    /// Stop whatever plays (a new message, the transcript closing, sign-out).
    public func stop() {
        loading?.cancel()
        loading = nil
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        delegate = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        fileURL = nil
        currentToken = nil
        isPlaying = false
        isLoading = false
        progress = 0
        remaining = nil
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
    }

    private func resume() {
        guard let player else { return }
        activateSession()
        player.play()
        isPlaying = true
        startTicker()
    }

    private func start(data: Data, contentType: String) throws {
        let ext = Self.fileExtension(for: data, contentType: contentType)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("comms-voice/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Audio Message.\(ext)")
        try data.write(to: url, options: .atomic)
        fileURL = url
        let p = try AVAudioPlayer(contentsOf: url)
        let d = Delegate { [weak self] in self?.finished() }
        p.delegate = d
        delegate = d
        guard p.prepareToPlay() else { throw Unplayable() }
        player = p
        isLoading = false
        remaining = p.duration
        activateSession()
        guard p.play() else { throw Unplayable() }
        isPlaying = true
        startTicker()
    }

    private func finished() {
        stop()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let p = self.player else { return }
                self.progress = p.duration > 0 ? min(1, p.currentTime / p.duration) : 0
                self.remaining = max(0, p.duration - p.currentTime)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func activateSession() {
        #if os(iOS)
        // Plays with the ring switch on silent, like Messages' audio messages.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    /// The playable bytes; an expired token (a transcript left open for hours) is exchanged once.
    static func fetchPlayable(token: String, fetcher: MediaFetcher) async throws -> (Data, String) {
        do {
            return try await fetcher.playableAudio(token)
        } catch CommsError.mediaExpired {
            guard let fresh = try await fetcher.refresh([token])[token] else { throw CommsError.mediaExpired }
            return try await fetcher.playableAudio(fresh)
        }
    }

    /// The file extension AVAudioPlayer needs to pick the right parser: the bytes first, then the type.
    public static func fileExtension(for data: Data, contentType: String) -> String {
        let h = [UInt8](data.prefix(12))
        func at(_ o: Int, _ s: String) -> Bool { h.count >= o + s.utf8.count && Array(h[o..<(o + s.utf8.count)]) == Array(s.utf8) }
        if at(4, "ftyp") { return "m4a" }
        if at(0, "caff") { return "caf" }
        if at(0, "RIFF") { return "wav" }
        if at(0, "FORM") { return "aiff" }
        if at(0, "fLaC") { return "flac" }
        if at(0, "ID3") || (h.count >= 2 && h[0] == 0xFF && h[1] & 0xE0 == 0xE0) { return "mp3" }
        switch contentType.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) ?? "" {
        case "audio/mp4", "audio/x-m4a", "audio/aac": return "m4a"
        case "audio/mpeg": return "mp3"
        case "audio/x-caf": return "caf"
        case "audio/wav", "audio/x-wav": return "wav"
        default: return "m4a"
        }
    }

    /// What the alert says. Never silent (owner report: "I can't play voice messages anywhere").
    public static func message(for error: any Error) -> String {
        if let c = error as? CommsError, case .mediaExpired = c { return "This audio message is no longer available." }
        if let e = error as? PrismError {
            switch e {
            case .unreachable, .outcomeUnknown: return "Couldn't load this audio message. Check your connection and try again."
            case .notSignedIn, .signedOut, .unauthorized: return "Sign in again to play this audio message."
            default:
                switch e.httpStatus {
                case 404, 410: return "This audio message is no longer available."
                case 413: return "This audio message is too long to play here."
                case 503 where e.serverCode == "transcode_unavailable": return "Your Prism server can't convert this audio message yet (ffmpeg isn't installed)."
                case 415, 422: return "This audio message can't be played."
                default: break
                }
            }
        }
        if error is URLError { return "Couldn't load this audio message. Check your connection and try again." }
        if error is Unplayable { return "This audio message can't be played." }
        return "This audio message can't be played."
    }

    struct Unplayable: Error {}

    private final class Delegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        let done: @MainActor () -> Void
        init(done: @escaping @MainActor () -> Void) { self.done = done }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor in done() }
        }
        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
            Task { @MainActor in
                done()
                VoicePlayer.shared.failure = "This audio message can't be played."
            }
        }
    }
}
