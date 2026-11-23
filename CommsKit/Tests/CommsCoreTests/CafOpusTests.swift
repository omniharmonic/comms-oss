import AVFoundation
@testable import CommsCore
import XCTest

/// iMessage / SMS voice notes: Opus in CAF, what Messages sends an audio message as.
final class CafOpusTests: XCTestCase {
    private func tone(seconds: Double, rate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let n = AVAudioFrameCount(rate * seconds)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        b.frameLength = n
        for i in 0..<Int(n) { b.floatChannelData![0][i] = 0.3 * sin(2 * .pi * 440 * Float(i) / Float(rate)) }
        return b
    }

    /// The CAF's chunks in order (type → size).
    private func chunks(_ data: Data) -> [(String, Int64)] {
        var out: [(String, Int64)] = []
        var i = data.startIndex + 8
        while i + 12 <= data.endIndex {
            let type = String(decoding: data[i..<i + 4], as: UTF8.self)
            let size = data[i + 4..<i + 12].reduce(Int64(0)) { $0 << 8 | Int64($1) }
            out.append((type, size))
            i += 12 + Int(size < 0 ? Int64(data.endIndex - i - 12) : size)
        }
        return out
    }

    func testEncodesOpusInCAFWithExactLength() throws {
        let data = try CafOpus.encode(pcm: tone(seconds: 2.5))
        XCTAssertEqual(data.prefix(4), Data("caff".utf8))
        let types = chunks(data).map(\.0)
        XCTAssertEqual(types.first, "desc")
        XCTAssertTrue(types.contains("kuki"), "the encoder's magic cookie: \(types)")
        XCTAssertTrue(types.contains("pakt"), "packet table: \(types)")
        XCTAssertTrue(types.contains("data"))
        // desc: sample rate (Float64) then the format id 'opus'.
        let desc = data[data.startIndex + 20..<data.startIndex + 40]
        XCTAssertEqual(desc[desc.startIndex + 8..<desc.startIndex + 12], Data("opus".utf8))
        // Speech-sized: 2.5 s at 24 kbps ≈ 7.5 kB (+ headers/packet table), far from PCM.
        XCTAssertLessThan(data.count, 20_000, "\(chunks(data))")

        // Read back by Core Audio: Opus, mono, 24 kHz, the real duration (priming trimmed).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("comms-caf-test-\(UUID().uuidString).caf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatOpus)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.sampleRate, CafOpus.sampleRate)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 2.5, accuracy: 0.001)
        // And it decodes (not silence).
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: pcm)
        let peak = (0..<Int(pcm.frameLength)).reduce(Float(0)) { max($0, abs(pcm.floatChannelData![0][$1])) }
        XCTAssertGreaterThan(peak, 0.1)

        if let out = try ffprobe(url) {
            XCTAssertTrue(out.contains("codec_name=opus"), out)
            XCTAssertTrue(out.contains("format_name=caf"), out)
        }
    }

    func testEncodesTheRecordersM4AInChunks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("comms-caf-src-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1],
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: tone(seconds: 3))
        }
        let seen = LockedProgress()
        let data = try CafOpus.encode(fileURL: url, progress: { seen.add($0) })
        XCTAssertEqual(data.prefix(4), Data("caff".utf8))
        XCTAssertEqual(seen.last, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(seen.count, 10, "progress per 100 ms chunk")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("comms-caf-out-\(UUID().uuidString).caf")
        try data.write(to: out)
        defer { try? FileManager.default.removeItem(at: out) }
        let file = try AVAudioFile(forReading: out)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatOpus)
        // AAC adds its own priming on the way in; the length stays within a frame or two.
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 3, accuracy: 0.05)
    }

    private func ffprobe(_ url: URL) throws -> String? {
        guard let tool = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-v", "error", "-show_entries", "stream=codec_name:format=format_name", "-of", "default=nw=1", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
