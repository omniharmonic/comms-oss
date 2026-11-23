import CommsClient
import CommsTestSupport
import Foundation
import SwiftUI
import XCTest
@testable import CommsCore
@testable import CommsUI

/// Sprint Task 8: the delivery caption under the owner's newest message (Sent, Delivered,
/// Read 2:14 PM, group Read by N) and the pinned grid at one, two and nine pins.
@MainActor
final class PinsReceiptsSnapshotTests: XCTestCase {
    override func setUp() async throws { ListSamples.seedAvatars() }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let sent = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
    private let en = Locale(identifier: "en_US")

    private func mine(_ delivery: String, readAt: Date? = nil, readBy: [CommsMessage.Reader]? = nil) -> CommsMessage {
        var m = FixtureMessages.message(id: "$m", outgoing: true, at: sent, text: "On my way", delivery: delivery)
        m.readAt = readAt
        m.readBy = readBy
        return m
    }

    // MARK: texts

    func testReceiptTexts() {
        let now = sent.addingTimeInterval(3600)
        func text(_ m: CommsMessage, group: Bool = false) -> String? { Receipt(m, isGroup: group)?.text(now: now, calendar: utc, locale: en) }
        XCTAssertEqual(text(mine("pending")), "Sending…")
        XCTAssertEqual(text(mine("sent")), "Sent")
        XCTAssertEqual(text(mine("delivered")), "Delivered")
        XCTAssertEqual(text(mine("read")), "Read")
        XCTAssertEqual(text(mine("read", readAt: sent.addingTimeInterval(14 * 60))), "Read 8:14\u{202F}AM")
        XCTAssertNil(text(mine("failed")), "Not Delivered is the row's own caption")
        let readers = [CommsMessage.Reader(id: "@a", name: "Alex", readAt: sent), CommsMessage.Reader(id: "@b", name: "Sam", readAt: sent),
                       CommsMessage.Reader(id: "@c", name: "Kai", readAt: sent)]
        XCTAssertEqual(text(mine("read", readBy: readers), group: true), "Read by 3")
        XCTAssertEqual(text(mine("read", readAt: sent, readBy: [readers[0]])), "Read 8:00\u{202F}AM", "a DM names the time, not a count")
        XCTAssertEqual(Receipt(mine("read", readBy: readers), isGroup: true)?.readers.map(\.name), ["Alex", "Sam", "Kai"])
        // Someone else's message has no caption.
        XCTAssertNil(Receipt(FixtureMessages.message(id: "$x", at: sent, delivery: nil)))
    }

    func testReadTimeFollowsMessages() {
        XCTAssertEqual(Receipt.readTime(sent, now: sent.addingTimeInterval(60), calendar: utc, locale: en), "8:00\u{202F}AM")
        XCTAssertEqual(Receipt.readTime(sent, now: sent.addingTimeInterval(86_400), calendar: utc, locale: en), "Yesterday")
        XCTAssertEqual(Receipt.readTime(sent, now: sent.addingTimeInterval(3 * 86_400), calendar: utc, locale: en), "Friday")
        XCTAssertEqual(Receipt.readTime(sent, now: sent.addingTimeInterval(30 * 86_400), calendar: utc, locale: en), "1/15/27")
    }

    func testCaptionOnlyUnderTheNewestOwnMessage() {
        let mineRow: TranscriptRow = .message(mine("delivered"), .single, showSenderName: false, showAvatar: false)
        XCTAssertEqual(Receipt.forLast([mineRow])?.receipt.text, "Delivered")
        let reply: TranscriptRow = .message(FixtureMessages.message(id: "$r", at: sent.addingTimeInterval(60), text: "ok"), .single, showSenderName: false, showAvatar: false)
        XCTAssertNil(Receipt.forLast([mineRow, reply]), "a reply after it hides the caption, as iMessage")
    }

    // MARK: snapshots

    private func row(_ m: CommsMessage, group: Bool = false, now: Date) -> some View {
        let rows: [TranscriptRow] = [.message(m, .single, showSenderName: false, showAvatar: false)]
        let receipt = Receipt.forLast(rows, isGroup: group)?.receipt
        // The read time's clock, zone and locale are pinned for the reference image.
        return TranscriptRowView(row: rows[0], context: TranscriptRowContext(isGroup: group, spacingAbove: 0, receipt: receipt, now: now))
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
            .environment(\.calendar, utc)
            .environment(\.locale, en)
    }

    func testReceiptFooterSnapshots() {
        let readers = (1...3).map { CommsMessage.Reader(id: "@r\($0)", name: "Reader \($0)", readAt: sent) }
        Snapshot.assert(row(mine("sent"), now: sent), named: "receiptSent")
        Snapshot.assert(row(mine("delivered"), now: sent), named: "receiptDelivered")
        Snapshot.assert(row(mine("read", readAt: sent.addingTimeInterval(14 * 60)), now: sent.addingTimeInterval(3600)), named: "receiptReadTime")
        Snapshot.assert(row(mine("read", readBy: readers), group: true, now: sent), named: "receiptReadByThree")
    }

    func testPinnedGridStates() {
        ListSnapshot.assert(PinnedGrid(threads: Array(ListSamples.pinned.prefix(1)), selection: nil, onSelect: { _ in }), named: "pinnedGridOne")
        ListSnapshot.assert(PinnedGrid(threads: Array(ListSamples.pinned.prefix(2)), selection: nil, onSelect: { _ in }), named: "pinnedGridTwo")
        let nine = (0..<9).map { i in
            ListSamples.thread("p9_\(i)", title: "Pin \(i + 1)", avatar: .monogram("P\(i + 1)", members: []), networks: [.whatsapp],
                               preview: "", minutesAgo: Double(i * 10), pinned: true)
        }
        ListSnapshot.assert(PinnedGrid(threads: nine, selection: nine[0].id, onSelect: { _ in }), named: "pinnedGridNine")
    }
}
