import CommsClient
import CommsTestSupport
import Foundation
@testable import CommsCore
import XCTest

/// Task 4: full message search (debounced, tokens, suggestions, paging, a server without it)
/// and contact tidy-up (People to tidy, link / create / ignore, refusals, undo).
@MainActor
final class FullSearchTidyTests: XCTestCase {
    private let base = PrismJSON.parseDate("2026-11-20T14:00:00Z")!

    private func backend() throws -> FixtureBackend {
        let b = try FixtureBackend()
        b.setThreads([])
        var ann = FixtureMessages.thread(id: "t_ann", title: "Ann Lee")
        ann.personId = "p_ann"
        var crew = FixtureMessages.thread(id: "t_crew", title: "Trail Crew", kind: "group")
        crew.lastActivityAt = base.addingTimeInterval(-60)
        var stranger = FixtureMessages.thread(id: "t_x", title: "+1 555 010 4477")
        stranger.needsTidy = true
        for t in [ann, crew, stranger] { b.upsertThread(t) }
        let msgs: [(String, String, Bool, Double)] = [
            ("t_ann", "Lunch at the café on Friday?", false, 3), ("t_ann", "Sure, the café by the pier", true, 2),
            ("t_crew", "Pier cleanup on Saturday", false, 1), ("t_x", "Is this the pier café?", false, 30),
        ]
        var pages: [String: [CommsMessage]] = [:]
        for (i, m) in msgs.enumerated() {
            pages[m.0, default: []].append(FixtureMessages.message(id: "m\(i)", threadID: m.0, outgoing: m.2, at: base.addingTimeInterval(-m.3 * 3600), text: m.1))
        }
        for (id, list) in pages { b.setMessagePages([nil: FixtureMessages.page(list, before: nil, hasMore: false)], threadID: id) }
        return b
    }

    func testTypingIsDebouncedAndHitsCarryHighlights() async throws {
        let b = try backend()
        let s = MessageSearchStore(backend: b, debounce: .milliseconds(30))
        s.text = "c"
        s.text = "ca"
        s.text = "cafe"
        await s.work?.value
        XCTAssertEqual(b.searchQueries, ["cafe"], "one request after the pause")
        XCTAssertEqual(s.hits.count, 3)
        let first = try XCTUnwrap(s.hits.first { $0.text.hasPrefix("Lunch") })
        XCTAssertEqual(first.highlights, [CommsTextRange(start: 13, length: 4)], "café matched by cafe")
        XCTAssertEqual(s.threads["t_ann"]?.title, "Ann Lee")
        XCTAssertFalse(s.isSearching)
    }

    func testTokensFilterAndSuggestionsBecomeTokens() async throws {
        let b = try backend()
        let s = MessageSearchStore(backend: b, debounce: .milliseconds(1))
        s.text = "ann"
        await s.work?.value
        XCTAssertEqual(s.suggestedTokens, [.person(id: "p_ann", name: "Ann Lee")])
        s.add(.person(id: "p_ann", name: "Ann Lee"))
        XCTAssertEqual(s.text, "", "the words that suggested the token become the token")
        s.text = "pier"
        await s.work?.value
        XCTAssertEqual(s.hits.map(\.threadId), ["t_ann"])
        s.add(.fromMe)
        s.text = "pier "
        await s.work?.value
        XCTAssertEqual(s.hits.map(\.text), ["Sure, the café by the pier"])
        s.remove(.person(id: "p_ann", name: "Ann Lee"))
        s.tokens = [.conversation(id: "t_crew", title: "Trail Crew")]
        await s.work?.value
        XCTAssertEqual(s.hits.map(\.threadId), ["t_crew"])
        s.clear()
        XCTAssertFalse(s.isActive)
        XCTAssertTrue(s.hits.isEmpty)
    }

    func testAServerWithoutFullSearchFallsBack() async throws {
        let b = try backend()
        b.setSearchEnabled(false)
        let s = MessageSearchStore(backend: b, debounce: .milliseconds(1))
        s.text = "pier"
        await s.work?.value
        XCTAssertFalse(s.isAvailable)
        XCTAssertNil(s.error)
    }

    func testPagingAppendsWithoutRepeats() async throws {
        let b = try backend()
        let s = MessageSearchStore(backend: b, debounce: .milliseconds(1))
        s.pageSize = 1
        s.text = "pier"
        await s.work?.value
        XCTAssertEqual(s.hits.count, 1)
        XCTAssertTrue(s.hasMore)
        await s.loadMore()
        await s.loadMore()
        XCTAssertEqual(s.hits.count, 3)
        XCTAssertEqual(Set(s.hits.map(\.id)).count, 3)
        XCTAssertFalse(s.hasMore)
    }

    func testTidyListLinkUndoAndIgnore() async throws {
        let b = try backend()
        b.setTidySuggestions([.init(personId: "p_ann", name: "Ann Lee", reason: "same-name")], threadID: "t_x")
        let t = TidyStore(backend: b)
        await t.load()
        XCTAssertEqual(t.people.map(\.threadId), ["t_x"])
        XCTAssertEqual(t.total, 1)
        let prompt = await t.loadPrompt(threadID: "t_x")
        XCTAssertEqual(prompt?.suggestions.first?.personId, "p_ann")
        let linked = await t.link(threadID: "t_x", personID: "p_ann")
        XCTAssertTrue(linked)
        XCTAssertEqual(t.lastAction?.kind, "link")
        XCTAssertEqual(t.lastAction?.personName, "Ann Lee")
        XCTAssertTrue(t.people.isEmpty)
        XCTAssertNil(b.currentThread(id: "t_x")?.needsTidy)
        XCTAssertEqual(b.currentThread(id: "t_x")?.personId, "p_ann")
        let undone = await t.undo()
        XCTAssertTrue(undone)
        XCTAssertNil(t.lastAction)
        XCTAssertEqual(b.currentThread(id: "t_x")?.needsTidy, true)
        XCTAssertEqual(t.prompts["t_x"]?.threadId, "t_x", "the prompt is back")
        XCTAssertEqual(t.people.count, 1)
        let ignored = await t.ignore(threadID: "t_x")
        XCTAssertTrue(ignored)
        XCTAssertEqual(b.tidyCalls, ["link t_x p_ann", "undo ta_1", "ignore t_x"])
    }

    func testCreateRefusedForASimilarNameThenAllowed() async throws {
        let b = try backend()
        b.setCreateRefusal(.similarPeople([.init(personId: "p_ann", name: "Ann Lee", reason: "same-name")]))
        let t = TidyStore(backend: b)
        let refused = await t.create(threadID: "t_x", name: "Ann Lee")
        XCTAssertFalse(refused)
        XCTAssertEqual(t.refusal, .similarPeople([.init(personId: "p_ann", name: "Ann Lee", reason: "same-name")]))
        XCTAssertEqual(TidyStore.message(t.refusal!), "Ann Lee is already in your people. Is it the same person?")
        let made = await t.create(threadID: "t_x", name: "Ann Lee", allowSimilar: true)
        XCTAssertTrue(made)
        XCTAssertNil(t.refusal)
        XCTAssertEqual(t.lastAction?.kind, "create")
    }

    func testPeopleSearchForLinkingReturnsVaultPeopleOnly() async throws {
        let b = try DemoBackend.make()
        let t = TidyStore(backend: b)
        let found = await t.searchPeople("Priya")
        XCTAssertEqual(found.map(\.personId), [DemoPeople.priya])
        let none = await t.searchPeople("   ")
        XCTAssertTrue(none.isEmpty)
        let linked = await t.link(threadID: "th_demo_lena", personID: DemoPeople.priya)
        XCTAssertTrue(linked)
        XCTAssertEqual(b.currentThread(id: "th_demo_lena")?.personId, DemoPeople.priya)
    }

    func testUnavailableSearchIsAskedAgainLater() async throws {
        let b = try backend()
        b.setSearchEnabled(false)
        let s = MessageSearchStore(backend: b, debounce: .milliseconds(1))
        s.text = "pier"
        await s.work?.value
        XCTAssertFalse(s.isAvailable)
        b.setSearchEnabled(true)
        s.text = "pier "
        await s.work?.value
        XCTAssertFalse(s.isAvailable, "not asked again at once")
        s.availabilityRetry = 0
        s.text = "pier"
        await s.work?.value
        XCTAssertTrue(s.isAvailable, "asked again after the retry interval (the server flag turned on)")
        XCTAssertEqual(s.hits.count, 3)
    }

    func testSafetyRefusalsHaveClearCopy() {
        XCTAssertEqual(TidyStore.message(.other("not_one_counterpart")),
                       "This conversation has more than one other person in it, so it can't be linked to one contact. Link the people in Prism.")
        XCTAssertEqual(TidyStore.message(.other("owner_person")), "That's you. Your own number or account isn't linked as a contact.")
        XCTAssertEqual(TidyStore.message(.other("something_new")), "That didn't work. Try again.")
    }
}
