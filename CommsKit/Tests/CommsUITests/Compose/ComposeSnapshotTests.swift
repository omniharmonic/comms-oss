import CommsClient
import CommsCore
import CommsTestSupport
import SwiftUI
import XCTest
@testable import CommsUI

/// Phase 2b C3: the New Message screen — suggestions while typing, and a chosen recipient
/// with a failed start. Compared on macOS (hosted); iOS renders as a smoke test.
@MainActor
final class ComposeSnapshotTests: XCTestCase {
    private func backend() throws -> FixtureBackend {
        let b = try FixtureBackend(capabilities: .success(FixtureBackend.validCapabilities))
        b.setThreads([])
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var wa = FixtureMessages.thread(id: "th_ann_wa", title: "Ann Lee", network: "whatsapp", avatar: ["monogram": "AL"])
        wa.personId = "ann"
        wa.lastActivityAt = base
        var group = FixtureMessages.thread(id: "th_ann_group", title: "Climbing with Ann", kind: "group", network: "telegram", avatar: ["monogram": "C"])
        group.lastActivityAt = base.addingTimeInterval(-60)
        b.upsertThread(group)
        b.upsertThread(wa)
        b.setPerson(CommsPerson(id: "ann", name: "Ann Lee", avatar: .monogram("AL", members: []),
                                contact: CommsContact(phones: [.init(value: "+15550102233")], emails: [.init(value: "ann@example.test")])))
        return b
    }

    #if os(macOS)
    private let size = CGSize(width: 420, height: 420)
    #else
    private let size = CGSize(width: 402, height: 520)
    #endif

    func testSuggestionsWhileTyping() async throws {
        let b0 = try backend()
        let store = ComposeStore(backend: b0, outbox: Outbox(backend: b0), lookupDelay: .milliseconds(1))
        store.toText = "ann"
        await store.lookupWork?.value
        XCTAssertEqual(store.addressSuggestions.count, 2)
        XCTAssertEqual(store.conversationSuggestions.map(\.id), ["th_ann_wa", "th_ann_group"])
        Snapshot.assertHosted(ComposeView(store: store, open: { _ in }).frame(height: size.height), named: "composeSuggestions", width: size.width)
    }

    func testChosenRecipientWithAFailedStart() async throws {
        let b = try backend()
        b.setConversationHandler { _ in throw CommsError.sendFailed(CommsSendFailure(reason: .rateLimited, status: 429)) }
        let store = ComposeStore(backend: b, outbox: Outbox(backend: b), lookupDelay: .milliseconds(1))
        store.toText = "ann"
        await store.lookupWork?.value
        _ = store.choose(store.addressSuggestions[0])
        store.messageText = "Lunch Thursday?"
        _ = await store.send()
        XCTAssertNotNil(store.failure)
        Snapshot.assertHosted(ComposeView(store: store, open: { _ in }).frame(height: size.height), named: "composeRecipientFailed", width: size.width)
    }
}
