import CommsClient
import CommsCore
import CommsTestSupport
@testable import CommsUI
import SwiftUI
import XCTest

/// Sprint Task 9 / polish r2: a row swiped on each side — Messages' circles (Read + Pin; Archive +
/// Mute + Status) half-revealed (parallax), open, stretched past the buttons and armed for a full
/// swipe — and the folder menu (iPhone top-left menu items; the Mac sidebar's title button).
@MainActor
final class RowActionsFolderSnapshotTests: XCTestCase {
    private let threads = [
        ListSamples.thread("s1", title: "Ann Example", avatar: .monogram("AE", members: []), networks: [.whatsapp],
                           preview: "Are we still on for Saturday?", minutesAgo: 4, unread: 1),
        ListSamples.thread("s2", title: "Trail Crew", kind: .group, avatar: .monogram("TC", members: []), networks: [.telegram],
                           preview: "Sam: I'll bring the maps.", minutesAgo: 30),
    ]

    private var actions: ConversationActions {
        ConversationActions(support: .all, toggleMute: { _ in }, setArchived: { _, _ in }, setStatus: { _, _ in },
                            foldersEnabled: true, folders: [CommsChatFolder(id: "cf_1", name: "Work", position: 0)])
    }

    private func swiped(_ offset: CGFloat) -> some View {
        let swipes = SwipeCoordinator()
        swipes.preset("s1", offset: offset)
        let pins = PinActions(isPinned: { _ in false }, toggle: { _ in }, move: { _, _ in })
        return SidebarContent(pinned: [], threads: threads, selection: nil, now: ListSamples.now, onSelect: { _ in }, onReachEnd: {},
                              onSetRead: { _, _ in }, pins: pins, actions: actions)
            .environment(swipes)
    }

    private var g: SwipeGeometry { SwipeGeometry(leading: 2, trailing: 3) }

    func testRowSwipedLeading() {
        ListSnapshot.assert(swiped(g.leadingReveal), named: "rowSwipeLeading", width: 360)
    }

    func testRowSwipeHalfRevealedParallax() {
        ListSnapshot.assert(swiped(-g.trailingReveal / 2), named: "rowSwipeTrailingHalf", width: 360)
    }

    func testRowSwipedTrailing() {
        ListSnapshot.assert(swiped(-g.trailingReveal), named: "rowSwipeTrailing", width: 360)
    }

    func testRowSwipeStretchesTheOuterCircle() {
        ListSnapshot.assert(swiped(-(g.trailingReveal + 40)), named: "rowSwipeTrailingStretched", width: 360)
    }

    func testRowFullSwipeArmedExpandsTheOuterButton() {
        let x = -(g.full(g.trailingReveal) + 10)
        XCTAssertTrue(g.isArmed(x))
        ListSnapshot.assert(swiped(x), named: "rowSwipeTrailingFull", width: 360)
    }

    func testMultiSelect() {
        ListSnapshot.assert(
            SidebarContent(pinned: [], threads: threads, selection: nil, now: ListSamples.now, onSelect: { _ in }, onReachEnd: {},
                           selecting: true, selected: ["s2"]),
            named: "rowMultiSelect", width: 360)
    }

    private func store(page: Int) async -> ThreadListStore {
        let b = try! FixtureBackend.staging()
        b.setFolders([("Work", []), ("Family", []), ("Trips", [])])
        let s = ThreadListStore(backend: b)
        await s.loadFolders()
        s.showPage(page)
        return s
    }

    func testPageTitles() async {
        let s = await store(page: 2)
        XCTAssertEqual(s.pageTitle, "Family")
        let home = await store(page: 0)
        XCTAssertEqual(home.pageTitle, "Comms", "the home page is Comms, not Messages")
        home.showNeedsYou()
        XCTAssertEqual(home.pageTitle, "Needs You")
        home.showPage(1)
        XCTAssertEqual(home.pageTitle, "Work", "a page choice leaves Needs You")
        home.showNeedsYou()
        XCTAssertTrue(home.page(by: 1))
        XCTAssertEqual(home.pageTitle, "Work", "⌃⌘→ from Needs You lands back on the folder under it")
    }

    func testUndoBanner() async {
        let b = try! FixtureBackend.staging()
        var t = FixtureMessages.thread(id: "th_u", title: "Bob")
        t.folder = .inbox
        b.setThreads([t])
        let s = ThreadListStore(backend: b)
        await s.load()
        await s.setArchived("th_u", true)
        XCTAssertNotNil(s.undoOffer)
        ListSnapshot.assert(UndoBannerContent(title: s.undoOffer?.title ?? "", undo: {}).frame(maxWidth: .infinity), named: "undoBannerArchived", width: 360)
    }

    #if os(macOS)
    func testMacFolderMenuButton() async {
        let s = await store(page: 1)
        Snapshot.assertHosted(FolderMenuButton(store: s, needsYouCount: 2), named: "macFolderMenuButton", width: 300)
        s.showNeedsYou()
        Snapshot.assertHosted(FolderMenuButton(store: s, needsYouCount: 2), named: "macFolderMenuButtonNeedsYou", width: 300)
    }
    #endif
}
