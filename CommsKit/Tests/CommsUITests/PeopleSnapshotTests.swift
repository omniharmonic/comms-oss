import CommsClient
import CommsCore
import CommsTestSupport
import SwiftUI
import XCTest
@testable import CommsUI

/// Contact cards (Details for a DM and a group, a member's card) and the Filter state.
/// Compared on macOS; on iOS the same views are rendered as a smoke test (see `Snapshot`).
@MainActor
final class PeopleSnapshotTests: XCTestCase {
    private struct Data {
        var alice: CommsThread
        var aliceContact: CommsContact
        var aliceShared: [CommsThread]
        var climbers: CommsThread
        var climbersMembers: [CommsMember]
        var maya: CommsPerson
    }

    private func data() async throws -> Data {
        let backend = try DemoBackend.make()
        let dm = try await backend.thread(id: DemoBackend.aliceThreadID)
        let alice = try await backend.person(id: DemoPeople.alice)
        let group = try await backend.thread(id: "th_demo_climbers")
        let maya = try await backend.person(id: DemoPeople.maya)
        return Data(alice: dm.thread, aliceContact: try XCTUnwrap(dm.contact), aliceShared: alice.threads.filter { $0.id != dm.thread.id },
                    climbers: group.thread, climbersMembers: group.members, maya: maya)
    }

    #if os(macOS)
    private let width: CGFloat = 300
    #else
    private let width: CGFloat = 402
    #endif

    func testDetailsDirectMessageIsAContactCard() async throws {
        let d = try await data()
        XCTAssertEqual(d.aliceShared.count, 2)
        #if os(macOS)
        let view = InspectorContent(thread: d.alice, members: [], messages: [], contact: d.aliceContact, shared: d.aliceShared)
        #else
        let view = PhoneDetailsView(thread: d.alice, members: [], messages: [], contact: d.aliceContact,
                                    preloadedPerson: try await DemoBackend.make().person(id: DemoPeople.alice), close: {})
        #endif
        Snapshot.assert(view, named: "detailsDM", width: width)
    }

    func testDetailsGroupListsMembers() async throws {
        let d = try await data()
        #if os(macOS)
        let view = InspectorContent(thread: d.climbers, members: d.climbersMembers, messages: [])
        #else
        let view = PhoneDetailsView(thread: d.climbers, members: d.climbersMembers, messages: [], close: {})
        #endif
        Snapshot.assert(view, named: "detailsGroup", width: width)
    }

    func testMemberCardShowsSharedConversations() async throws {
        let d = try await data()
        XCTAssertEqual(Set(d.maya.threads.map(\.id)), ["th_demo_maya", "th_demo_maya_wa", "th_demo_climbers"])
        let view = PersonCardContent(route: PersonRoute(id: d.maya.id, name: d.maya.name, avatar: d.maya.avatar), person: d.maya)
        Snapshot.assert(view, named: "personCard", width: width)
    }

    func testFilterButtonTintsAndSummaryNamesTheFilter() {
        let filter = FilterState(unread: true, triage: .status(.urgent))
        let view = VStack(spacing: 12) {
            HStack(spacing: 24) {
                FilterMenuLabel(isFiltering: false)
                FilterMenuLabel(isFiltering: true)
            }
            FilterSummaryBar(filter: .constant(filter))
            FilterSummaryBar(filter: .constant(FilterState(triage: .needsAttention)))
        }
        Snapshot.assert(view, named: "filterActive", width: width)
    }

    func testSummaryBarClearsFiltersButKeepsTheFolder() {
        var state = FilterState(folder: .low, unread: true, networks: [.whatsapp], triage: .needsAttention)
        let binding = Binding(get: { state }, set: { state = $0 })
        // The clear action, as the button runs it.
        binding.wrappedValue.clearFilters()
        XCTAssertEqual(state, FilterState(folder: .low))
        XCTAssertNil(state.summary(networkName: \.displayName), "nothing left to show: the bar hides")
    }

    /// Phase 2b C2: several statuses and networks at once — the button tints, the summary
    /// names every choice (Needs attention collapsed to its preset name).
    func testFilterMultiSelectSummary() {
        var many = FilterState(unread: true, networks: [.whatsapp, .telegram, .imessage], triage: .needsAttention)
        many.set(.status(.social), true)
        many.set(.status(.informational), true)
        XCTAssertEqual(many.summary(networkName: \.displayName), "Needs attention, Informational, Social, Unread, iMessage, Telegram, WhatsApp")
        let view = VStack(spacing: 12) {
            FilterMenuLabel(isFiltering: many.isFiltering)
            FilterSummaryBar(filter: .constant(FilterState(statuses: [.urgent, .social])))
            FilterSummaryBar(filter: .constant(FilterState(networks: [.whatsapp, .signal])))
            FilterSummaryBar(filter: .constant(many))
        }
        Snapshot.assert(view, named: "filterMultiSelect", width: width)
    }

    func testCallOpenerOpensOnlyAllowedLinks() {
        var opened: [URL] = []
        let saved = CallOpener.open
        CallOpener.open = { opened.append($0) }
        defer { CallOpener.open = saved }
        XCTAssertTrue(CallOpener.openIfAllowed(URL(string: "facetime://+15550001")!))
        XCTAssertFalse(CallOpener.openIfAllowed(URL(string: "file:///etc/hosts")!))
        XCTAssertFalse(CallOpener.openIfAllowed(URL(string: "https://example.test/")!))
        XCTAssertEqual(opened.map(\.absoluteString), ["facetime://+15550001"])
    }

    func testPhoneDisplay() {
        XCTAssertEqual(ContactPointRows.displayPhone("+15550102233"), "+1 (555) 010-2233")
        XCTAssertEqual(ContactPointRows.displayPhone("+15550001"), "+15550001")
        XCTAssertEqual(ContactPointRows.displayPhone("+442079460000"), "+442079460000")
    }

    func testSharedConversationSubtitle() {
        var group = FixtureMessages.thread(id: "g", title: "Weekend Climbers", kind: "group", network: "whatsapp")
        XCTAssertEqual(SharedConversationRows.subtitle(group), "WhatsApp · Group")
        group.kind = .dm
        XCTAssertEqual(SharedConversationRows.subtitle(group), "WhatsApp")
    }
}
