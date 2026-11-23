import CommsClient
import CoreGraphics
import Foundation
import SwiftUI
import XCTest
@testable import CommsUI

/// Thread row, avatar and pinned-grid snapshots (UX spec §3 and §9, Mac sizes).
@MainActor
final class ListSnapshotTests: XCTestCase {
    override func setUp() async throws {
        ListSamples.seedAvatars()
    }

    func testRowUnreadWithBadge() {
        let t = ListSamples.thread("r1", title: "Juniper Vale", avatar: .token("sample-1"), networks: [.telegram],
                                   preview: "Sure! Happy to meet any time this week.", minutesAgo: 22, unread: 2)
        ListSnapshot.assert(ThreadRow(thread: t, isSelected: false, now: ListSamples.now), named: "rowUnreadWithBadge")
    }

    func testRowGroupMonogramCluster() {
        let t = ListSamples.thread("r2", title: "Garden Crew", kind: .group,
                                   avatar: .monogram("GC", members: [.token("sample-2"), .monogram("OP", members: []), .token("sample-3")]),
                                   networks: [.whatsapp], preview: "Bringing the seed trays on Saturday, and the spare gloves too.",
                                   minutesAgo: 60 * 26)
        ListSnapshot.assert(ThreadRow(thread: t, isSelected: false, now: ListSamples.now), named: "rowGroupMonogramCluster")
    }

    func testRowLongTitleTruncates() {
        let t = ListSamples.thread("r3", title: "A conversation title that is much too long to fit on one line of the sidebar",
                                   avatar: .monogram("AC", members: []), networks: [.email],
                                   preview: "Short.", minutesAgo: 60 * 24 * 40)
        ListSnapshot.assert(ThreadRow(thread: t, isSelected: false, now: ListSamples.now), named: "rowLongTitleTruncates")
    }

    func testRowSelectedIsAccentBlue() {
        let t = ListSamples.thread("r4", title: "Orin Pell", avatar: .token("sample-4"), networks: [.imessage],
                                   preview: "Here's my latest draft.", minutesAgo: 90, unread: 1)
        ListSnapshot.assert(ThreadRow(thread: t, isSelected: true, now: ListSamples.now), named: "rowSelectedAccent")
    }

    func testPinnedGridThreeColumns() {
        ListSnapshot.assert(
            PinnedGrid(threads: ListSamples.pinned, selection: ListSamples.pinned[4].id, onSelect: { _ in }),
            named: "pinnedGridThreeColumns"
        )
    }

    func testAvatarFallbacks() {
        let row = HStack(spacing: 12) {
            AvatarView(nil, kind: .dm, size: 40, badge: .sms)
            AvatarView(nil, kind: .group, size: 40, badge: .discord)
            AvatarView(.monogram("JV", members: []), size: 40, badge: .matrix)
            AvatarView(.monogram("TQ", members: [.token("sample-5"), .token("sample-6")]), kind: .group, size: 40, badge: .messenger)
            AvatarView(.token("never-loaded"), size: 40, badge: .x)
        }
        ListSnapshot.assert(row, named: "avatarFallbacks")
    }

    func testAccessibilityLabelNamesNetworkUnreadAndMuted() {
        let t = ListSamples.thread("a1", title: "Milo Hart", avatar: nil, networks: [.whatsapp, .sms],
                                   preview: "On my way", minutesAgo: 5, unread: 3, muted: true)
        XCTAssertEqual(ThreadRow.accessibilityLabel(for: t, time: "2:55 PM"),
                       "Milo Hart, WhatsApp and SMS, 3 unread messages, muted, 2:55 PM, On my way")
        let quiet = ListSamples.thread("a2", title: "Wren", avatar: nil, networks: [.telegram], preview: "", minutesAgo: 5, unread: 1)
        XCTAssertEqual(ThreadRow.accessibilityLabel(for: quiet, time: nil), "Wren, Telegram, 1 unread message")
    }

    func testTimestampsFollowMessagesRules() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = ThreadTimestamp(calendar: cal, locale: Locale(identifier: "en_US"))
        let now = ListSamples.now  // Saturday 21 Nov 2026, 15:00 UTC
        XCTAssertEqual(f.string(for: now.addingTimeInterval(-22 * 60), now: now), "2:38\u{202F}PM", "ICU puts a narrow no-break space before AM/PM")
        XCTAssertEqual(f.string(for: now.addingTimeInterval(-20 * 3600), now: now), "Yesterday")
        XCTAssertEqual(f.string(for: now.addingTimeInterval(-3 * 86400), now: now), "Wednesday")
        XCTAssertEqual(f.string(for: now.addingTimeInterval(-40 * 86400), now: now), "10/12/26")
    }

    /// `RECORD_SNAPSHOTS=1` also writes design/refs/comms-sidebar-v0.png: the Apple guide's
    /// sidebar crop (left) next to ours (right), for the owner to compare by eye.
    func testWriteSidebarComparison() throws {
        try XCTSkipUnless(ListSnapshot.recording, "design reference is written only when recording")
        let root = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let refURL = root.appendingPathComponent("docs/research/refs/macos26-guide-window-sidebar-transcript.png")
        let reference = try XCTUnwrap(ListSnapshot.readPNG(refURL))
        // The guide image is ≈ 1×: its floating sidebar spans x 8…262.
        let crop = try XCTUnwrap(reference.cropping(to: CGRect(x: 0, y: 0, width: 270, height: reference.height)))

        let mock = SidebarComparisonMock()
        let renderer = ImageRenderer(content: mock.environment(\.colorScheme, .light))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 270, height: CGFloat(reference.height))
        let ours = try XCTUnwrap(renderer.cgImage)

        let gap = 40, s = 2
        let width = crop.width * s + gap + ours.width, height = max(crop.height * s, ours.height)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: height - crop.height * s, width: crop.width * s, height: crop.height * s))
        ctx.draw(ours, in: CGRect(x: crop.width * s + gap, y: height - ours.height, width: ours.width, height: ours.height))
        let out = try XCTUnwrap(ctx.makeImage())
        try ListSnapshot.writePNG(out, to: root.appendingPathComponent("design/refs/comms-sidebar-v0.png"))
    }
}

/// Our sidebar laid out like the guide image: an inset rounded panel, traffic-light dots and the
/// Filter glyph in the top row, a search capsule (drawn here only), then the list content.
private struct SidebarComparisonMock: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color.white
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                        Circle().fill($0).frame(width: 12, height: 12)
                    }
                    Spacer()
                    FilterMenuLabel(isFiltering: false)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search").foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(Color.black.opacity(0.05)))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                SidebarContent(
                    pinned: ListSamples.pinned, threads: ListSamples.rows, selection: ListSamples.pinned[7].id,
                    now: ListSamples.now, onSelect: { _ in }, onReachEnd: {}
                )
                Spacer(minLength: 0)
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ListSnapshot.sidebarBackground(.light)))
            .padding(8)
        }
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
    }
}
