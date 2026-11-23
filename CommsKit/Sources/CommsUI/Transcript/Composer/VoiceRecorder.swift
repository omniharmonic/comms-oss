import AVFoundation
import CommsClient
import CommsCore
import Foundation
import Observation
import os
import SwiftUI

/// Records one audio message for the composer, as Messages does: a red recording state with
/// a live waveform and timer, then a recorded state to play back, delete or send.
///
/// Format (by the thread's network, `VoiceNoteFormat`): iMessage / SMS get Opus in CAF
/// (`CafOpus`, `audio/x-caf`, "Audio Message.caf"), which BlueBubbles sends as a real audio
/// message (`isAudioMessage`); BlueBubbles refuses Ogg. Everywhere else:
/// Ogg/Opus (`audio/ogg`), which mautrix-whatsapp and -telegram pass through as native
/// voice notes (and -signal converts to AAC). AVAudioRecorder records AAC `.m4a` (48 kHz mono)
/// and `OggOpus` re-encodes it when recording stops; if that fails the `.m4a` (`audio/mp4`,
/// which the server also accepts) is sent instead. The waveform is ≤ 200 samples in 0…1024
/// from the meter readings; `durationMs` is always set.
@MainActor @Observable
public final class VoiceRecorder {
    public enum Phase: Equatable {
        case idle
        case recording
        /// Stopped: `note` is ready to preview or send.
        case recorded
        /// Could not record (no permission, no input): the composer says why.
        case failed(String)
    }

    /// `.microphone` records for real; `.simulated` makes up levels and a short silent file
    /// (DEBUG demo / UI tests: no microphone prompt, nothing captured).
    public enum Source: Sendable { case microphone, simulated }

    public private(set) var phase: Phase = .idle
    /// Live levels (0…1), newest last, for the recording waveform.
    public private(set) var levels: [Double] = []
    public private(set) var elapsed: TimeInterval = 0
    /// The finished recording.
    public private(set) var note: OutgoingAttachment?
    public private(set) var isPlaying = false
    /// Recorded, and the Ogg/Opus encode is still running (Send waits for it).
    public private(set) var isEncoding = false
    /// 0…1 while encoding.
    public private(set) var encodeProgress: Double = 0

    /// Messages caps audio messages at a few minutes; so do we (then it stops by itself).
    public static let maxDuration: TimeInterval = 10 * 60
    static let meterInterval: Duration = .milliseconds(50)
    public static let mime = OggOpus.mime
    public static let filename = "Audio Message.ogg"
    static let fallbackMime = "audio/mp4"
    static let fallbackFilename = "Audio Message.m4a"

    @ObservationIgnored private let source: Source
    /// The container the finished note is sent in (by the thread's network).
    public let format: VoiceNoteFormat
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playerDelegate: PlayerDelegate?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var decibels: [Float] = []
    @ObservationIgnored private var fileURL: URL?
    /// `start()` is awaiting permission / setting up: a second tap must not start twice.
    @ObservationIgnored private var isStarting = false
    /// Bumped by every reset: a late encode result for an abandoned recording is dropped.
    @ObservationIgnored private var generation = 0
    /// Files and the audio session to clean up if the recorder goes away mid-way (deinit).
    @ObservationIgnored private nonisolated let leftovers = OSAllocatedUnfairLock(initialState: Leftovers())
    private struct Leftovers: Sendable {
        var files: Set<URL> = []
        var sessionActive = false
    }

    public init(source: Source = .microphone, format: VoiceNoteFormat = .oggOpus) {
        self.source = source
        self.format = format
    }

    /// The composer went away (another conversation, sign-out, quit) with a recording open:
    /// the raw audio never outlives it, and on iOS the record session is released.
    deinit {
        let left = leftovers.withLock { $0 }
        for url in left.files { try? FileManager.default.removeItem(at: url) }
        #if os(iOS)
        if left.sessionActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }

    /// The temporary recording, when one exists (tests).
    var temporaryFile: URL? { fileURL }

    /// A recorder frozen in a phase, for previews and snapshots (records nothing).
    public static func preview(phase: Phase, levels: [Double], elapsed: TimeInterval) -> VoiceRecorder {
        let r = VoiceRecorder(source: .simulated)
        r.phase = phase
        r.levels = levels
        r.elapsed = elapsed
        if phase == .recorded {
            r.note = OutgoingAttachment(kind: .voice, data: Data([0]), mime: mime, filename: filename,
                                        durationMs: Int(elapsed * 1000), waveform: VoiceWaveform.samples(fromLinear: levels))
        }
        return r
    }

    public var isActive: Bool { phase != .idle }

    // MARK: Recording

    public func start() async {
        guard !isStarting, phase == .idle || phase.isFailure else { return }
        isStarting = true
        defer { isStarting = false }
        reset()
        let gen = generation
        if source == .simulated { return begin(with: nil) }
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("Comms needs microphone access to record audio messages. Turn it on in Settings.")
            return
        }
        // Discarded (or the composer moved on) while the permission prompt was up.
        guard gen == generation, phase == .idle else { return }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            leftovers.withLock { $0.sessionActive = true }
            #endif
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("comms-voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            leftovers.withLock { _ = $0.files.insert(url) }
            fileURL = url
            guard r.record() else { throw CocoaError(.fileWriteUnknown) }
            begin(with: r)
        } catch {
            phase = .failed("Couldn't start recording.")
        }
    }

    private func begin(with r: AVAudioRecorder?) {
        recorder = r
        phase = .recording
        let started = Date()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.meterInterval)
                guard let self, self.phase == .recording else { return }
                let db: Float
                if let r = self.recorder {
                    r.updateMeters()
                    db = r.averagePower(forChannel: 0)
                } else {
                    // Simulated speech: a slow swell with syllable-like ripples.
                    let t = Date().timeIntervalSince(started)
                    db = Float(-40 + 30 * abs(sin(t * 2.3)) * (0.6 + 0.4 * abs(sin(t * 9.1))))
                }
                self.decibels.append(db)
                self.levels.append(VoiceRecorder.linear(db))
                if self.levels.count > 400 { self.levels.removeFirst(self.levels.count - 400) }
                self.elapsed = self.recorder?.currentTime ?? Date().timeIntervalSince(started)
                if self.elapsed >= Self.maxDuration { self.stop() }
            }
        }
    }

    /// Stop recording. The preview is ready at once; the Ogg/Opus encode runs off the main
    /// thread (`isEncoding`, `encodeProgress`) and `note` is set when it is done.
    public func stop() {
        guard phase == .recording else { return }
        meterTask?.cancel()
        meterTask = nil
        let duration = max(recorder?.currentTime ?? elapsed, elapsed)
        recorder?.stop()
        recorder = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        leftovers.withLock { $0.sessionActive = false }
        #endif
        let samples = VoiceWaveform.samples(fromDecibels: decibels)
        let durationMs = max(1, Int((duration * 1000).rounded()))
        levels = samples.map { Double($0) / Double(VoiceWaveform.maxValue) }
        elapsed = duration
        phase = .recorded
        if source == .simulated {
            note = OutgoingAttachment(kind: .voice, data: Data(count: 16), mime: format.mime, filename: format.filename, durationMs: durationMs, waveform: samples)
            return
        }
        guard let url = fileURL else { phase = .failed("The recording was empty."); return }
        isEncoding = true
        encodeProgress = 0
        let gen = generation
        let names = (ogg: (Self.mime, Self.filename), caf: (CafOpus.mime, CafOpus.filename), m4a: (Self.fallbackMime, Self.fallbackFilename))
        let format = format
        let (updates, sink) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let encode = Task.detached(priority: .userInitiated) { () -> (Data, String, String)? in
            defer { sink.finish() }
            // Ogg/Opus for the bridges' voice notes, Opus-in-CAF for iMessage / SMS (a real
            // audio message there); the recorded .m4a if encoding fails.
            switch format {
            case .oggOpus:
                if let ogg = try? OggOpus.encode(fileURL: url, progress: { sink.yield($0) }) { return (ogg, names.ogg.0, names.ogg.1) }
            case .opusCAF:
                if let caf = try? CafOpus.encode(fileURL: url, progress: { sink.yield($0) }) { return (caf, names.caf.0, names.caf.1) }
            case .aacM4A:
                break
            }
            guard let m4a = try? Data(contentsOf: url), !m4a.isEmpty else { return nil }
            return (m4a, names.m4a.0, names.m4a.1)
        }
        Task { [weak self] in
            for await p in updates {
                guard let self, self.generation == gen else { break }
                self.encodeProgress = p
            }
            let result = await encode.value
            guard let self, self.generation == gen else { return }
            self.isEncoding = false
            guard let (data, mime, name) = result else { self.phase = .failed("The recording was empty."); return }
            self.encodeProgress = 1
            self.note = OutgoingAttachment(kind: .voice, data: data, mime: mime, filename: name, durationMs: durationMs, waveform: samples)
        }
    }

    /// The recorded note, handing it over (the recorder returns to idle and its file is
    /// deleted). Nil while the encode is still running.
    public func take() -> OutgoingAttachment? {
        guard let n = note, !isEncoding else { return nil }
        reset()
        return n
    }

    /// The app is going to the background: stop a recording in progress (keeping it).
    public func suspend() { if phase == .recording { stop() } }

    /// Delete the recording (or abandon one in progress).
    public func discard() { reset() }

    // MARK: Playback

    public func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        // Play the recorded .m4a (AVAudioPlayer does not read Ogg/Opus).
        guard phase == .recorded, let fileURL, source == .microphone else { return }
        do {
            if player == nil {
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                try? AVAudioSession.sharedInstance().setActive(true)
                #endif
                let p = try AVAudioPlayer(contentsOf: fileURL)
                let delegate = PlayerDelegate { [weak self] in Task { @MainActor in self?.isPlaying = false } }
                p.delegate = delegate
                playerDelegate = delegate
                player = p
            }
            isPlaying = player?.play() ?? false
        } catch {
            isPlaying = false
        }
    }

    // MARK: Internals

    private func reset() {
        generation += 1
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        player?.stop()
        player = nil
        playerDelegate = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
            leftovers.withLock { _ = $0.files.remove(fileURL) }
        }
        #if os(iOS)
        if leftovers.withLock({ $0.sessionActive }) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            leftovers.withLock { $0.sessionActive = false }
        }
        #endif
        fileURL = nil
        isEncoding = false
        encodeProgress = 0
        decibels = []
        levels = []
        elapsed = 0
        note = nil
        isPlaying = false
        phase = .idle
    }

    /// dBFS → 0…1 for drawing (-50 dB and below is silence).
    static func linear(_ db: Float) -> Double {
        guard db.isFinite else { return 0 }
        return Double(max(0, min(1, (max(db, -50) + 50) / 50)))
    }

    /// "0:07", "1:23".
    public static func timeString(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

extension VoiceRecorder.Phase {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    let finished: @Sendable () -> Void
    init(finished: @escaping @Sendable () -> Void) { self.finished = finished }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { finished() }
}

/// DEBUG demo / UI tests: record with `VoiceRecorder.Source.simulated` (no microphone).
extension EnvironmentValues {
    @Entry public var simulatedVoiceRecorder: Bool = false
}
