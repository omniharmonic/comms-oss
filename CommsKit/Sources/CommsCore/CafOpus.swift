import AudioToolbox
import AVFoundation
import Foundation

/// iMessage / SMS voice notes as Opus in a CAF file — the format Messages itself sends an audio
/// message in ("Audio Message.caf", Opus, mono). Sent with `kind=voice`, the server forwards it to
/// BlueBubbles with `isAudioMessage`, which hands an Opus CAF to Messages unchanged, so the
/// recipient gets a real voice bubble (an .m4a arrives as an ordinary audio file).
///
/// The recorder's AAC .m4a is read in chunks (`OggOpus.PCMSource`), AVAudioConverter makes the
/// Opus packets (24 kHz mono, 20 ms, 24 kbps — speech), and AudioFile writes the CAF with the
/// encoder's magic cookie and a packet table (priming + remainder), so the duration is exact.
public enum CafOpus {
    public static let mime = "audio/x-caf"
    public static let filename = "Audio Message.caf"
    public static let sampleRate: Double = 24_000

    public static func encode(fileURL: URL, bitRate: Int = 24_000, progress: (@Sendable (Double) -> Void)? = nil) throws -> Data {
        let source = try OggOpus.PCMSource(fileURL: fileURL, sampleRate: sampleRate, progress: progress)
        let stream = try OggOpus.opusStream(format: source.format, bitRate: bitRate, next: source.next)
        return try write(stream: stream, sampleRate: sampleRate, validFrames: source.produced)
    }

    /// Encode mono float PCM (any rate; resampled to 24 kHz) — tests and fixtures.
    public static func encode(pcm: AVAudioPCMBuffer, bitRate: Int = 24_000) throws -> Data {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw OggOpus.EncodeError.unsupported
        }
        let buffer = pcm.format == target ? pcm : try OggOpus.convert(pcm, to: target)
        var given = false
        let stream = try OggOpus.opusStream(format: target, bitRate: bitRate) {
            defer { given = true }
            return given ? nil : buffer
        }
        return try write(stream: stream, sampleRate: sampleRate, validFrames: Int64(buffer.frameLength))
    }

    static func write(stream: (packets: [Data], preSkip: UInt16, framesPerPacket: AVAudioFrameCount, cookie: Data?), sampleRate: Double, validFrames: Int64) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("comms-caf-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                               mFramesPerPacket: stream.framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var file: AudioFileID?
        guard AudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &asbd, .eraseFile, &file) == noErr, let file else {
            throw OggOpus.EncodeError.failed
        }
        var closed = false
        defer { if !closed { AudioFileClose(file) } }
        if let cookie = stream.cookie, !cookie.isEmpty {
            let status = cookie.withUnsafeBytes { AudioFileSetProperty(file, kAudioFilePropertyMagicCookieData, UInt32(cookie.count), $0.baseAddress!) }
            guard status == noErr else { throw OggOpus.EncodeError.failed }
        }
        var bytes = Data()
        var descriptions: [AudioStreamPacketDescription] = []
        descriptions.reserveCapacity(stream.packets.count)
        for p in stream.packets {
            descriptions.append(AudioStreamPacketDescription(mStartOffset: Int64(bytes.count), mVariableFramesInPacket: 0, mDataByteSize: UInt32(p.count)))
            bytes.append(p)
        }
        var count = UInt32(descriptions.count)
        let written = bytes.withUnsafeBytes { raw in
            AudioFileWritePackets(file, false, UInt32(bytes.count), descriptions, 0, &count, raw.baseAddress!)
        }
        guard written == noErr, count == UInt32(descriptions.count) else { throw OggOpus.EncodeError.failed }
        // Exact length: the encoder's priming at the front, the padding of the last packet at the end.
        let total = Int64(stream.packets.count) * Int64(stream.framesPerPacket)
        let priming = Int32(stream.preSkip)
        let valid = max(0, min(validFrames, total - Int64(priming)))
        var table = AudioFilePacketTableInfo(mNumberValidFrames: valid, mPrimingFrames: priming, mRemainderFrames: Int32(clamping: total - valid - Int64(priming)))
        _ = AudioFileSetProperty(file, kAudioFilePropertyPacketTableInfo, UInt32(MemoryLayout<AudioFilePacketTableInfo>.size), &table)
        AudioFileClose(file)
        closed = true
        return stripFreeChunks(try Data(contentsOf: url))
    }

    /// AudioFile reserves room for its header with a `free` chunk (~32 kB here, 4× the audio
    /// of a short note); CAF readers skip it, so it is dropped before upload. Chunk order and
    /// everything else stay as written. A malformed layout is returned untouched.
    static func stripFreeChunks(_ data: Data) -> Data {
        guard data.count >= 8, data.prefix(4) == Data("caff".utf8) else { return data }
        var out = Data(data.prefix(8))
        var i = data.startIndex + 8
        while i < data.endIndex {
            guard i + 12 <= data.endIndex else { return data }
            let type = data[i..<i + 4]
            let size = data[i + 4..<i + 12].reduce(Int64(0)) { $0 << 8 | Int64($1) }
            // -1 = the data chunk runs to the end of the file (it is then the last chunk).
            let end = size < 0 ? data.endIndex : i + 12 + Int(size)
            guard size >= -1, end <= data.endIndex else { return data }
            if type != Data("free".utf8) { out.append(data[i..<end]) }
            i = end
        }
        return out
    }
}
