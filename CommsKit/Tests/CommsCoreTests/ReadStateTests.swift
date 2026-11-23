import CommsClient
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

/// Sprint Task 1: mark read on open / while open, presence leases, Mark as Read / Unread,
/// the badge, notification settings and push registration.
@MainActor
final class ReadStateTests: XCTestCase {
    private func thread(_ id: String, unread: Int, status: String = "urgent") -> CommsThread {
        let json: [String: Any] = [
            "id": id, "title": "T \(id)", "titleSource": "contact", "avatar": ["monogram": "T"], "kind": "dm",
            "networks": ["whatsapp"], "lastActivityAt": "2026-11-21T10:00:00.000Z", "unread": ["count": unread, "trusted": true],
            "folder": "inbox", "status": status, "pinned": false, "muted": false, "channels": [[String: Any]](),
        ]
        return try! PrismJSON.decoder().decode(CommsThread.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func make(_ threads: [CommsThread]) async throws -> (ThreadListStore, FixtureBackend) {
        let backend = try FixtureBackend()
        backend.setThreads(threads)
        let store = ThreadListStore(backend: backend, refetchDelay: .milliseconds(1))
        store.badgeDelay = .milliseconds(1)
        await store.load()
        return (store, backend)
    }

    private func unread(_ store: ThreadListStore, _ id: String) -> Int? {
        (store.pinned + store.threads).first { $0.id == id }?.unread.count
    }

    func testOpeningMarksReadWithAViewingLeaseAndClosingDropsIt() async throws {
        let (store, backend) = try await make([thread("a", unread: 3), thread("b", unread: 1)])
        store.openThreadID = "a"
        XCTAssertEqual(unread(store, "a"), 0)
        store.openThreadID = "b"
        store.openThreadID = nil
        await store.readWork?.value
        XCTAssertEqual(backend.readCalls, ["read:a:true", "read:a:false", "read:b:true", "read:b:false"])
    }

    func testBackgroundDropsTheLeaseAndForegroundTakesItAgain() async throws {
        let (store, backend) = try await make([thread("a", unread: 1)])
        store.openThreadID = "a"
        store.appActive = false
        store.appActive = true
        await store.readWork?.value
        XCTAssertEqual(backend.readCalls, ["read:a:true", "read:a:false", "read:a:true"])
    }

    func testAMessageArrivingInTheOpenThreadIsRead_notTheOwnersOwn() async throws {
        let (store, backend) = try await make([thread("a", unread: 0), thread("b", unread: 0)])
        store.openThreadID = "a"
        store.apply(CommsEvent(id: "1", kind: .messageCreated, payload: ["threadId": "a", "message": ["sender": ["isSelf": false]]]))
        store.apply(CommsEvent(id: "2", kind: .messageCreated, payload: ["threadId": "a", "message": ["sender": ["isSelf": true]]]))
        store.apply(CommsEvent(id: "3", kind: .messageCreated, payload: ["threadId": "b", "message": ["sender": ["isSelf": false]]]))
        store.appActive = false
        store.apply(CommsEvent(id: "4", kind: .messageCreated, payload: ["threadId": "a", "message": ["sender": ["isSelf": false]]]))
        await store.readWork?.value
        XCTAssertEqual(backend.readCalls, ["read:a:true", "read:a:true", "read:a:false"])
    }

    func testMarkUnreadKeepsTheDotWhileSelected_andMarkReadClearsIt() async throws {
        let (store, backend) = try await make([thread("a", unread: 2), thread("b", unread: 0)])
        store.openThreadID = "a"
        store.markUnread("a")
        XCTAssertEqual(unread(store, "a"), 1)
        // a refetch while still selected does not clear it, and no read is reported
        store.apply(CommsEvent(id: "9", kind: .messageCreated, payload: ["threadId": "a", "message": ["sender": ["isSelf": false]]]))
        await store.apply(CommsEvent(id: "10", kind: .threadUpdated, payload: ["threadId": "a"])).value
        XCTAssertEqual(unread(store, "a"), 1)
        store.openThreadID = "b" // leaving it does not mark it read either
        await store.readWork?.value
        XCTAssertEqual(backend.readCalls, ["read:a:true", "unread:a", "read:b:true"])
        store.markRead("a")
        XCTAssertEqual(unread(store, "a"), 0)
        store.markUnread("b") // b is the open thread: kept unread while selected
        XCTAssertEqual(unread(store, "b"), 1)
        await store.readWork?.value
        XCTAssertEqual(backend.readCalls.suffix(2), ["read:a:nil:explicit", "unread:b"], "Mark as Read is explicit (D10: receipt where supported)")
    }

    func testBadgeIsTheNeedsAttentionUnreadCount() async throws {
        let (store, _) = try await make([thread("a", unread: 2, status: "urgent"), thread("b", unread: 1, status: "informational"), thread("c", unread: 0, status: "action-required")])
        await store.refreshBadge()
        XCTAssertEqual(store.attentionUnread, 1)
        store.markRead("a")
        await store.refreshBadge()
        XCTAssertEqual(store.attentionUnread, 0)
    }

    func testSettingsStoreSavesInOrderAndKeepsServerKeys() async throws {
        let backend = try FixtureBackend()
        let store = NotificationSettingsStore(backend: backend)
        await store.load()
        XCTAssertEqual(store.settings, .defaults)
        XCTAssertEqual(store.available?.push, true)
        store.update { $0.hidePreviews = true }
        store.setNotifies(.telegram, false)
        store.setNotifies(.telegram, true)
        await store.saveWork?.value
        XCTAssertEqual(backend.settingsUpdates.count, 3)
        XCTAssertEqual(backend.settingsUpdates[0], { var p = CommsNotifySettingsPatch(); p.hidePreviews = true; return p }(), "only the changed key")
        XCTAssertEqual(backend.settingsUpdates.last?.networks, ["telegram": true], "explicit true: the server merges maps")
        XCTAssertTrue(store.settings.hidePreviews)
        XCTAssertNil(store.error)
    }

    func testSettingsStoreRevertsAFailedSave() async throws {
        struct Failing: ChatBackend {
            func capabilities() async throws -> CommsCapabilities { FixtureBackend.validCapabilities }
            func threads(_ q: CommsThreadQuery) async throws -> CommsThreadPage { throw CommsError.clientScope }
            func thread(id: String) async throws -> CommsThreadDetail { throw CommsError.threadUnavailable }
            func messages(threadID: String, before: String?, limit: Int) async throws -> CommsMessagePage { throw CommsError.threadUnavailable }
            func mediaURL(token: String) -> URL { URL(string: "https://x.invalid")! }
            func media(token: String) async throws -> (Data, String) { throw CommsError.mediaExpired }
            func events(lastEventID: String?) -> AsyncThrowingStream<CommsEvent, Error> { AsyncThrowingStream { $0.finish() } }
            func updateNotificationSettings(_ patch: CommsNotifySettingsPatch) async throws -> CommsNotifySettingsResponse { throw CommsError.clientScope }
        }
        let store = NotificationSettingsStore(backend: Failing())
        await store.load()
        store.update { $0.readReceipts = true }
        XCTAssertTrue(store.settings.readReceipts)
        await store.saveWork?.value
        XCTAssertFalse(store.settings.readReceipts, "back to what the server has")
        XCTAssertNotNil(store.error)
    }

    /// Review I4: a settings screen loaded earlier never undoes another device's change.
    func testAStaleScreenDoesNotUndoAnotherDevicesChange() async throws {
        let backend = try FixtureBackend()
        let mac = NotificationSettingsStore(backend: backend)
        await mac.load() // loaded hours ago: hidePreviews false
        let phone = NotificationSettingsStore(backend: backend)
        await phone.load()
        phone.update { $0.hidePreviews = true }
        await phone.saveWork?.value
        mac.update { $0.statuses.informational = true } // an unrelated change on the stale screen
        await mac.saveWork?.value
        XCTAssertTrue(backend.notifySettings.hidePreviews, "the phone's Hide Previews survives")
        XCTAssertTrue(backend.notifySettings.statuses.informational)
        XCTAssertTrue(mac.settings.hidePreviews, "and the stale screen now shows the server's merged settings")
    }

    /// Review I3: the Mac reads a thread only when frontmost, key and recently used.
    func testReadingPresencePolicy() async throws {
        XCTAssertTrue(ReadingPresence.isReading(appActive: true, windowKey: true, idleSeconds: 5))
        XCTAssertFalse(ReadingPresence.isReading(appActive: false, windowKey: true, idleSeconds: 5), "another app is frontmost")
        XCTAssertFalse(ReadingPresence.isReading(appActive: true, windowKey: false, idleSeconds: 5), "another window is key")
        XCTAssertFalse(ReadingPresence.isReading(appActive: true, windowKey: true, idleSeconds: 600), "nobody at the Mac")
        // and while not reading the store holds no lease and leaves arrivals unread
        let (store, backend) = try await make([thread("a", unread: 0)])
        store.leaseInterval = .milliseconds(20)
        store.openThreadID = "a"
        store.appActive = false
        try await Task.sleep(for: .milliseconds(120))
        store.apply(CommsEvent(id: "1", kind: .messageCreated, payload: ["threadId": "a", "message": ["sender": ["isSelf": false]]]))
        await store.readWork?.value
        XCTAssertEqual(backend.readCalls, ["read:a:true", "read:a:false"], "no renewals and no reads while away")
    }

    func testPushCenterRegistersOnceBothTokenAndBackendAreKnown_andRoutesTaps() async throws {
        let backend = try FixtureBackend()
        let center = CommsPushCenter(environment: .sandbox, platform: .ios)
        center.setDeviceToken(Data([1, 2, 3]))
        XCTAssertEqual(backend.pushRegistrationCount, 0)
        center.setBackend(backend)
        await center.registration?.value
        XCTAssertEqual(backend.pushRegistrationCount, 1)
        XCTAssertEqual(center.serverPushEnabled, true)
        center.setDeviceToken(Data([1, 2, 3]))
        await center.registration?.value
        XCTAssertEqual(backend.pushRegistrationCount, 1, "the same token is not registered twice")
        center.handleTap(userInfo: ["type": "comms.message", "threadId": "th_1"])
        XCTAssertEqual(center.pendingThreadID, "th_1")
        center.pendingThreadID = nil
        center.handleTap(userInfo: ["type": "other", "threadId": "th_2"])
        XCTAssertNil(center.pendingThreadID)
        // no entitlement → never registers
        let unsigned = CommsPushCenter(environment: nil, platform: .macos)
        unsigned.setBackend(backend)
        unsigned.setDeviceToken(Data([9]))
        XCTAssertNil(unsigned.registration)
    }

    func testProvisioningProfileEnvironment() {
        func profile(_ env: String) -> Data {
            Data("garbage-cms<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Entitlements</key><dict><key>aps-environment</key><string>\(env)</string></dict></dict></plist>trailer".utf8)
        }
        XCTAssertEqual(PushEnvironment.fromProvisioningProfile(profile("development")), .sandbox)
        XCTAssertEqual(PushEnvironment.fromProvisioningProfile(profile("production")), .production)
        XCTAssertNil(PushEnvironment.fromProvisioningProfile(Data("no plist".utf8)))
        #if os(macOS)
        XCTAssertNil(PushEnvironment.current(), "the test runner has no push entitlement")
        #endif
    }
}
