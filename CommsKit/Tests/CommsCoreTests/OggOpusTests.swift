import AVFoundation
@testable import CommsCore
import XCTest

final class OggOpusTests: XCTestCase {
    /// 1.5 s of a 440 Hz tone, 48 kHz mono float.
    private func tone(seconds: Double = 1.5) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let n = AVAudioFrameCount(48_000 * seconds)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        b.frameLength = n
        for i in 0..<Int(n) { b.floatChannelData![0][i] = 0.3 * sin(2 * .pi * 440 * Float(i) / 48_000) }
        return b
    }

    func testCRCMatchesOggReference() {
        // The Ogg CRC of "OggS" (no reflection, init 0), checked against libogg's table.
        XCTAssertEqual(OggOpus.crc32(Data("OggS".utf8)), 0x5FB0_A94F)
        XCTAssertEqual(OggOpus.crc32(Data()), 0)
    }

    func testEncodesAValidOggOpusStream() throws {
        let data = try OggOpus.encode(pcm: tone())
        XCTAssertEqual(data.prefix(4), Data("OggS".utf8))
        XCTAssertNotNil(data.range(of: Data("OpusHead".utf8)))
        XCTAssertNotNil(data.range(of: Data("OpusTags".utf8)))
        XCTAssertGreaterThan(data.count, 1000)

        // When ffprobe is installed (developer Macs), let it read the file back.
        let ffprobe = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffprobe else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("comms-opus-\(UUID().uuidString).ogg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-show_entries", "stream=codec_name,sample_rate,channels:format=format_name,duration", "-of", "default=nw=1", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0, out)
        XCTAssertTrue(out.contains("codec_name=opus"), out)
        XCTAssertTrue(out.contains("format_name=ogg"), out)
        XCTAssertTrue(out.contains("channels=1"), out)
        let duration = out.split(separator: "\n").first { $0.hasPrefix("duration=") }.flatMap { Double($0.dropFirst("duration=".count)) }
        XCTAssertEqual(duration ?? 0, 1.5, accuracy: 0.02, out)
        XCTAssertFalse(out.lowercased().contains("error"), out)
    }

    /// Ogg pages: (granule, header type, packets).
    private func pages(_ data: Data) -> [(granule: Int64, flags: UInt8, packets: Int)] {
        var out: [(Int64, UInt8, Int)] = []
        var i = data.startIndex
        while i + 27 <= data.endIndex, data[i..<i + 4] == Data("OggS".utf8) {
            let flags = data[i + 5]
            let granule = data[i + 6..<i + 14].enumerated().reduce(Int64(0)) { $0 | Int64($1.element) << (8 * $1.offset) }
            let n = Int(data[i + 26])
            let lacing = data[i + 27..<i + 27 + n]
            let packets = lacing.filter { $0 < 255 }.count
            let size = lacing.reduce(0) { $0 + Int($1) }
            out.append((granule, flags, packets))
            i += 27 + n + size
        }
        return out
    }

    private func ffprobe(_ data: Data) throws -> String? {
        let tool = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tool else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("comms-opus-\(UUID().uuidString).ogg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-v", "error", "-show_entries", "stream=codec_name,start_time,duration:format=duration", "-of", "default=nw=1", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func value(_ key: String, in out: String) -> Double? {
        out.split(separator: "\n").first { $0.hasPrefix(key + "=") }.flatMap { Double($0.dropFirst(key.count + 1)) }
    }

    func testMultiPageGranulesFollowRFC7845() throws {
        // 12 s: three audio pages (255 + 255 + 91 packets of 20 ms).
        let data = try OggOpus.encode(pcm: tone(seconds: 12))
        let all = pages(data)
        XCTAssertEqual(all.first?.flags, 0x02, "BOS")
        let audio = Array(all.dropFirst(2))
        XCTAssertGreaterThanOrEqual(audio.count, 3, "a multi-page stream")
        var packets = 0
        for (i, p) in audio.enumerated() {
            packets += p.packets
            if i < audio.count - 1 {
                XCTAssertEqual(p.granule, Int64(packets * 960), "page \(i): granule = decoded samples incl. pre-skip")
                XCTAssertEqual(p.flags, 0)
            } else {
                XCTAssertEqual(p.flags, 0x04, "EOS")
                XCTAssertLessThanOrEqual(p.granule, Int64(packets * 960))
            }
        }
        if let out = try ffprobe(data) {
            XCTAssertEqual(value("start_time", in: out) ?? -1, 0, accuracy: 0.0001, out)
            XCTAssertEqual(value("duration", in: out) ?? 0, 12, accuracy: 0.03, out)
        }
    }

    func testChunkedFileEncodeResamplesAndReportsProgress() throws {
        // A 44.1 kHz stereo file (not what the recorder makes): resampled to 48 kHz mono in chunks.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("comms-voice-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
            let n = AVAudioFrameCount(44_100 * 7)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
            b.frameLength = n
            for c in 0..<2 { for i in 0..<Int(n) { b.floatChannelData![c][i] = 0.3 * sin(2 * .pi * 330 * Float(i) / 44_100) } }
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: b)
        }
        let seen = LockedProgress()
        let data = try OggOpus.encode(fileURL: url) { seen.add($0) }
        XCTAssertEqual(seen.last, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(seen.count, 10, "progress reported per chunk")
        if let out = try ffprobe(data) {
            XCTAssertTrue(out.contains("codec_name=opus"), out)
            XCTAssertEqual(value("start_time", in: out) ?? -1, 0, accuracy: 0.0001, out)
            XCTAssertEqual(value("duration", in: out) ?? 0, 7, accuracy: 0.05, out)
        }
    }

    func testEncodesTheRecordersM4A() throws {
        // What the recorder writes (AAC .m4a, 48 kHz mono) → Ogg/Opus.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("comms-voice-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1],
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: tone(seconds: 1))
        }
        let data = try OggOpus.encode(fileURL: url)
        XCTAssertEqual(data.prefix(4), Data("OggS".utf8))
    }
}

final class LockedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    var last: Double { lock.lock(); defer { lock.unlock() }; return values.last ?? -1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}
