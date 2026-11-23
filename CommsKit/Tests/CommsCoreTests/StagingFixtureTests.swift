import CommsClient
import CommsTestSupport
import Foundation
import XCTest

/// `staging-rooms.json` must use the server's real wire keys (attachments `mediaToken` /
/// `thumbToken`, link previews `imageToken`, avatars `{token}`). The decoder ignores unknown
/// keys, so a wrong key (`token`, `imageMxc`) decodes silently and every picture renders as
/// a placeholder.
final class StagingFixtureTests: XCTestCase {
    func testStagingRoomsUseTheWireMediaKeys() async throws {
        let backend = try FixtureBackend.staging()
        let threads = try await backend.threads(CommsThreadQuery()).threads
        var attachments: [CommsAttachment] = []
        var previews: [CommsLinkPreview] = []
        for t in threads {
            let page = try await backend.messages(threadID: t.id, before: nil, limit: 50)
            attachments += page.messages.flatMap(\.attachments)
            previews += page.messages.flatMap(\.linkPreviews)
        }
        XCTAssertFalse(attachments.isEmpty)
        XCTAssertFalse(previews.isEmpty)
        for a in attachments where a.kind == .image {
            XCTAssertNotNil(a.mediaToken, "image attachment without mediaToken")
            XCTAssertNotNil(a.thumbToken, "image attachment without thumbToken")
        }
        XCTAssertTrue(previews.contains { $0.imageToken != nil }, "the seeded link preview carries an image")
    }

    func testStagingRoomsHaveNoLegacyKeys() throws {
        let text = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        for legacy in ["\"token\": \"stg_", "\"imageMxc\"", "\"mxc\"", "mxc://"] {
            XCTAssertFalse(text.contains(legacy), "legacy key \(legacy) in staging-rooms.json")
        }
    }

    /// The source-tree copy (the bundled resource is CommsTestSupport's `Bundle.module`).
    private static let fixtureURL = URL(fileURLWithPath: "\(#filePath)")
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/CommsTestSupport/Fixtures/staging-rooms.json")
}
