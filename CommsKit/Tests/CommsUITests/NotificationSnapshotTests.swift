import CommsClient
import CommsCore
import CommsTestSupport
import SwiftUI
import XCTest
@testable import CommsUI

/// Sprint Task 1: Settings › Notifications and the unread state in the list.
@MainActor
final class NotificationSnapshotTests: XCTestCase {
    override func setUp() async throws {
        ListSamples.seedAvatars()
    }

    private func settings(_ s: CommsNotifySettings, available: CommsNotifyAvailability, folders: [CommsChatFolder] = [], height: CGFloat = 1700,
                          backend: FixtureBackend? = nil) throws -> some View {
        // The screen reloads when it appears: the fixture answers the same settings and folders.
        let b = try backend ?? FixtureBackend()
        b.notifySettings = s
        b.setNotifyAvailability(available)
        let store = NotificationSettingsStore(backend: b, settings: s, available: available, folders: folders)
        return NotificationSettingsView(store: store).frame(height: height)
    }

    /// Every triage tag listed, and a Folders section with each folder's Default / All Messages / None.
    func testSettingsFolderRules() async throws {
        let b = try FixtureBackend()
        var folders: [CommsChatFolder] = []
        for name in ["Work", "Family", "Newsletters"] { folders.append(try await b.createFolder(name: name)) }
        var s = CommsNotifySettings.defaults
        s.statuses.social = true
        s.folders = [folders[0].id: .all, folders[2].id: .off]
        try Snapshot.assertHosted(settings(s, available: CommsNotifyAvailability(push: true, readReceipts: true), folders: folders, height: 2000, backend: b),
                                  named: "notifySettingsFolders", width: 500)
    }

    func testSettingsDefaults() throws {
        try Snapshot.assertHosted(settings(.defaults, available: CommsNotifyAvailability(push: true, readReceipts: true)),
                                  named: "notifySettingsDefaults", width: 500)
    }

    func testSettingsHiddenPreviewsServerOff() throws {
        var s = CommsNotifySettings.defaults
        s.hidePreviews = true
        s.readReceipts = true
        s.networks = ["telegram": false]
        s.statuses.informational = true
        try Snapshot.assertHosted(settings(s, available: CommsNotifyAvailability(push: false, readReceipts: false)),
                                  named: "notifySettingsHiddenServerOff", width: 500)
    }

    func testListUnreadAndRead() {
        let threads = [
            ListSamples.thread("u1", title: "Juniper Vale", avatar: .token("sample-1"), networks: [.telegram],
                               preview: "Can you call me back?", minutesAgo: 3, unread: 2),
            ListSamples.thread("u2", title: "Orin Pell", avatar: .token("sample-4"), networks: [.imessage],
                               preview: "Marked as unread by hand.", minutesAgo: 40, unread: 1),
            ListSamples.thread("u3", title: "Garden Crew", kind: .group, avatar: .monogram("GC", members: []), networks: [.whatsapp],
                               preview: "Read already.", minutesAgo: 90),
        ]
        ListSnapshot.assert(
            SidebarContent(pinned: [], threads: threads, selection: nil, now: ListSamples.now, onSelect: { _ in }, onReachEnd: {}),
            named: "listUnreadAndRead"
        )
    }

    func testReadActionTitlesFollowTheRow() {
        XCTAssertEqual(ThreadRow.accessibilityLabel(for: ListSamples.thread("x", title: "A", avatar: nil, networks: [.sms], preview: "", minutesAgo: 1, unread: 1), time: nil),
                       "A, SMS, 1 unread message")
    }
}
