import CommsClient
import CommsCore
import CommsTestSupport
@testable import CommsUI
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
#if os(macOS)
import AppKit
#endif

/// Drag and drop / paste into the composer (owner report 2026-11-22: "i can't drag images into
/// a message"). Providers are built the way Finder, Photos, Safari and the screenshot thumbnail
/// hand them over; everything goes through the same import as "+ → Files".
@MainActor
final class AttachmentDropTests: XCTestCase {
    private func jpeg(gps: Bool) throws -> Data {
        let cg = try XCTUnwrap(MediaImage(data: FixtureMessages.placeholderPNG)).cgImage
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        let props: [CFString: Any] = gps ? [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.6, kCGImagePropertyGPSLatitudeRef: "N"]] : [:]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func tempFile(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testFinderFileDropBecomesAnImageWithItsSizeAndNoLocation() async throws {
        let src = try tempFile("Screenshot 2026-11-22 at 10.15.32\u{202F}AM.jpg", try jpeg(gps: true))
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: src))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let a = try await AttachmentDrop.load(provider, limit: nil)
        XCTAssertEqual(a.kind, .image, "a picture is sent as a picture (with w/h), not as a file")
        XCTAssertEqual(a.pixelWidth, 4)
        XCTAssertEqual(a.pixelHeight, 3)
        XCTAssertEqual(a.filename, "Screenshot 2026-11-22 at 10.15.32\u{202F}AM.jpg")
        XCTAssertFalse(AttachmentImport.containsLocation(a.data))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "the owner's original is untouched")
    }

    func testImageDataDropLikeSafariOrPhotosIsReadFromItsFileRepresentation() async throws {
        let data = try jpeg(gps: true)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { done in
            done(data, nil)
            return nil
        }
        provider.suggestedName = "sunset"
        let a = try await AttachmentDrop.load(provider, limit: nil)
        XCTAssertEqual(a.kind, .image)
        XCTAssertEqual(a.filename, "sunset.jpeg")
        XCTAssertEqual(a.mime, "image/jpeg")
        XCTAssertFalse(AttachmentImport.containsLocation(a.data))
    }

    func testSizeCapFolderAndRefusedKinds() async throws {
        let big = try tempFile("Movie.pdf", Data(repeating: 1, count: 20_000))
        do { _ = try await AttachmentDrop.load(try XCTUnwrap(NSItemProvider(contentsOf: big)), limit: 1_000); XCTFail() } catch {
            XCTAssertEqual(error as? AttachmentImport.ImportError, .tooLarge(limit: 1_000))
        }
        let folder = big.deletingLastPathComponent()
        do { _ = try await AttachmentImport.make(fileURL: folder, limit: nil); XCTFail() } catch {
            XCTAssertEqual(error as? AttachmentImport.ImportError, .folder)
        }
        let svg = try tempFile("logo.svg", Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8))
        do { _ = try await AttachmentDrop.load(try XCTUnwrap(NSItemProvider(contentsOf: svg)), limit: nil); XCTFail() } catch {
            XCTAssertEqual(error as? AttachmentImport.ImportError, .unsupportedType)
        }
        let script = try tempFile("run.sh", Data("echo hi\n".utf8))
        do { _ = try await AttachmentImport.make(fileURL: script, limit: nil); XCTFail() } catch {
            XCTAssertEqual(error as? AttachmentImport.ImportError, .unsupportedType)
        }
        XCTAssertEqual(AttachmentImport.ImportError.tooMany(limit: 10).errorDescription, "You can attach up to 10 items to one message.")
        XCTAssertEqual(AttachmentImport.ImportError.folder.errorDescription, "Folders can't be attached. Attach the files inside it instead.")
    }

    func testWhatADropTargetAccepts() {
        XCTAssertTrue(AttachmentDrop.canAttach([.fileURL]))
        XCTAssertTrue(AttachmentDrop.canAttach([.heic]))
        XCTAssertTrue(AttachmentDrop.canAttach([.quickTimeMovie]))
        XCTAssertFalse(AttachmentDrop.canAttach([.utf8PlainText]), "text drops are the text field's")
        XCTAssertFalse(AttachmentDrop.canAttach([.url]))
        XCTAssertEqual(AttachmentDrop.preferredType([.url, .png, .tiff]), .png, "the provider's best image, not the page link")
        XCTAssertEqual(AttachmentDrop.preferredType([.png, .quickTimeMovie]), .quickTimeMovie)
        XCTAssertNil(AttachmentDrop.preferredType([.utf8PlainText]))
    }

    func testDropInboxHandsProvidersOverOnce() {
        let inbox = ComposerDropInbox()
        let g = inbox.generation
        inbox.deliver([NSItemProvider(), NSItemProvider()])
        XCTAssertEqual(inbox.generation, g + 1)
        XCTAssertEqual(inbox.take().count, 2)
        XCTAssertTrue(inbox.take().isEmpty)
        inbox.deliver([])
        XCTAssertEqual(inbox.generation, g + 1, "an empty drop delivers nothing")
    }

    func testUndeliveredUnsupportedTypeShowsTheServersReason() {
        let f = CommsSendFailure(reason: .unsupportedType, message: "This file can't be sent: photos must be JPEG, PNG, GIF or WebP.")
        XCTAssertEqual(f.displayText, "This file can't be sent: photos must be JPEG, PNG, GIF or WebP.")
        XCTAssertEqual(CommsSendFailure(reason: .invalid, message: "The upload could not be read. Try attaching the file again.").displayText,
                       "The upload could not be read. Try attaching the file again.")
    }

    #if os(macOS)
    func testPasteAttachesFilesAndImagesButNotText() {
        typealias P = NSPasteboard.PasteboardType
        XCTAssertEqual(ComposerPaste.decide(types: [.fileURL, .string], hasFileURLs: true, string: "Photo.jpg"), .files,
                       "a Finder copy attaches the file, never pastes its name")
        XCTAssertEqual(ComposerPaste.decide(types: [.tiff, .png], hasFileURLs: false, string: nil), .image(.tiff))
        XCTAssertEqual(ComposerPaste.decide(types: [.png, .string], hasFileURLs: false, string: "https://example.com/a.png"), .image(.png),
                       "Safari's Copy Image also puts the address as text")
        XCTAssertEqual(ComposerPaste.decide(types: [.string, .rtf, .tiff], hasFileURLs: false, string: "See you at 7"), .text)
        XCTAssertEqual(ComposerPaste.decide(types: [.string], hasFileURLs: false, string: "hello"), .text)
    }

    func testPasteReadsTheRealPasteboard() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("comms-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(try jpeg(gps: true), forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        let jobs = try XCTUnwrap(ComposerPaste.jobs(from: board, limit: nil))
        XCTAssertEqual(jobs.count, 1)
        let a = try await jobs[0]()
        XCTAssertEqual(a.kind, .image)
        XCTAssertFalse(AttachmentImport.containsLocation(a.data))
        board.clearContents()
        board.setString("just text", forType: .string)
        XCTAssertNil(ComposerPaste.jobs(from: board, limit: nil))
    }
    #endif
}
