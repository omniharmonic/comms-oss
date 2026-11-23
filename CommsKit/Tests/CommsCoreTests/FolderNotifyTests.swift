import CommsClient
import CommsCore
import CommsTestSupport
import Foundation
import XCTest

/// Owner request 2026-11-22: notifications by tag type or folder. Each owner folder has
/// Default / All Messages / None, set from Settings › Notifications › Folders or the folder's
/// own menu ("Notifications ▸"); only the changed folder's key is sent.
@MainActor
final class FolderNotifyTests: XCTestCase {
    private func backend() -> FixtureBackend {
        let b = try! FixtureBackend.staging()
        b.setThreads([FixtureMessages.thread(id: "th_0", title: "Person 0")])
        return b
    }

    func testFolderMenuSetsTheRuleAndSendsOnlyThatFolder() async {
        let b = backend()
        let store = ThreadListStore(backend: b)
        await store.loadFolders()
        let work = await store.createFolder(name: "Work")!
        let fam = await store.createFolder(name: "Family")!
        XCTAssertEqual(store.notifyRule(forFolder: work.id), .default)
        await store.setNotifyRule(.all, forFolder: work.id)
        await store.setNotifyRule(.off, forFolder: fam.id)
        XCTAssertEqual(store.notifyRule(forFolder: work.id), .all)
        XCTAssertEqual(store.notifyRule(forFolder: fam.id), .off)
        XCTAssertEqual(b.settingsUpdates.map(\.folders), [[work.id: .all], [fam.id: .off]])
        XCTAssertNil(b.settingsUpdates[0].statuses, "nothing but the folder's key")
        // Back to Default removes the rule on the server.
        await store.setNotifyRule(.default, forFolder: work.id)
        XCTAssertEqual(b.notifySettings.folders, [fam.id: .off])
        XCTAssertEqual(store.notifyRule(forFolder: work.id), .default)
        // Another store (another device) reads the same rules when it loads its folders.
        let other = ThreadListStore(backend: b)
        await other.loadFolders()
        XCTAssertEqual(other.notifyRule(forFolder: fam.id), .off)
    }

    func testSettingsScreenListsFoldersAndEveryStatus() async {
        let b = backend()
        let list = ThreadListStore(backend: b)
        await list.loadFolders()
        let work = await list.createFolder(name: "Work")!
        let store = NotificationSettingsStore(backend: b)
        await store.load()
        XCTAssertEqual(store.folders.map(\.name), ["Work"])
        XCTAssertFalse(store.settings.hidePreviews, "full previews by default")
        store.setFolderRule(work.id, .all)
        store.update { $0.statuses.social = true }
        await store.saveWork?.value
        XCTAssertEqual(b.settingsUpdates.map(\.folders), [[work.id: .all], nil])
        XCTAssertEqual(b.settingsUpdates.last?.statuses, ["social": true])
        XCTAssertEqual(store.folderRule(work.id), .all)
        XCTAssertTrue(b.notifySettings.statuses.social)
    }

    func testAServerWithoutFoldersShowsNoFolderSection() async {
        let b = backend()
        b.setFoldersSupported(false)
        let store = NotificationSettingsStore(backend: b)
        await store.load()
        XCTAssertTrue(store.folders.isEmpty)
    }
}
