import AVFoundation
import CommsClient
import CommsCore
import CommsTestSupport
import CoreVideo
import ImageIO
@testable import CommsUI
import SwiftUI
import UniformTypeIdentifiers
import XCTest

/// Location never leaves with a picked photo or video; size is checked before bytes are read.
@MainActor
final class AttachmentImportTests: XCTestCase {
    typealias Import = AttachmentImport

    private func image(_ type: UTType, properties: [CFString: Any] = [:], xmp: CGImageMetadata? = nil) throws -> Data {
        let cg = try XCTUnwrap(MediaImage(data: FixtureMessages.placeholderPNG)).cgImage
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        if let xmp {
            CGImageDestinationAddImageAndMetadata(dest, cg, xmp, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private let gps: [CFString: Any] = [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.6, kCGImagePropertyGPSLatitudeRef: "N",
                                                                       kCGImagePropertyGPSLongitude: 122.3, kCGImagePropertyGPSLongitudeRef: "W"]]

    func testJPEGAndPNGLoseGPSAndKeepTheirSize() throws {
        for type in [UTType.jpeg, .png] {
            let original = try image(type, properties: gps)
            XCTAssertTrue(Import.containsLocation(original), "\(type)")
            let a = try Import.make(data: original, type: type, filename: "IMG.\(type.preferredFilenameExtension!)")
            XCTAssertEqual(a.kind, .image)
            XCTAssertEqual(a.mime, type.preferredMIMEType)
            XCTAssertFalse(Import.containsLocation(a.data), "\(type): GPS stripped")
            XCTAssertEqual(a.pixelWidth, 4)
            XCTAssertEqual(a.pixelHeight, 3)
        }
    }

    func testXMPAndIPTCLocationsAreCaught() throws {
        let meta = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "photoshop:City" as CFString, "Seattle" as CFString))
        let xmp = try image(.jpeg, xmp: meta)
        XCTAssertTrue(Import.containsLocation(xmp), "XMP photoshop:City")
        let iptc = try image(.jpeg, properties: [kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Seattle"]])
        XCTAssertTrue(Import.containsLocation(iptc), "IPTC City")
        for data in [xmp, iptc] {
            let a = try Import.make(data: data, type: .jpeg, filename: "x.jpg")
            XCTAssertFalse(Import.containsLocation(a.data), "falls back to a metadata-free JPEG")
        }
        XCTAssertFalse(Import.containsLocation(try image(.jpeg)))
    }

    func testStripFailureFallsBackToReencodeAndRefusesWhenThatFailsToo() throws {
        let original = try image(.jpeg, properties: gps)
        // The lossless rewrite fails: a metadata-free JPEG instead.
        let a = try Import.picture(data: original, type: .jpeg, name: "IMG.jpg", strip: { _ in nil })
        XCTAssertFalse(Import.containsLocation(a.data))
        XCTAssertEqual(a.data.prefix(2), Data([0xFF, 0xD8]))
        // The "stripped" bytes still carry GPS: never sent; the re-encode is used.
        let b = try Import.picture(data: original, type: .jpeg, name: "IMG.jpg", strip: { $0 })
        XCTAssertFalse(Import.containsLocation(b.data))
        // Both fail: refused (fails closed), the original is never returned.
        XCTAssertThrowsError(try Import.picture(data: original, type: .jpeg, name: "IMG.jpg", strip: { _ in nil }, encode: { _ in nil })) {
            XCTAssertEqual($0 as? Import.ImportError, .locationNotRemovable)
        }
        XCTAssertThrowsError(try Import.picture(data: original, type: .jpeg, name: "IMG.jpg", strip: { $0 }, encode: { ($0, 4, 3) })) {
            XCTAssertEqual($0 as? Import.ImportError, .locationNotRemovable, "a 're-encode' that kept GPS is refused too")
        }
    }

    func testOtherFormatsBecomeMetadataFreeJPEG() throws {
        let tiff = try image(.tiff, properties: gps)
        let a = try Import.make(data: tiff, type: .tiff, filename: "IMG_0002.tiff")
        XCTAssertEqual(a.mime, "image/jpeg")
        XCTAssertEqual(a.filename, "IMG_0002.jpg")
        XCTAssertFalse(Import.containsLocation(a.data))
    }

    func testSizeIsCheckedBeforeReading() async throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString).pdf")
        try Data(repeating: 1, count: 10_000).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        do { _ = try await Import.make(fileURL: src, limit: 1_000); XCTFail() } catch {
            XCTAssertEqual(error as? Import.ImportError, .tooLarge(limit: 1_000))
        }
        XCTAssertThrowsError(try Import.make(data: Data(count: 2_000), type: .pdf, filename: "a.pdf", limit: 1_000))
        let ok = try await Import.make(fileURL: src, limit: 1_000_000)
        XCTAssertEqual(ok.kind, .file)
        XCTAssertEqual(ok.byteCount, 10_000)
        let copy = try XCTUnwrap(ok.fileURL)
        XCTAssertTrue(copy.path.hasPrefix(OutgoingFiles.directory.path), "a copy we own (streamed, deleted after upload)")
        XCTAssertTrue(ok.data.isEmpty, "not loaded into memory")
        ok.deleteFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "the owner's original is never touched")
    }

    /// A one-second 64×64 movie with a QuickTime location, written with AVAssetWriter.
    private func movieWithLocation() async throws -> URL {
        let url = OutgoingFiles.newURL(extension: "mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.value = "+47.6062-122.3321/" as NSString
        location.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [location]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            XCTAssertTrue(adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    func testVideoLocationIsRemovedWithoutReencoding() async throws {
        let original = try await movieWithLocation()
        let hadLocation = await Import.videoHasLocation(original)
        XCTAssertTrue(hadLocation, "the fixture movie carries a location")
        let a = try await Import.make(ownedFile: original, originalName: "IMG_0003.MOV", limit: nil)
        XCTAssertEqual(a.kind, .video)
        let clean = try XCTUnwrap(a.fileURL)
        let stillHas = await Import.videoHasLocation(clean)
        XCTAssertFalse(stillHas, "location stripped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path), "the unstripped copy is deleted")
        XCTAssertEqual(a.pixelWidth, 64)
        XCTAssertEqual(a.durationMs ?? 0, 1000, accuracy: 150)
        XCTAssertThrowsError(try Import.make(data: Data([0, 0, 0, 20]), type: .quickTimeMovie, filename: "v.mov"),
                             "videos are only taken from files, through the location filter")
        a.deleteFile()
    }

    func testMacReturnNeverSendsWhileComposing() {
        typealias C = ComposerBar
        XCTAssertEqual(C.returnAction(option: false, shift: false, composing: false), .send)
        XCTAssertEqual(C.returnAction(option: true, shift: false, composing: false), .newline)
        XCTAssertEqual(C.returnAction(option: false, shift: true, composing: false), .newline)
        // にほんご → 日本語 (still marked) → Return confirms the conversion: never a send.
        XCTAssertEqual(C.returnAction(option: false, shift: false, composing: true), .passThrough)
        XCTAssertEqual(C.returnAction(option: true, shift: false, composing: true), .passThrough)
        XCTAssertEqual(ComposerBar.disabledPlaceholder(for: .whatsapp, encrypted: true), "WhatsApp • Encrypted")
    }

    #if os(macOS)
    func testMarkedTextIsDetectedInTheFieldEditor() {
        // A real text view with marked text (what an input method leaves while composing).
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        if NSApp.keyWindow === window { XCTAssertTrue(ComposerKeyboard.isComposing()) }
        view.unmarkText()
        if NSApp.keyWindow === window { XCTAssertFalse(ComposerKeyboard.isComposing()) }
        window.orderOut(nil)
    }
    #endif

    func testRecorderStartsOnceAndHandsOverOnlyAFinishedNote() async throws {
        let r = VoiceRecorder(source: .simulated)
        async let a: Void = r.start()
        async let b: Void = r.start()
        _ = await (a, b)
        XCTAssertEqual(r.phase, .recording)
        try await Task.sleep(for: .milliseconds(200))
        r.suspend() // backgrounded: stopped, kept
        XCTAssertEqual(r.phase, .recorded)
        let note = try XCTUnwrap(r.take())
        XCTAssertEqual(note.kind, .voice)
        XCTAssertEqual(note.mime, "audio/ogg")
        XCTAssertGreaterThan(note.durationMs ?? 0, 0)
        XCTAssertEqual(r.phase, .idle)
        XCTAssertNil(r.take(), "handed over once")

        // iMessage / SMS threads send Opus in CAF (a real audio message; BlueBubbles refuses Ogg).
        let im = VoiceRecorder(source: .simulated, format: .for(.imessage))
        await im.start()
        try await Task.sleep(for: .milliseconds(120))
        im.stop()
        let caf = try XCTUnwrap(im.take())
        XCTAssertEqual(caf.mime, "audio/x-caf")
        XCTAssertEqual(caf.filename, "Audio Message.caf")
    }
}
