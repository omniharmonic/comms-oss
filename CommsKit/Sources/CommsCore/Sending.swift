import CommsClient
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// One file the owner picked (photo, video, file) or recorded (voice note), waiting in the
/// composer or being sent. Its `id` is the send's `clientId` (one per attachment), kept for
/// a Try Again so the server can recognise a resend.
///
/// Small items (pictures after location stripping, voice notes) carry their bytes in `data`;
/// large ones (videos, files) live in a temporary file (`fileURL`, under ``OutgoingFiles``)
/// and are streamed to the server, never loaded whole into memory.
public struct OutgoingAttachment: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var kind: CommsOutgoingKind
    public var data: Data
    /// A temporary file this app owns (deleted once the upload is done or the item dropped).
    public var fileURL: URL?
    /// The upload's size in bytes (the file's, or `data`'s).
    public var byteCount: Int
    public var mime: String
    public var filename: String
    /// Voice / video length.
    public var durationMs: Int?
    /// Voice only: ≤ 200 samples, 0…1024.
    public var waveform: [Int]?
    /// Pixel size of a picture or video frame, when known (bubble aspect ratio).
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(id: UUID = UUID(), kind: CommsOutgoingKind, data: Data = Data(), fileURL: URL? = nil, mime: String, filename: String, durationMs: Int? = nil, waveform: [Int]? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.id = id
        self.kind = kind
        self.data = data
        self.fileURL = fileURL
        self.byteCount = fileURL.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int } ?? data.count
        self.mime = mime
        self.filename = filename
        self.durationMs = durationMs
        self.waveform = waveform
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// The token its local bytes are registered under (``LocalMedia``) while it is pending.
    public var localToken: String { LocalMedia.token(for: id) }

    /// The attachment kind a bubble draws for it.
    public var attachmentKind: CommsAttachmentKind {
        switch kind {
        case .image: .image
        case .video: .video
        case .voice: .voice
        case .file: .file
        }
    }

    /// The same attachment without its bytes (after upload: the bubble needs only the facts).
    public var withoutBytes: OutgoingAttachment {
        var a = self
        a.data = Data()
        a.fileURL = nil
        return a
    }

    /// Delete its temporary file, if any.
    public func deleteFile() {
        if let fileURL { OutgoingFiles.remove(fileURL) }
    }
}

/// Temporary files of outgoing attachments (videos and files copied out of Photos / Files,
/// location-stripped exports, the recorder's audio). Each is deleted when its upload is done
/// or the item is dropped; what a previous run left behind is swept once per launch.
public enum OutgoingFiles {
    public static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("comms-outgoing", isDirectory: true)
    }

    /// A fresh file URL in the directory (the directory is created).
    public static func newURL(extension ext: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clean = ext.isEmpty ? "bin" : ext
        return directory.appendingPathComponent("\(UUID().uuidString).\(clean)")
    }

    /// Remove `url` only if it is one of ours (never a file the owner picked in place).
    public static func remove(_ url: URL) {
        guard isOurs(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func isOurs(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let dir = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(dir + "/") || (path.hasPrefix(tmp + "/") && url.lastPathComponent.hasPrefix("comms-voice-"))
    }

    private static let swept = OSAllocatedUnfairLock(initialState: false)

    /// Once per process (before anything is picked): delete leftovers of earlier runs — the
    /// outgoing directory and recorder files (`comms-voice-*`). Pending sends do not survive
    /// a relaunch, so nothing there is still needed.
    public static func sweepOnce() {
        let first = swept.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return }
        sweep()
    }

    static func sweep() {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        let tmp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("comms-voice-") {
            try? fm.removeItem(at: tmp.appendingPathComponent(name))
        }
    }
}

/// The container a voice note is sent in, by network: Ogg/Opus for the Matrix-bridged
/// networks (WhatsApp and Telegram play it as a native voice note), AAC in MPEG-4 (.m4a) for
/// iMessage / SMS through BlueBubbles (the server refuses Ogg there with 415: iPhones don't
/// play it in Messages).
public enum VoiceNoteFormat: Sendable, Equatable {
    /// Ogg/Opus: what the mautrix bridges pass through as native WhatsApp / Telegram voice notes.
    case oggOpus
    /// Opus in CAF (`CafOpus`): what Messages sends an audio message as. iMessage / SMS, where
    /// BlueBubbles sends it with `isAudioMessage` — a real voice bubble for the recipient.
    case opusCAF
    /// The recorder's AAC .m4a, sent as it is when an encode fails (an ordinary audio file).
    case aacM4A

    public static func `for`(_ network: CommsNetwork?) -> VoiceNoteFormat {
        switch network {
        case .imessage?, .sms?: .opusCAF
        default: .oggOpus
        }
    }

    public var mime: String {
        switch self {
        case .oggOpus: "audio/ogg"
        case .opusCAF: CafOpus.mime
        case .aacM4A: "audio/mp4"
        }
    }

    public var filename: String {
        switch self {
        case .oggOpus: "Audio Message.ogg"
        case .opusCAF: CafOpus.filename
        case .aacM4A: "Audio Message.m4a"
        }
    }

    /// Whether a voice attachment of `mime` may go to `network`: Ogg never to iMessage/SMS
    /// (BlueBubbles refuses it), CAF only there (the bridges' recipients can't play it).
    public static func accepts(_ network: CommsNetwork?, mime: String) -> Bool {
        let m = mime.lowercased()
        switch Self.for(network) {
        case .opusCAF: return !m.hasPrefix("audio/ogg")
        default: return !m.hasPrefix("audio/x-caf")
        }
    }
}

extension CommsNetwork {
    /// Replies (`replyTo`) can be sent on this network: not on iMessage / SMS (BlueBubbles
    /// refuses them with 422).
    public var supportsSentReplies: Bool { self != .imessage && self != .sms }
}

/// Bytes of attachments that exist only on this device (picked or recorded, not yet echoed
/// by the server), by a `local-<uuid>` token. The media loader answers these tokens from
/// here and never asks the server for them.
public enum LocalMedia {
    private static let store = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])
    static let prefix = "local-"

    public static func token(for id: UUID) -> String { prefix + id.uuidString.lowercased() }
    public static func isLocal(_ token: String) -> Bool { token.hasPrefix(prefix) }

    public static func register(_ data: Data, for id: UUID) { store.withLock { $0[token(for: id)] = data } }
    public static func data(for token: String) -> Data? { store.withLock { $0[token] } }
    public static func remove(_ id: UUID) { store.withLock { _ = $0.removeValue(forKey: token(for: id)) } }

    /// Replace a picture's full bytes with a small JPEG preview (≤ `maxPixel`), enough for the
    /// pending bubble once the upload is done. Anything that is not a picture is just removed.
    public static func keepPreview(for id: UUID, maxPixel: Int = 640) {
        let t = token(for: id)
        guard let full = store.withLock({ $0[t] }) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        let out = NSMutableData()
        guard let src = CGImageSourceCreateWithData(full as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary),
              let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            remove(id)
            return
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return remove(id) }
        let preview = Data(out as Data)
        store.withLock { $0[t] = preview }
    }

    /// How many entries are registered (tests: nothing leaks).
    static var count: Int { store.withLock { $0.count } }
}

extension CommsSendFailure {
    /// Trying again with the same clientId cannot succeed (the server would refuse it the
    /// same way, or says the safe-retry window is over): the bubble offers no Try Again.
    public var isFinal: Bool {
        switch reason {
        case .encryptedRoom, .unsupportedNetwork, .unsupportedType, .tooLarge, .bridgeCommand, .sendDisabled, .invalid, .notFound, .alreadyReacted: return true
        // Email: the recipients changed; the same clientId would echo the old header (the store refetches it).
        case .other("target_changed"): return true
        default: return retryWindowExpired
        }
    }

    /// 502 maybeSent past the server's safe-retry window ("can no longer be retried safely"):
    /// the owner checks the conversation and may send it again as a NEW message.
    public var retryWindowExpired: Bool {
        reason == .sendFailed && maybeSent && (message?.localizedCaseInsensitiveContains("no longer be retried") ?? false)
    }

    /// What the "Not Delivered" detail says (Messages keeps it short).
    public var displayText: String {
        switch reason {
        case .sendDisabled: return "Sending is turned off on the server."
        case .deviceRequired: return "Sign in on this device to send."
        case .notFound: return "This conversation is no longer available."
        case .unsupportedNetwork: return "Sending isn't available on this network yet."
        case .tooLarge: return message ?? "The attachment is too large to send."
        case .unsupportedType: return message ?? "This kind of file can't be sent here."
        case .invalid: return message ?? "The message couldn't be sent."
        case .rateLimited: return "Too many messages. Try again in a moment."
        case .inProgress: return "Still sending. Try again in a moment."
        case .encryptedRoom: return "This conversation is end-to-end encrypted; Comms can't send to it."
        case .bridgeCommand: return message ?? "Messages starting with ! are bridge commands and are not sent."
        case .topicRequired: return message ?? "Choose a topic to send to."
        case .topicMismatch: return message ?? "That message is in another topic. Nothing was sent."
        case .alreadyReacted: return message ?? "You already reacted with that."
        case .busy: return "Other attachments are still uploading. Try again in a moment."
        case .alreadyReacted: return "You already reacted with this."
        case .sourceUnavailable: return "The server can't reach the chat network right now."
        case .sendFailed:
            // The server's sentence matters here (e.g. a Try Again past its safe window).
            if let message, !message.isEmpty { return message }
            return maybeSent ? "This message may have been sent. Check before trying again." : "The network couldn't deliver it."
        case .outcomeUnknown:
            return maybeSent ? "This message may have been sent. Check before trying again." : "The network couldn't deliver it."
        case .unreachable: return "Can't reach the server."
        case .other: return message ?? "The message couldn't be sent."
        }
    }
}

/// Voice-note waveforms: what the server and the bridges accept (≤ 200 samples, 0…1024).
public enum VoiceWaveform {
    public static let maxSamples = 200
    public static let maxValue = 1024

    /// Average-power readings (dBFS, -160…0) taken while recording → ≤ `maxSamples` values
    /// in 0…1024 (bucket maxima, so short peaks survive; -50 dB and quieter read as silence).
    public static func samples(fromDecibels levels: [Float], count: Int = maxSamples) -> [Int] {
        let linear = levels.map { db -> Double in
            guard db.isFinite else { return 0 }
            let floor: Float = -50
            return Double(max(0, min(1, (max(db, floor) - floor) / -floor)))
        }
        return samples(fromLinear: linear, count: count)
    }

    /// Linear levels (0…1) → ≤ `count` values in 0…1024.
    public static func samples(fromLinear levels: [Double], count: Int = maxSamples) -> [Int] {
        guard !levels.isEmpty, count > 0 else { return [] }
        let n = min(count, levels.count)
        var out: [Int] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let lo = i * levels.count / n
            let hi = max(lo + 1, (i + 1) * levels.count / n)
            let peak = levels[lo..<hi].max() ?? 0
            out.append(Int((max(0, min(1, peak)) * Double(maxValue)).rounded()))
        }
        return out
    }
}
