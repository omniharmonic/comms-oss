import AVFoundation
import Foundation

/// Voice notes as Ogg/Opus (RFC 7845), what WhatsApp and Telegram play as native voice notes
/// through the mautrix bridges without converting (send-server report). AVAudioRecorder can
/// only put Opus in CAF, so the recorder's audio is re-encoded here: AVAudioConverter makes
/// the Opus packets (48 kHz mono, 20 ms frames) and this file writes the Ogg pages.
public enum OggOpus {
    public static let mime = "audio/ogg"
    public static let sampleRate: Double = 48_000
    static let frameSize: AVAudioFrameCount = 960 // 20 ms at 48 kHz

    public enum EncodeError: Error { case unsupported, failed }

    /// Encode an audio file (any format AVAudioFile reads: the recorder's .m4a) to Ogg/Opus,
    /// reading it in 100 ms chunks (a long note is never decoded whole into memory). Call it
    /// off the main thread. `progress` gets 0…1.
    public static func encode(fileURL: URL, bitRate: Int = 32_000, progress: (@Sendable (Double) -> Void)? = nil) throws -> Data {
        let source = try PCMSource(fileURL: fileURL, sampleRate: sampleRate, progress: progress)
        let packets = try opusPackets(format: source.format, bitRate: bitRate, next: source.next)
        return mux(packets: packets.packets, preSkip: packets.preSkip, totalSamples: source.produced)
    }

    /// An audio file read in 100 ms chunks, resampled / downmixed to `sampleRate` mono float
    /// (a long note is never decoded whole into memory). Shared by the Ogg and CAF encoders.
    final class PCMSource {
        let format: AVAudioFormat
        private(set) var produced: Int64 = 0
        private let input: AVAudioFile
        private let resampler: AVAudioConverter?
        private let progress: (@Sendable (Double) -> Void)?
        private var finished = false
        private let chunk: AVAudioFrameCount = 4800

        init(fileURL: URL, sampleRate: Double, progress: (@Sendable (Double) -> Void)?) throws {
            input = try AVAudioFile(forReading: fileURL)
            guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
                throw EncodeError.unsupported
            }
            format = pcm
            let source = input.processingFormat
            resampler = source == pcm ? nil : AVAudioConverter(from: source, to: pcm)
            if source != pcm, resampler == nil { throw EncodeError.unsupported }
            self.progress = progress
        }

        func next() throws -> AVAudioPCMBuffer? {
            guard !finished else { return nil }
            let source = input.processingFormat
            guard let raw = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk) else { throw EncodeError.failed }
            if input.framePosition < input.length {
                try input.read(into: raw, frameCount: AVAudioFrameCount(min(Int64(chunk), input.length - input.framePosition)))
            } else {
                raw.frameLength = 0
            }
            if raw.frameLength == 0 { finished = true }
            progress?(min(1, Double(input.framePosition) / Double(max(1, input.length))))
            guard let resampler else {
                if raw.frameLength == 0 { return nil }
                produced += Int64(raw.frameLength)
                return raw
            }
            // Drain the resampler (at end of file, flush what it still holds).
            let capacity = AVAudioFrameCount(Double(max(raw.frameLength, chunk)) * format.sampleRate / source.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw EncodeError.failed }
            var given = false
            var error: NSError?
            let status = resampler.convert(to: out, error: &error) { _, inputStatus in
                if given || raw.frameLength == 0 { inputStatus.pointee = raw.frameLength == 0 ? .endOfStream : .noDataNow; return nil }
                given = true
                inputStatus.pointee = .haveData
                return raw
            }
            if status == .error { throw error ?? EncodeError.failed }
            if out.frameLength == 0 && raw.frameLength == 0 { return nil }
            produced += Int64(out.frameLength)
            return out
        }
    }

    /// Encode 48 kHz mono float PCM to Ogg/Opus.
    public static func encode(pcm: AVAudioPCMBuffer, bitRate: Int = 32_000) throws -> Data {
        var given = false
        let packets = try opusPackets(format: pcm.format, bitRate: bitRate) {
            defer { given = true }
            return given ? nil : pcm
        }
        return mux(packets: packets.packets, preSkip: packets.preSkip, totalSamples: Int64(pcm.frameLength))
    }

    /// Opus packets from PCM buffers handed out by `next` (nil = end).
    static func opusPackets(format: AVAudioFormat, bitRate: Int, next: () throws -> AVAudioPCMBuffer?) throws -> (packets: [Data], preSkip: UInt16) {
        let r = try opusStream(format: format, bitRate: bitRate, next: next)
        return (r.packets, r.preSkip)
    }

    /// Opus packets (20 ms frames at `format`'s rate) plus what a container needs: the
    /// encoder's priming (pre-skip), the frames per packet and its magic cookie (CAF `kuki`).
    static func opusStream(format: AVAudioFormat, bitRate: Int, next: () throws -> AVAudioPCMBuffer?) throws -> (packets: [Data], preSkip: UInt16, framesPerPacket: AVAudioFrameCount, cookie: Data?) {
        let framesPerPacket = AVAudioFrameCount(format.sampleRate / 50) // 20 ms
        var asbd = AudioStreamBasicDescription(mSampleRate: format.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                               mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &asbd), let converter = AVAudioConverter(from: format, to: opus) else {
            throw EncodeError.unsupported
        }
        converter.bitRate = bitRate
        let maxPacket = max(converter.maximumOutputPacketSize, 1500)
        var packets: [Data] = []
        var ended = false
        var readError: (any Error)?
        while true {
            let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 32, maximumPacketSize: maxPacket)
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if ended { inputStatus.pointee = .endOfStream; return nil }
                do {
                    guard let b = try next() else { ended = true; inputStatus.pointee = .endOfStream; return nil }
                    inputStatus.pointee = .haveData
                    return b
                } catch {
                    readError = error
                    ended = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if status == .error { throw error ?? EncodeError.failed }
            if let descs = out.packetDescriptions {
                for i in 0..<Int(out.packetCount) {
                    let d = descs[i]
                    packets.append(Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize)))
                }
            }
            if status == .endOfStream || (ended && out.packetCount == 0) { break }
        }
        guard !packets.isEmpty else { throw EncodeError.failed }
        let lead = Int(converter.primeInfo.leadingFrames)
        return (packets, UInt16(clamping: lead > 0 ? lead : 312), framesPerPacket, converter.magicCookie)
    }

    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { throw EncodeError.unsupported }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw EncodeError.failed }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .endOfStream; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw error ?? EncodeError.failed }
        return out
    }

    // MARK: Ogg

    /// RFC 7845 stream: OpusHead page, OpusTags page, then audio pages. The last page's
    /// granule position is pre-skip + the real sample count (end trimming).
    static func mux(packets: [Data], preSkip: UInt16, totalSamples: Int64, serial: UInt32 = UInt32.random(in: 1...UInt32.max)) -> Data {
        var head = Data("OpusHead".utf8)
        head.append(1) // version
        head.append(1) // channels
        head.appendLE(preSkip)
        head.appendLE(UInt32(sampleRate))
        head.appendLE(UInt16(0)) // output gain
        head.append(0) // mapping family
        var tags = Data("OpusTags".utf8)
        let vendor = Data("Comms".utf8)
        tags.appendLE(UInt32(vendor.count))
        tags.append(vendor)
        tags.appendLE(UInt32(0))

        var out = Data()
        var sequence: UInt32 = 0
        func page(_ packets: [Data], granule: Int64, flags: UInt8) {
            var lacing: [UInt8] = []
            for p in packets {
                var n = p.count
                while n >= 255 { lacing.append(255); n -= 255 }
                lacing.append(UInt8(n))
            }
            var page = Data("OggS".utf8)
            page.append(0)
            page.append(flags)
            page.appendLE(UInt64(bitPattern: granule))
            page.appendLE(serial)
            page.appendLE(sequence)
            let crcOffset = page.count
            page.appendLE(UInt32(0))
            page.append(UInt8(lacing.count))
            page.append(contentsOf: lacing)
            for p in packets { page.append(p) }
            let crc = crc32(page)
            page.replaceSubrange(crcOffset..<crcOffset + 4, with: withUnsafeBytes(of: crc.littleEndian) { Data($0) })
            out.append(page)
            sequence += 1
        }
        page([head], granule: 0, flags: 0x02)
        page([tags], granule: 0, flags: 0)

        let end = Int64(preSkip) + totalSamples
        var batch: [Data] = []
        var segments = 0
        var decoded: Int64 = 0
        for (i, p) in packets.enumerated() {
            let need = p.count / 255 + 1
            if segments + need > 255 {
                // RFC 7845 §4: a page's granule is the samples decoded so far, pre-skip
                // INCLUDED (only the last page is trimmed to pre-skip + the real length).
                page(batch, granule: min(end, decoded), flags: 0)
                batch = []
                segments = 0
            }
            batch.append(p)
            segments += need
            decoded += Int64(frameSize)
            if i == packets.count - 1 { page(batch, granule: end, flags: 0x04) }
        }
        return out
    }

    /// Ogg's CRC-32 (polynomial 0x04C11DB7, no reflection, initial 0).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
