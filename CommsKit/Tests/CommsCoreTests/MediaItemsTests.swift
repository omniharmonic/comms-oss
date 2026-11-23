import CommsClient
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

final class MediaItemsTests: XCTestCase {
    private func date(_ iso: String) -> Date { PrismJSON.parseDate(iso)! }

    private func msg(_ id: String, _ iso: String, attachments: [[String: Any]] = [], links: [[String: Any]] = []) -> CommsMessage {
        FixtureMessages.message(id: id, at: date(iso), attachments: attachments, linkPreviews: links)
    }

    func testInspectorPhotosTabListsImageAttachmentsNewestFirst() {
        let messages = [
            msg("a", "2026-11-20T10:00:00Z", attachments: [FixtureMessages.image(token: "old", w: 4, h: 3)]),
            msg("b", "2026-11-20T11:00:00Z", attachments: [["kind": "file", "name": "notes.pdf", "mediaToken": "doc"]]),
            msg("c", "2026-11-21T09:00:00Z", attachments: [
                FixtureMessages.image(token: "new1", w: 4, h: 3),
                ["kind": "video", "mediaToken": "clip", "thumbToken": "clip_thumb"],
            ]),
            msg("d", "2026-11-21T09:05:00Z", attachments: [["kind": "sticker", "mediaToken": "stk"]]),
            msg("e", "2026-11-21T09:06:00Z", attachments: [["kind": "image", "w": 1, "h": 1]]), // no token: nothing to show
        ]
        XCTAssertEqual(mediaItems(from: messages).map(\.mediaToken), ["new1", "clip", "old"])
        XCTAssertEqual(mediaItems(from: messages.reversed()).map(\.mediaToken), ["new1", "clip", "old"], "order comes from sentAt, not input order")
        XCTAssertEqual(mediaItems(from: []).count, 0)
    }

    func testLinksListNewestFirstWithoutDuplicateURLs() {
        let messages = [
            msg("a", "2026-11-20T10:00:00Z", links: [["url": "https://example.test/a", "title": "A"]]),
            msg("b", "2026-11-21T10:00:00Z", links: [["url": "https://example.test/b"], ["url": "https://example.test/a", "title": "A again"]]),
        ]
        XCTAssertEqual(linkItems(from: messages).map(\.url), ["https://example.test/b", "https://example.test/a"])
    }
}
