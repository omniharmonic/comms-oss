import CommsClient
import CommsCore
import CommsTestSupport
@testable import CommsUI
import PrismModels
import SwiftUI
import XCTest

/// Omni in Comms (PRD §5.7, D9), light and dark at Mac sizes: the dashed draft bubble with its
/// actions, the composer as Omni's instruction field, "Omni is drafting…", the private note, and
/// Needs you. Hosted renders (glass and real text fields).
@MainActor
final class OmniSnapshotTests: XCTestCase {
    static let width: CGFloat = 460
    let th = "th_snap"

    private func omniStore(drafts: [String] = [], composer: Bool = false) throws -> OmniStore {
        let backend = try FixtureBackend()
        backend.omni.setAvailable(true)
        for d in drafts { backend.omni.addDraft(threadID: th, body: d, summary: "Reply to Alex") }
        let store = OmniStore(backend: backend, presence: FixedPresence(true))
        if composer { store.beginAsk(threadID: th) }
        return store
    }

    func testDraftBubble() {
        Snapshot.assertHosted(OmniDraftBubble(text: "Thursday at 3 works for me — see you then!").padding(.vertical, 12),
                              named: "omniDraftBubble", width: Self.width)
    }

    func testStatusChipAndNote() {
        let v = VStack(spacing: 12) {
            OmniNoteCard(title: "Catch Up", text: "• Alex asked whether Thursday works for the grant call.\n• Nothing else needs you.")
            OmniStatusChip()
        }
        .padding(.vertical, 12)
        Snapshot.assertHosted(v, named: "omniNoteAndChip", width: Self.width)
    }

    func testComposerOmniMode() async throws {
        let omni = try omniStore(composer: true)
        let bar = ComposerBar(network: .whatsapp, canSend: true, omniThreadID: th, draft: "Say yes to Thursday and ask for the agenda")
            .padding(.vertical, 12)
            .environment(\.omniStore, omni)
        Snapshot.assertHosted(bar, named: "composerOmniMode", width: Self.width)
    }

    func testComposerAtOmniTyped() async throws {
        let omni = try omniStore()
        let bar = ComposerBar(network: .whatsapp, canSend: true, omniThreadID: th, draft: "@Omni draft a polite no")
            .padding(.vertical, 12)
            .environment(\.omniStore, omni)
        Snapshot.assertHosted(bar, named: "composerAtOmni", width: Self.width)
    }

    func testNeedsYou() {
        let items = [
            FixtureOmni.approval(id: "apr_1", threadID: th, body: "Thursday at 3 works for me.", summary: "Reply to Alex"),
            FixtureOmni.approval(id: "apr_2", threadID: "th_2", body: "Happy to join — I'll bring the budget.", summary: "Reply to Trail Crew"),
        ]
        Snapshot.assertHosted(NeedsYouList(items: items) { _ in }.frame(width: 300).padding(.vertical, 12), named: "omniNeedsYou", width: 320)
    }

    func testMenuOffersAskOmniOnlyWithOmni() {
        let m = FixtureMessages.message(id: "m1", threadID: th, at: Date(timeIntervalSince1970: 1_800_000_000), text: "Are you free Thursday?")
        let without = MessageMenuItem.groups(for: m, interactions: .none, platformSelect: true).flatMap { $0 }.map(\.kind)
        XCTAssertFalse(without.contains(.askOmni))
        let with = MessageInteractions(askOmni: { _ in })
        XCTAssertEqual(MessageMenuItem.groups(for: m, interactions: with, platformSelect: true).last?.map(\.kind), [.askOmni])
    }
}

/// Review fix round 1 (C1, I2).
@MainActor
final class OmniReviewSnapshotTests: XCTestCase {
    static let iPhoneWidth: CGFloat = 390
    static let longDraft = (1...14).map { "Paragraph \($0): Thanks for the details about the grant call — Thursday at 3 works, and I'll bring the budget sheet." }
        .joined(separator: "\n\n") + "\n\nThe end: https://example.invalid/never-unseen"

    /// A long draft at iPhone width: a capped, scrolling preview; no Approve & Send inline, only
    /// "Review & Send…".
    func testLongDraftIsCappedAndNotYetApprovable() {
        Snapshot.assertHosted(OmniDraftBubble(text: Self.longDraft).padding(.vertical, 12), named: "omniLongDraft", width: Self.iPhoneWidth)
    }

    /// Round 2: the review sheet, the only place with Approve & Send (disabled: not read through yet).
    func testDraftReviewSheet() {
        Snapshot.assertHosted(DraftReview(text: Self.longDraft, recipient: "Alex", network: .whatsapp, embedded: false, onEdit: {}, onRefine: { _ in }),
                              named: "omniDraftReview", width: Self.iPhoneWidth)
    }

    /// Round 3: a short draft — the sheet is only as tall as its content; the bubble is the
    /// network's outgoing colour; Edit / Refine… / Approve & Send in one row.
    func testDraftReviewSheetShortDraft() {
        Snapshot.assertHosted(DraftReview(text: "Thursday at 3 works for me — see you then!", recipient: "Alice Example", network: .imessage,
                                          embedded: false, onEdit: {}, onRefine: { _ in }),
                              named: "omniDraftReviewShort", width: Self.iPhoneWidth)
    }

    /// A draft with hidden characters: the sheet says why and never enables Approve & Send.
    func testDraftReviewRefusesHiddenCharacters() {
        Snapshot.assertHosted(DraftReview(text: "Sure\u{E0100}, Thursday works.", embedded: false).frame(height: 300), named: "omniDraftReviewHidden", width: Self.iPhoneWidth)
    }

    /// `@Omni …` without Omni: blocked with a reason, no send arrow (it is never sent to the chat).
    func testAtOmniWithoutOmniIsBlocked() {
        Snapshot.assertHosted(ComposerBar(network: .whatsapp, canSend: true, omniThreadID: "th_x", draft: "@Omni tell him no").padding(.vertical, 12),
                              named: "composerAtOmniWithoutOmni", width: 460)
    }
}
