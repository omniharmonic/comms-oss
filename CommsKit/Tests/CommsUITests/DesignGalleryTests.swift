#if DEBUG
import CommsClient
import CommsCore
import CommsTestSupport
import CoreGraphics
import Foundation
import SwiftUI
import XCTest
@testable import CommsUI

/// The DEBUG design gallery: a smoke render on every run, and (RENDER_COMPARISON=1) the static
/// export design/refs/comms-gallery-v0.png the owner reviews.
@MainActor
final class DesignGalleryTests: XCTestCase {
    private func render() async throws -> CGImage {
        let data = try await GalleryData.load(from: try FixtureBackend.staging())
        let renderer = ImageRenderer(content: DesignGalleryBoard(data: data))
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    func testGalleryLoadsStagingRoomsAndRenders() async throws {
        let data = try await GalleryData.load(from: try FixtureBackend.staging())
        XCTAssertEqual(data.oneToOne.thread.kind, .dm)
        XCTAssertEqual(data.group.thread.kind, .group)
        XCTAssertFalse(data.group.members.isEmpty)
        let image = try await render()
        XCTAssertEqual(image.width, Int(2 * (2 * DesignGalleryBoard.panelWidth + 24 + 64)))
        XCTAssertGreaterThan(image.height, 6 * Int(DesignGalleryBoard.panelHeight))
    }

    func testRenderGalleryPNG() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RENDER_COMPARISON"] == "1", "set RENDER_COMPARISON=1")
        let image = try await render()
        try Snapshot.writePNG(image, to: TokensTests.repo.appendingPathComponent("design/refs/comms-gallery-v0.png"))
    }

    func testQuickLookTempFileKeepsExtensionAndIsDeleted() throws {
        let url = try QuickLookTempFile.write(Data([1, 2, 3]), contentType: "image/jpeg; charset=binary", baseName: "Photo")
        XCTAssertEqual(url.pathExtension, "jpeg", "the extension follows the Content-Type")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "Photo")
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        QuickLookTempFile.remove(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        // Anything outside the quick-look root is never deleted.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID().uuidString)")
        try Data().write(to: outside)
        QuickLookTempFile.remove(outside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        try FileManager.default.removeItem(at: outside)
    }

    func testFetchSurvivesRequestHandoff() async throws {
        let viewer = MediaViewer()
        let attachment = FixtureMessages.message(id: "m", at: Date(), attachments: [FixtureMessages.image(token: "tok", w: 4, h: 3)]).attachments[0]
        viewer.open(attachment)
        let request = try XCTUnwrap(viewer.take())
        XCTAssertNil(viewer.request, "handing the request over clears the shared slot")
        let fetcher = MediaFetcher { token in
            XCTAssertEqual(token, "tok")
            try await Task.sleep(nanoseconds: 50_000_000) // in flight while the slot is already clear
            return (Data([9]), "image/png")
        }
        let url = try await QuickLookPreparer.prepare(request.attachment, fetch: fetcher)
        let file = try XCTUnwrap(url)
        // Owner report fix: the served (sniffed) type wins over the attachment's declared mime —
        // BlueBubbles converts HEIC to JPEG while the message still says image/heic.
        XCTAssertEqual(file.lastPathComponent, "Photo.png", "the response's sniffed type wins over the declared mime")
        QuickLookTempFile.remove(file)
    }

    func testANewQuickLookRequestCancelsTheOneInFlight() async throws {
        let slow = FixtureMessages.message(id: "s", at: Date(), attachments: [FixtureMessages.image(token: "slow", w: 4, h: 3)]).attachments[0]
        let fast = FixtureMessages.message(id: "f", at: Date(), attachments: [FixtureMessages.image(token: "fast", w: 4, h: 3)]).attachments[0]
        let fetcher = MediaFetcher { token in
            if token == "slow" { try await Task.sleep(for: .milliseconds(300)) }
            return (Data([token == "slow" ? 1 : 2]), "image/png")
        }
        let fetch = QuickLookFetch()
        var delivered: [URL] = []
        var failures: [String] = []
        fetch.start(slow, fetcher: fetcher, ready: { delivered.append($0) }, failed: { failures.append($0) })
        let first = try XCTUnwrap(fetch.task)
        fetch.start(fast, fetcher: fetcher, ready: { delivered.append($0) }, failed: { failures.append($0) })
        await first.value
        await fetch.task?.value
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(delivered.count, 1, "only the newest request is shown")
        XCTAssertEqual(try Data(contentsOf: delivered[0]), Data([2]))
        XCTAssertTrue(failures.isEmpty, "a cancelled fetch is not an error")
        delivered.forEach(QuickLookTempFile.remove)
    }

    func testCancelledQuickLookFetchDeliversNothingAndLeavesNoFile() async throws {
        let a = FixtureMessages.message(id: "c", at: Date(), attachments: [FixtureMessages.image(token: "c", w: 4, h: 3)]).attachments[0]
        let before = (try? FileManager.default.contentsOfDirectory(atPath: QuickLookTempFile.root.path)) ?? []
        let fetcher = MediaFetcher { _ in
            try await Task.sleep(for: .milliseconds(100))
            return (Data([3]), "image/png")
        }
        let fetch = QuickLookFetch()
        var delivered: [URL] = []
        fetch.start(a, fetcher: fetcher, ready: { delivered.append($0) }, failed: { _ in XCTFail("no alert for a cancel") })
        let task = try XCTUnwrap(fetch.task)
        fetch.cancel() // the transcript disappeared
        await task.value
        XCTAssertTrue(delivered.isEmpty)
        let after = (try? FileManager.default.contentsOfDirectory(atPath: QuickLookTempFile.root.path)) ?? []
        XCTAssertEqual(Set(after), Set(before), "no orphan temp file")
    }

    func testURLErrorCancelledCountsAsCancellation() {
        XCTAssertTrue(QuickLookPreparer.isCancellation(URLError(.cancelled)))
        XCTAssertTrue(QuickLookPreparer.isCancellation(CancellationError()))
        XCTAssertFalse(QuickLookPreparer.isCancellation(URLError(.notConnectedToInternet)))
    }
}
#endif
