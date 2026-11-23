import CommsClient
@testable import CommsCore
import CommsTestSupport
import Foundation
import XCTest

/// Phase 2a "people": triage filters, contact cards with shared conversations, call menus.
@MainActor
final class PeopleTests: XCTestCase {
    // MARK: CallRoutes

    private func urls(_ o: [CallOption]) -> [String] { o.map(\.url.absoluteString) }

    func testPhonesAndEmailsInContractOrder() {
        let c = CommsContact(phones: [.init(label: "mobile", value: "+1 (555) 010-2233")], emails: [.init(value: "maya@example.test")])
        let o = CallRoutes.options(contact: c)
        XCTAssertEqual(urls(o), [
            "facetime-audio://+15550102233", "facetime://+15550102233", "tel:+15550102233",
            "facetime-audio://maya@example.test", "facetime://maya@example.test",
        ])
        XCTAssertEqual(o.map(\.title), ["FaceTime Audio", "FaceTime", "Phone", "FaceTime Audio", "FaceTime"])
        XCTAssertEqual(o.map(\.kind), [.audio, .video, .audio, .audio, .video])
        XCTAssertEqual(o[0].detail, "+15550102233")
        XCTAssertEqual(CallRoutes.mail(contact: c)?.absoluteString, "mailto:maya@example.test")
    }

    func testEachNetworkDeepLink() {
        func app(_ network: CommsNetwork, _ value: String, _ kind: CommsHandleKind) -> String? {
            CallRoutes.options(contact: CommsContact(handles: [.init(network: network, value: value, kind: kind)])).first.map(\.url.absoluteString)
        }
        XCTAssertEqual(app(.whatsapp, "+15550001", .phone), "https://wa.me/15550001")
        XCTAssertEqual(app(.signal, "+15550001", .phone), "https://signal.me/#p/+15550001")
        XCTAssertEqual(app(.telegram, "@alice_example", .username), "tg://resolve?domain=alice_example")
        XCTAssertEqual(app(.telegram, "+15550001", .phone), "tg://resolve?phone=15550001")
        XCTAssertEqual(app(.telegram, "123456789", .userId), "tg://user?id=123456789")
        XCTAssertEqual(app(.slack, "T0ABC-U0XYZ", .userId), "slack://user?team=T0ABC&id=U0XYZ")
        XCTAssertEqual(app(.x, "783214", .userId), "https://x.com/messages/compose?recipient_id=783214")
        // No documented link to a person: nothing offered.
        XCTAssertNil(app(.discord, "80351110224678912", .userId))
        XCTAssertNil(app(.messenger, "100004", .userId))
        XCTAssertNil(app(.x, "jack", .username))
        XCTAssertNil(app(.unknown("instagram"), "someone", .username))
        // Every app option is titled for its app and sits in both menus, after the calls.
        let o = CallRoutes.options(contact: CommsContact(phones: [.init(value: "+15550001")], handles: [.init(network: .whatsapp, value: "+15550001", kind: .phone)]))
        XCTAssertEqual(o.last?.title, "Open in WhatsApp")
        XCTAssertEqual(CallRoutes.audio(o).map(\.title), ["FaceTime Audio", "Phone", "Open in WhatsApp"])
        XCTAssertEqual(CallRoutes.video(o).map(\.title), ["FaceTime", "Open in WhatsApp"])
    }

    func testInstagramAndLinkedInLinks() {
        func app(_ network: CommsNetwork, _ value: String, _ kind: CommsHandleKind) -> CallOption? {
            CallRoutes.options(contact: CommsContact(handles: [.init(network: network, value: value, kind: kind)])).first
        }
        XCTAssertEqual(app(.instagram, "@maya.okafor_", .username)?.url.absoluteString, "https://ig.me/m/maya.okafor_")
        XCTAssertEqual(app(.instagram, "@maya.okafor_", .username)?.title, "Open in Instagram")
        XCTAssertEqual(app(.linkedin, "maya-okafor-1a2b", .username)?.url.absoluteString, "https://www.linkedin.com/in/maya-okafor-1a2b")
        XCTAssertEqual(app(.linkedin, "maya-okafor-1a2b", .username)?.title, "Open in LinkedIn")
        // A bridge's numeric / URN ids are not public profiles: nothing.
        XCTAssertNil(app(.instagram, "17841400000000000", .userId))
        XCTAssertNil(app(.linkedin, "ACoAAB12345", .userId))
        XCTAssertNil(app(.linkedin, "a/b", .username))
        XCTAssertNil(app(.instagram, "bad name", .username))
        XCTAssertTrue(CallLinks.isAllowed(URL(string: "https://ig.me/m/x")!))
        XCTAssertTrue(CallLinks.isAllowed(URL(string: "https://www.linkedin.com/in/maya")!))
        XCTAssertFalse(CallLinks.isAllowed(URL(string: "https://linkedin.com.evil.test/in/x")!))
        XCTAssertEqual(CommsNetwork(wire: "instagram").displayName, "Instagram")
        XCTAssertEqual(CommsNetwork(wire: "linkedin").displayName, "LinkedIn")
        XCTAssertTrue(FilterState(networks: [.instagram]).admits({
            var t = FixtureMessages.thread(id: "i", title: "i", network: "instagram"); t.status = nil; return t
        }()))
    }

    func testHostileOrMalformedValuesOfferNothing() {
        let c = CommsContact(
            phones: [.init(value: "12"), .init(value: "+1555abc0100"), .init(value: "+15550100;evil")],
            emails: [.init(value: "not-an-email"), .init(value: "a@b.test?cc=x")],
            handles: [
                .init(network: .telegram, value: "@a/b", kind: .username),
                .init(network: .slack, value: "T1-U1-X", kind: .userId),
                .init(network: .slack, value: "../x", kind: .userId),
                .init(network: .x, value: "12;3", kind: .userId),
                .init(network: .whatsapp, value: "+1", kind: .phone),
            ])
        XCTAssertEqual(CallRoutes.options(contact: c), [])
        XCTAssertNil(CallRoutes.mail(contact: c))
        XCTAssertEqual(CallRoutes.options(contact: nil), [])
        XCTAssertEqual(CallRoutes.options(contact: CommsContact()), [], "empty contact: the buttons hide")
    }

    func testHandlesOnTheConversationsNetworksComeFirstAndDuplicatesCollapse() {
        let c = CommsContact(phones: [.init(value: "+15550001"), .init(label: "WhatsApp", value: "+15550001")],
                             handles: [.init(network: .whatsapp, value: "+15550001", kind: .phone),
                                       .init(network: .telegram, value: "@alice_example", kind: .username)])
        let o = CallRoutes.options(contact: c, networks: [.telegram])
        XCTAssertEqual(o.filter { $0.kind == .app }.map(\.title), ["Open in Telegram", "Open in WhatsApp"])
        XCTAssertEqual(o.filter { $0.kind != .app }.count, 3, "the same number twice offers its calls once")
    }

    func testCallLinksAllowlistIsShapeExact() {
        for ok in ["tel:+15550001", "facetime://+15550001", "facetime-audio://a@b.test", "tg://resolve?domain=alice_example",
                   "tg://resolve?phone=15550001", "tg://user?id=42", "slack://user?team=T0ABC&id=U0XYZ", "mailto:a@b.test",
                   "https://wa.me/15550001", "https://signal.me/#p/+15550001", "https://x.com/messages/compose?recipient_id=1",
                   "https://ig.me/m/maya.o", "https://www.linkedin.com/in/maya-okafor"] {
            XCTAssertTrue(CallLinks.isAllowed(URL(string: ok)!), ok)
        }
        for no in ["http://wa.me/15550001", "https://evil.test/", "https://wa.me.evil.test/15550001", "https://user@wa.me/15550001",
                   "https://wa.me:8443/15550001", "https://wa.me/15550001?text=hi", "file:///etc/passwd", "sms:15550001",
                   "javascript:alert(1)", "whatsapp://send?phone=1", "smb://x",
                   // Right scheme, wrong shape (M1).
                   "tg://msg?text=hi", "tg://resolve?domain=alice_example&text=hi", "slack://open", "slack://channel?team=T1&id=C1",
                   "mailto:a@b.test?body=hi", "mailto:a%40b@x.test", "tel:+15550001;ext=2", "tel:15550001", "tel:+0044791000000",
                   "facetime://+1555", "https://x.com/elonmusk", "https://www.linkedin.com/feed/"] {
            XCTAssertFalse(CallLinks.isAllowed(URL(string: no)!), no)
        }
        // Everything CallRoutes builds is allowed.
        for o in CallRoutes.options(contact: sampleContact()) { XCTAssertTrue(CallLinks.isAllowed(o.url), o.url.absoluteString) }
    }

    func testTrailingNewlinesLeadingZeroAndPercentAreRefused() {
        let c = CommsContact(
            phones: [.init(value: "0044791000000"), .init(value: "+0044791000000"), .init(value: "+15550001\n")],
            emails: [.init(value: "a%40b@x.test"), .init(value: "a@b.co\n")],
            handles: [.init(network: .slack, value: "T0A-U1\n", kind: .userId),
                      .init(network: .telegram, value: "@alice_example\n", kind: .username),
                      .init(network: .instagram, value: "maya\n", kind: .username),
                      .init(network: .linkedin, value: "maya-okafor\n", kind: .username)])
        XCTAssertEqual(CallRoutes.options(contact: c).map(\.url.absoluteString), [], "M2/M3/M4")
        XCTAssertNil(CallRoutes.mail(contact: c))
    }

    /// I1: Details unions the thread's own contact with the person's, so a person whose page
    /// lacks the DM counterpart's ghost facts (or is empty) never takes options away.
    func testMergedContactNeverShrinksTheOptions() {
        let thread = CommsContact(phones: [.init(label: "WhatsApp", value: "+15550001")],
                                  handles: [.init(network: .whatsapp, value: "+15550001", kind: .phone)])
        let before = CallRoutes.options(contact: thread)
        XCTAssertEqual(CallRoutes.options(contact: thread.merged(with: CommsContact())), before, "an empty person contact")
        let partial = CommsContact(phones: [.init(label: "mobile", value: "+1 555 0001")], emails: [.init(value: "a@example.test")],
                                   handles: [.init(network: .telegram, value: "@alice_example", kind: .username)])
        let merged = thread.merged(with: partial)
        XCTAssertEqual(merged.phones.count, 1, "the same number written differently is one phone")
        XCTAssertEqual(merged.emails.map(\.value), ["a@example.test"])
        XCTAssertEqual(Set(merged.handles.map(\.network)), [.whatsapp, .telegram])
        let after = CallRoutes.options(contact: merged)
        XCTAssertTrue(Set(before.map(\.id)).isSubset(of: Set(after.map(\.id))))
        XCTAssertEqual(thread.merged(with: nil), thread)
    }

    func testUnknownStatusFromTheServerIsNeverAdmittedByAStatusFilter() {
        var t = FixtureMessages.thread(id: "f", title: "f")
        t.status = .unknown("snoozed")
        for choice in TriageFilter.menu { XCTAssertFalse(FilterState(triage: choice).admits(t), choice.label) }
        XCTAssertTrue(FilterState().admits(t), "no status filter: shown")
    }

    private func sampleContact() -> CommsContact {
        CommsContact(phones: [.init(value: "+15550001")], emails: [.init(value: "a@example.test")],
                     handles: [.init(network: .whatsapp, value: "+15550001", kind: .phone), .init(network: .signal, value: "+15550001", kind: .phone),
                               .init(network: .telegram, value: "@alice_example", kind: .username), .init(network: .slack, value: "T1A-U2B", kind: .userId),
                               .init(network: .x, value: "42", kind: .userId)])
    }

    // MARK: FilterState

    private func thread(_ id: String, status: String?, network: String = "whatsapp", folder: String = "inbox") -> CommsThread {
        var t = FixtureMessages.thread(id: id, title: id, network: network)
        t.status = status.map(CommsThreadStatus.init(wire:))
        t.folder = CommsFolder(wire: folder)
        return t
    }

    func testTriageFilterQueryAndAdmits() {
        XCTAssertEqual(FilterState(triage: .needsAttention).query(), CommsThreadQuery(attention: true))
        XCTAssertEqual(FilterState(unread: true, networks: [.telegram], triage: .status(.handled)).query(),
                       CommsThreadQuery(unreadOnly: true, networks: [.telegram], statuses: [.handled]))
        XCTAssertTrue(FilterState(triage: .status(.low)).isFiltering)

        let attention = FilterState(triage: .needsAttention)
        XCTAssertTrue(attention.admits(thread("u", status: "urgent")))
        XCTAssertTrue(attention.admits(thread("a", status: "action-required")))
        XCTAssertFalse(attention.admits(thread("i", status: "informational")))
        XCTAssertFalse(attention.admits(thread("n", status: nil)), "no status from an older server: not admitted")
        let social = FilterState(networks: [.telegram], triage: .status(.social))
        XCTAssertTrue(social.admits(thread("s", status: "social", network: "telegram")))
        XCTAssertFalse(social.admits(thread("s", status: "social", network: "whatsapp")), "stacks with networks")
        XCTAssertFalse(FilterState(triage: .status(.social)).admits(thread("s", status: "social", folder: "archived")), "keeps the folder")
        XCTAssertFalse(FilterState(triage: .status(.social)).admits(thread("f", status: "snoozed")))
    }

    // MARK: Multi-select (phase 2b C2)

    func testStatusesAndNetworksAreMultiSelect() {
        var f = FilterState()
        f.set(.status(.urgent), true)
        f.set(.status(.social), true)
        f.set(.whatsapp, true)
        f.set(.telegram, true)
        XCTAssertEqual(f.statuses, [.urgent, .social])
        XCTAssertEqual(f.query(), CommsThreadQuery(networks: [.telegram, .whatsapp], statuses: [.urgent, .social]))
        XCTAssertTrue(f.admits(thread("u", status: "urgent", network: "telegram")))
        XCTAssertTrue(f.admits(thread("s", status: "social", network: "whatsapp")))
        XCTAssertFalse(f.admits(thread("i", status: "informational", network: "whatsapp")), "status not chosen")
        XCTAssertFalse(f.admits(thread("u2", status: "urgent", network: "signal")), "network not chosen")
        XCTAssertFalse(f.isOn(.needsAttention), "only one of its two statuses")

        f.set(.needsAttention, true)
        XCTAssertTrue(f.isOn(.needsAttention))
        XCTAssertTrue(f.isOn(.status(.actionRequired)), "the preset turns on both statuses")
        XCTAssertEqual(f.query(), CommsThreadQuery(networks: [.telegram, .whatsapp], statuses: [.social], attention: true),
                       "the preset pair goes as attention=true, the rest as status=")
        f.set(.status(.urgent), false)
        XCTAssertFalse(f.isOn(.needsAttention), "a member off: the preset is off")
        XCTAssertEqual(f.query().statuses, [.actionRequired, .social])
        f.set(.needsAttention, false)
        XCTAssertEqual(f.statuses, [.social])
        f.set(.telegram, false)
        XCTAssertEqual(f.networks, [.whatsapp])

        f.clearFilters()
        XCTAssertFalse(f.isFiltering)
        XCTAssertEqual(f.folder, .inbox, "clearing keeps the folder")
    }

    func testLiveUpsertsRespectMultipleStatuses() async throws {
        let backend = try FixtureBackend(capabilities: .success(FixtureBackend.validCapabilities))
        backend.setFiltersThreadQuery(true)
        for t in [thread("a", status: "urgent"), thread("b", status: "social"), thread("c", status: "informational")] { backend.upsertThread(t) }
        let store = ThreadListStore(backend: backend, refetchDelay: .milliseconds(1))
        store.filter = FilterState(statuses: [.urgent, .social])
        await store.loadTask?.value
        XCTAssertEqual(Set(store.threads.map(\.id)), ["a", "b"], "the server query carries both statuses")
        backend.upsertThread(thread("c", status: "social"))
        await store.apply(CommsEvent(id: "e1", kind: .threadUpdated, payload: ["threadId": "c"])).value
        XCTAssertEqual(Set(store.threads.map(\.id)), ["a", "b", "c"])
        backend.upsertThread(thread("a", status: "handled"))
        await store.apply(CommsEvent(id: "e2", kind: .threadUpdated, payload: ["threadId": "a"])).value
        XCTAssertEqual(Set(store.threads.map(\.id)), ["b", "c"])
    }

    func testMenuAndSummary() {
        XCTAssertEqual(TriageFilter.menu.map(\.label), ["Needs attention", "Urgent", "Action required", "Needs triage",
                                                        "Informational", "Low priority", "Social", "Handled"])
        XCTAssertNil(FilterState().summary(networkName: \.displayName))
        XCTAssertNil(FilterState(folder: .spam).summary(networkName: \.displayName))
        XCTAssertEqual(FilterState(unread: true, networks: [.whatsapp, .telegram], triage: .status(.urgent)).summary(networkName: \.displayName),
                       "Urgent, Unread, Telegram, WhatsApp")
    }

    func testLiveUpsertsRespectTheTriageFilter() async throws {
        let backend = try FixtureBackend(capabilities: .success(FixtureBackend.validCapabilities))
        backend.setFiltersThreadQuery(true)
        for t in [thread("t_urgent", status: "urgent"), thread("t_info", status: "informational")] { backend.upsertThread(t) }
        let store = ThreadListStore(backend: backend, refetchDelay: .milliseconds(1))
        store.filter = FilterState(triage: .needsAttention)
        await store.loadTask?.value
        XCTAssertEqual(store.threads.map(\.id), ["t_urgent"])

        // The informational thread becomes urgent: it joins; the urgent one is handled: it leaves.
        backend.upsertThread(thread("t_info", status: "urgent"))
        await store.apply(CommsEvent(id: "e1", kind: .threadUpdated, payload: ["threadId": "t_info"])).value
        XCTAssertEqual(Set(store.threads.map(\.id)), ["t_urgent", "t_info"])
        backend.upsertThread(thread("t_urgent", status: "handled"))
        await store.apply(CommsEvent(id: "e2", kind: .threadUpdated, payload: ["threadId": "t_urgent"])).value
        XCTAssertEqual(store.threads.map(\.id), ["t_info"])
    }

    func testStatusBurstWithoutAThreadReloadsTheList() async throws {
        let backend = try FixtureBackend(capabilities: .success(FixtureBackend.validCapabilities))
        backend.setFiltersThreadQuery(true)
        backend.upsertThread(thread("t1", status: "informational"))
        let store = ThreadListStore(backend: backend, refetchDelay: .milliseconds(1))
        store.filter = FilterState(triage: .needsAttention)
        await store.loadTask?.value
        XCTAssertEqual(store.threads.map(\.id), [])
        backend.upsertThread(thread("t1", status: "urgent"))
        await store.apply(CommsEvent(id: "e9", kind: .threadUpdated, payload: ["threadId": .null, "reason": "status"])).value
        XCTAssertEqual(store.threads.map(\.id), ["t1"])
    }

    // MARK: People + demo

    func testDemoPersonListsEveryConversationSharedWithThem() async throws {
        let backend = try DemoBackend.make()
        let store = PersonStore(backend: backend, personID: DemoPeople.alice)
        await store.load()
        let alice = try XCTUnwrap(store.person)
        XCTAssertEqual(alice.name, "Alice Example")
        XCTAssertEqual(Set(alice.threads.map(\.id)), ["th_stg2", "th_demo_alice_tg", "th_stg1"], "her DMs on two networks and the group she is in")
        XCTAssertEqual(alice.threads.map(\.lastActivityAt), alice.threads.map(\.lastActivityAt).sorted(by: >), "newest first")
        XCTAssertFalse(store.sharedThreads(except: "th_stg2").contains { $0.id == "th_stg2" })
        XCTAssertFalse(CallRoutes.options(contact: alice.contact).isEmpty)

        let missing = PersonStore(backend: backend, personID: "p_nobody")
        await missing.load()
        XCTAssertNil(missing.person)
        XCTAssertEqual(missing.error, "This contact is no longer available.")
    }

    func testDemoTimelineCarriesTheContactAndMembersResolveToPeople() async throws {
        let backend = try DemoBackend.make()
        let dm = TimelineStore(backend: backend, threadID: DemoBackend.aliceThreadID)
        await dm.loadLatest()
        XCTAssertEqual(dm.contact?.phones.first?.value, "+15550001")
        XCTAssertEqual(dm.thread?.personId, DemoPeople.alice)
        let group = TimelineStore(backend: backend, threadID: "th_demo_climbers")
        await group.loadLatest()
        XCTAssertNil(group.contact)
        XCTAssertEqual(group.members.compactMap(\.personId).count, 3)
    }

    func testEveryStatusChoiceShowsSomethingInTheDemo() async throws {
        let backend = try DemoBackend.make()
        for choice in TriageFilter.menu {
            let page = try await backend.threads(FilterState(triage: choice).query())
            XCTAssertFalse(page.threads.isEmpty, choice.label)
            XCTAssertTrue(page.threads.allSatisfy { choice.admits($0.status) }, choice.label)
        }
        let people = try await backend.threads(CommsThreadQuery(person: DemoPeople.maya, anyFolder: true)).threads
        XCTAssertEqual(Set(people.map(\.id)), ["th_demo_maya", "th_demo_maya_wa", "th_demo_climbers"])
    }
}
