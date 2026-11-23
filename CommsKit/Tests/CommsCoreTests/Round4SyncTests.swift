import CommsClient
import CommsTestSupport
import Foundation
import PrismModels
@testable import CommsCore
import XCTest

/// Owner-testing round 4: decisions made on one device show on the others (tidy, Omni notes),
/// and the push diagnostics in Notification settings.
@MainActor
final class Round4SyncTests: XCTestCase {
    private func tidyBackend() throws -> FixtureBackend {
        let b = try FixtureBackend()
        b.setThreads([])
        var stranger = FixtureMessages.thread(id: "t_x", title: "+1 555 010 4477")
        stranger.needsTidy = true
        b.upsertThread(stranger)
        return b
    }

    func testATidyDecisionOnAnotherDeviceLeavesPeopleToTidyHere() async throws {
        let b = try tidyBackend()
        b.setTidySuggestions([.init(personId: "p_ann", name: "Ann Lee", reason: "same-name")], threadID: "t_x")
        let here = TidyStore(backend: b)
        here.reloadDelay = .milliseconds(1)
        await here.load()
        XCTAssertEqual(here.people.map(\.threadId), ["t_x"])
        // The Mac links it.
        let mac = TidyStore(backend: b)
        _ = await mac.link(threadID: "t_x", personID: "p_ann")
        // This device sees only the stream event.
        XCTAssertNil(here.apply(CommsEvent(id: "e0", kind: .threadUpdated, payload: ["threadId": "t_x"])), "an ordinary thread update is not a tidy one")
        let reload = try XCTUnwrap(here.apply(CommsEvent(id: "e1", kind: .threadUpdated, payload: ["threadId": "t_x", "reason": "tidy"])))
        // A burst is one reload.
        let again = here.apply(CommsEvent(id: "e2", kind: .threadUpdated, payload: ["threadId": "t_x", "reason": "tidy"]))
        await reload.value
        await again?.value
        XCTAssertTrue(here.people.isEmpty)
        XCTAssertEqual(here.total, 0)
    }

    func testAForegroundReloadPicksUpDecisionsMadeElsewhere() async throws {
        let b = try tidyBackend()
        let here = TidyStore(backend: b)
        here.reloadDelay = .milliseconds(1)
        await here.load()
        XCTAssertEqual(here.people.count, 1)
        _ = await TidyStore(backend: b).ignore(threadID: "t_x")
        XCTAssertEqual(here.people.count, 1, "nothing told this device yet")
        await here.scheduleReload().value
        XCTAssertEqual(here.people.count, 0)
    }

    func testAClosedOmniNoteStaysClosedOnAnotherDevice() async throws {
        let b = try FixtureBackend()
        b.upsertThread(FixtureMessages.thread(id: "th_o", title: "Alex"))
        b.omni.setAvailable(true)
        b.omni.setDelay(.milliseconds(5))
        let phone = OmniStore(backend: b, presence: FixedPresence(true), pollInterval: .milliseconds(10), maxPolls: 50)
        await phone.catchUp(threadID: "th_o")
        await phone.pollSettled("th_o")
        XCTAssertNotNil(phone.reply("th_o"))
        let mac = OmniStore(backend: b, presence: FixedPresence(true), pollInterval: .milliseconds(10), maxPolls: 50)
        await mac.load("th_o")
        XCTAssertNotNil(mac.reply("th_o"))
        // Closed on the phone → remembered by the server.
        await phone.dismissReply("th_o")?.value
        XCTAssertNil(phone.reply("th_o"))
        XCTAssertEqual(b.omni.dismissedNotes.count, 1)
        // The Mac hears it on the stream and refreshes.
        let refresh = try XCTUnwrap(mac.apply(CommsEvent(id: "e1", kind: .threadUpdated, payload: ["threadId": "th_o", "reason": "omni"])))
        await refresh.value
        XCTAssertNil(mac.reply("th_o"))
        // A fresh launch (new store) does not bring it back.
        let relaunch = OmniStore(backend: b, presence: FixedPresence(true), pollInterval: .milliseconds(10), maxPolls: 50)
        await relaunch.load("th_o")
        XCTAssertNil(relaunch.reply("th_o"))
        XCTAssertNil(relaunch.apply(CommsEvent(id: "e2", kind: .threadUpdated, payload: ["threadId": "other", "reason": "omni"])), "a thread not shown here is not loaded")
    }

    func testPushDeviceLinesSayWhatAppleAnswered() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let phone = CommsPushDevice(platform: "ios", environment: "sandbox", thisDevice: true,
                                    lastDelivery: .init(status: 403, reason: "BadEnvironmentKeyInToken", outcome: "failed", at: at))
        XCTAssertEqual(NotificationSettingsStore.deviceName(phone), "This iPhone")
        XCTAssertEqual(NotificationSettingsStore.deliveryText(phone), "Development build · Apple refused the last notification (403 BadEnvironmentKeyInToken)")
        let mac = CommsPushDevice(platform: "macos", environment: "production", thisDevice: false,
                                  lastDelivery: .init(status: 200, reason: "", outcome: "sent", at: at))
        XCTAssertEqual(NotificationSettingsStore.deviceName(mac), "Mac")
        XCTAssertEqual(NotificationSettingsStore.deliveryText(mac), "App Store / Developer ID build · last notification delivered to Apple")
        let fresh = CommsPushDevice(platform: "ios", environment: "production", thisDevice: false)
        XCTAssertEqual(NotificationSettingsStore.deliveryText(fresh), "App Store / Developer ID build · nothing sent yet")
    }

    func testReregisterSendsTheRegistrationAgain() async throws {
        let b = try FixtureBackend()
        let push = CommsPushCenter(environment: .sandbox, platform: .ios)
        push.setBackend(b)
        push.setDeviceToken(Data([1, 2, 3]))
        await push.registration?.value
        push.setDeviceToken(Data([1, 2, 3]))
        await push.registration?.value
        let once = b.pushRegistrationCount
        XCTAssertEqual(once, 1, "the same token is not sent twice")
        push.reregister()
        await push.registration?.value
        XCTAssertEqual(b.pushRegistrationCount, 2, "coming back to the foreground sends it again")
    }
}
