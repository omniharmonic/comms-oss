import CommsClient
import CommsCore
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

/// Sprint Task 9: Mute / Archive / Status from a row (optimistic, rolled back on failure, undo),
/// owner folders (create / rename / reorder / delete, membership, multi-select), the pages the
/// list swipes through, and the filter of a folder page.
@MainActor
final class RowActionsFolderTests: XCTestCase {
    private func backend(_ count: Int = 4) -> FixtureBackend {
        let b = try! FixtureBackend.staging()
        b.setFiltersThreadQuery(true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var threads: [CommsThread] = []
        for i in 0..<count {
            var t = FixtureMessages.thread(id: "th_\(i)", title: "Person \(i)")
            t.lastActivityAt = now.addingTimeInterval(TimeInterval(-60 * i))
            t.status = .informational
            threads.append(t)
        }
        b.setThreads(threads)
        return b
    }

    func testMuteTogglesAndRollsBack() async {
        let b = backend()
        let store = ThreadListStore(backend: b)
        await store.load()
        XCTAssertEqual(store.rowActions, .all)
        await store.toggleMute("th_1")
        XCTAssertEqual(store.threads.first { $0.id == "th_1" }?.muted, true)
        await store.toggleMute("th_1")
        XCTAssertEqual(store.threads.first { $0.id == "th_1" }?.muted, false)
        b.setRowError(CommsError.threadActionsDisabled)
        await store.toggleMute("th_1")
        XCTAssertEqual(store.threads.first { $0.id == "th_1" }?.muted, false, "rolled back")
        XCTAssertNotNil(store.actionNotice)
        XCTAssertEqual(b.rowCalls, ["mute:th_1:true", "mute:th_1:false", "mute:th_1:true"])
    }

    func testArchiveLeavesTheListAndUndoBringsItBack() async {
        let b = backend()
        let store = ThreadListStore(backend: b)
        await store.load()
        await store.setArchived("th_2", true)
        XCTAssertFalse(store.threads.contains { $0.id == "th_2" })
        XCTAssertEqual(store.undoOffer?.kind, .archive(threadID: "th_2"))
        await store.undo()
        XCTAssertNil(store.undoOffer)
        XCTAssertEqual(store.threads.map(\.id), ["th_0", "th_1", "th_2", "th_3"], "back in its place")
        XCTAssertEqual(b.rowCalls, ["archive:th_2:true", "archive:th_2:false"])
        // A failed archive keeps the row.
        b.setRowError(CommsError.threadActionsDisabled)
        await store.setArchived("th_0", true)
        XCTAssertTrue(store.threads.contains { $0.id == "th_0" })
        XCTAssertNil(store.undoOffer)
    }

    func testStatusChangeAndUndo() async {
        let b = backend()
        let store = ThreadListStore(backend: b)
        await store.load()
        await store.setStatus("th_0", .urgent)
        XCTAssertEqual(store.threads.first?.status, .urgent)
        guard case .status(let id, _)? = store.undoOffer?.kind else { return XCTFail("undo offered") }
        XCTAssertEqual(id, "th_0")
        await store.undo()
        XCTAssertEqual(store.threads.first?.status, .informational)
        // The same status again asks nothing.
        await store.setStatus("th_0", .informational)
        XCTAssertEqual(b.rowCalls, ["status:th_0:urgent", "undo:th_0"])
        // An iMessage thread without a vault note: refused, put back, said.
        var bb = FixtureMessages.thread(id: "th_bb", title: "Phone", network: "imessage")
        bb.status = .informational
        b.upsertThread(bb)
        await store.load()
        await store.setStatus("th_bb", .handled)
        XCTAssertEqual(store.threads.first { $0.id == "th_bb" }?.status, .informational)
        XCTAssertEqual(store.actionNotice, "This conversation has no status to change.")
    }

    func testFoldersPagesAndMembership() async {
        let b = backend()
        let store = ThreadListStore(backend: b)
        await store.loadFolders()
        await store.load()
        XCTAssertTrue(store.canUseFolders)
        XCTAssertEqual(store.pages, [nil])
        let work = await store.createFolder(name: "  Work ")
        XCTAssertEqual(work?.name, "Work")
        let fam = await store.createFolder(name: "Family")
        XCTAssertEqual(store.pages, [nil, work!.id, fam!.id])
        let dup = await store.createFolder(name: "work")
        XCTAssertNil(dup, "names are unique")
        XCTAssertEqual(store.actionNotice, "There is already a folder called “work”.")
        store.dismissActionNotice()
        // Add two (multi-select), then page to the folder: only they show.
        store.isSelecting = true
        store.toggleSelected("th_1")
        store.toggleSelected("th_3")
        XCTAssertEqual(store.actionTargets(for: "th_1"), ["th_1", "th_3"])
        XCTAssertEqual(store.actionTargets(for: "th_0"), ["th_0"])
        await store.add(store.actionTargets(for: "th_1"), toFolder: work!.id)
        store.isSelecting = false
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertTrue(store.isInFolder("th_1", work!.id))
        XCTAssertTrue(store.page(by: 1))
        XCTAssertEqual(store.filter.chatFolder, work!.id)
        XCTAssertEqual(store.currentFolder?.name, "Work")
        await store.loadTask?.value
        XCTAssertEqual(store.threads.map(\.id), ["th_1", "th_3"])
        XCTAssertEqual(b.threadQueries.last?.inFolder, work!.id)
        XCTAssertEqual(b.threadQueries.last?.anyFolder, true)
        // Removing on the folder page drops the row at once.
        await store.remove(["th_3"], fromFolder: work!.id)
        XCTAssertEqual(store.threads.map(\.id), ["th_1"])
        // Paging stops at the ends.
        XCTAssertTrue(store.page(by: 1))
        XCTAssertFalse(store.page(by: 1))
        store.showPage(0)
        XCTAssertNil(store.filter.chatFolder)
        XCTAssertFalse(store.page(by: -1))
        // Rename, reorder, delete (the open page falls back to the home page).
        await store.renameFolder(work!.id, to: "Job")
        XCTAssertEqual(store.folders.map(\.name), ["Job", "Family"])
        await store.moveFolder(fam!.id, to: 0)
        XCTAssertEqual(store.folders.map(\.name), ["Family", "Job"])
        store.showPage(2)
        await store.deleteFolder(work!.id)
        XCTAssertNil(store.filter.chatFolder)
        XCTAssertEqual(store.folders.map(\.name), ["Family"])
    }

    func testFolderEventsRefetchFoldersAndADeletedPageFallsBack() async {
        let b = backend()
        let store = ThreadListStore(backend: b)
        b.setFolders([("Work", ["th_0"])])
        await store.loadFolders()
        store.showPage(1)
        await store.loadTask?.value
        XCTAssertEqual(store.threads.map(\.id), ["th_0"])
        // Another device deletes it.
        try? await b.deleteFolder(id: store.folders[0].id)
        await store.apply(CommsEvent(id: "e1", kind: .threadUpdated, payload: .object(["threadId": .null, "reason": .string("folders")]))).value
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertNil(store.filter.chatFolder)
    }

    func testAServerWithoutFoldersOrActionsOffersNone() async {
        let b = backend()
        b.setFoldersSupported(false)
        b.setRowActions([])
        let store = ThreadListStore(backend: b)
        await store.loadFolders()
        XCTAssertFalse(store.canUseFolders)
        XCTAssertEqual(store.rowActions, [])
        XCTAssertEqual(store.pages, [nil])
        XCTAssertFalse(b.rowCalls.contains("folders"), "never asked")
    }

    func testFolderPageFilterAdmits() {
        var f = FilterState()
        f.chatFolder = "cf_1"
        var t = FixtureMessages.thread(id: "a", title: "A")
        XCTAssertFalse(f.admits(t))
        t.folderIds = ["cf_1"]
        XCTAssertTrue(f.admits(t))
        t.folder = .low
        XCTAssertTrue(f.admits(t), "a folder spans system folders")
        t.folder = .archived
        XCTAssertFalse(f.admits(t), "but not Archived")
        let q = f.query()
        XCTAssertEqual(q.inFolder, "cf_1")
        XCTAssertTrue(q.anyFolder)
        XCTAssertNil(FilterState().query().inFolder)
    }
}
