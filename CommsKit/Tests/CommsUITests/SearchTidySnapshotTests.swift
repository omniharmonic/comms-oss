import CommsClient
import CommsCore
import CommsTestSupport
import SwiftUI
import XCTest
@testable import CommsUI

/// Task 4: search results (bubbles with highlighted words, suggestions, Links / Photos), the
/// "Who is this?" card and People to Tidy. Compared on macOS; rendered as a smoke test on iOS.
@MainActor
final class SearchTidySnapshotTests: XCTestCase {
    private let base = PrismJSON.parseDate("2026-11-20T14:00:00Z")!
    private var now: Date { base.addingTimeInterval(3600) }

    #if os(macOS)
    private let width: CGFloat = 300
    #else
    private let width: CGFloat = 402
    #endif

    private func backend() throws -> FixtureBackend {
        let b = try FixtureBackend()
        b.setThreads([])
        var ann = FixtureMessages.thread(id: "t_ann", title: "Ann Lee", avatar: ["monogram": "AL"])
        ann.personId = "p_ann"
        let crew = FixtureMessages.thread(id: "t_crew", title: "Trail Crew", kind: "group", network: "telegram", avatar: ["monogram": "TC"])
        var stranger = FixtureMessages.thread(id: "t_x", title: "+1 (555) 010-4477", avatar: ["monogram": "#"])
        stranger.needsTidy = true
        stranger.titleSource = .handle
        for t in [ann, crew, stranger] { b.upsertThread(t) }
        let link: [String: Any] = ["url": "https://example.test/pier-map", "title": "Pier map and tide times", "siteName": "example.test"]
        let pages: [String: [CommsMessage]] = [
            "t_ann": [
                FixtureMessages.message(id: "a1", threadID: "t_ann", sender: "Ann Lee", at: base.addingTimeInterval(-3 * 3600), text: "Lunch at the pier café on Friday?"),
                FixtureMessages.message(id: "a2", threadID: "t_ann", outgoing: true, at: base.addingTimeInterval(-2 * 3600), text: "Yes! The café by the pier at noon"),
            ],
            "t_crew": [
                FixtureMessages.message(id: "c1", threadID: "t_crew", network: "telegram", sender: "Jonah", at: base.addingTimeInterval(-26 * 3600),
                                        text: "Pier cleanup on Saturday, bring gloves", linkPreviews: [link]),
                FixtureMessages.message(id: "c2", threadID: "t_crew", network: "telegram", sender: "Priya", at: base.addingTimeInterval(-25 * 3600),
                                        text: nil, attachments: [FixtureMessages.image(token: "tok_photo", w: 400, h: 300)]),
            ],
            "t_x": [FixtureMessages.message(id: "x1", threadID: "t_x", sender: "+1 (555) 010-4477", at: base.addingTimeInterval(-50 * 3600), text: "Hi, is this the pier café?")],
        ]
        for (id, list) in pages { b.setMessagePages([nil: FixtureMessages.page(list, before: nil, hasMore: false)], threadID: id) }
        b.setTidySuggestions([.init(personId: "p_priya", name: "Priya Natarajan", reason: "same-handle")], threadID: "t_x")
        return b
    }

    private func results(_ search: MessageSearchStore, conversations: [CommsThread] = []) -> some View {
        SearchResultsView(search: search, conversations: conversations, now: now, open: { _ in })
            .environment(\.bubbleMetrics, .current)
            .environment(\.mediaLoader, .placeholder)
    }

    func testResultsShowBubblesWithHighlightedWordsAndSuggestions() async throws {
        let b = try backend()
        let s = MessageSearchStore(backend: b, debounce: .milliseconds(1))
        s.text = "pier cafe"
        await s.work?.value
        try await Task.sleep(for: .milliseconds(50)) // links (media) answer
        XCTAssertEqual(s.hits.count, 3)
        Snapshot.assert(results(s), named: "searchResults", width: width)
    }

    func testTokenSuggestionsAndConversationsRow() async throws {
        let b = try backend()
        let s = MessageSearchStore(backend: b, debounce: .milliseconds(1))
        s.text = "trail"
        await s.work?.value
        XCTAssertEqual(s.suggestedTokens, [.conversation(id: "t_crew", title: "Trail Crew")])
        let crew = try XCTUnwrap(b.currentThread(id: "t_crew"))
        Snapshot.assert(results(s, conversations: [crew]), named: "searchSuggestions", width: width)
    }

    func testPhotosAndLinksTabs() async throws {
        let b = try backend()
        let s = MessageSearchStore(backend: b, debounce: .milliseconds(1))
        s.tokens = [.conversation(id: "t_crew", title: "Trail Crew")]
        s.text = "pier"
        await s.work?.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(s.photos.count, 1)
        XCTAssertEqual(s.links.map(\.link?.url), ["https://example.test/pier-map"])
        s.scope = .links
        Snapshot.assert(results(s), named: "searchLinks", width: width)
        s.scope = .photos
        try await Task.sleep(for: .milliseconds(50))
        Snapshot.assert(results(s), named: "searchPhotos", width: width)
    }

    func testHighlightRangesBecomeBoldRuns() {
        let a = SearchHitBubble.attributed("😀 Pier café", highlights: [CommsTextRange(start: 3, length: 4), CommsTextRange(start: 99, length: 2)])
        let bold = a.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(a[$0.range].characters) }
        XCTAssertEqual(bold, ["Pier"], "a UTF-16 range after an emoji; an out-of-range one is ignored")
    }

    func testWhoIsThisCardOffersLinkCreateIgnore() async throws {
        let b = try backend()
        let tidy = TidyStore(backend: b)
        await tidy.loadPrompt(threadID: "t_x")
        let thread = try XCTUnwrap(b.currentThread(id: "t_x"))
        let view = WhoIsThisCard(thread: thread)
            .environment(\.tidyStore, tidy)
            .padding(16)
        Snapshot.assert(view, named: "whoIsThis", width: width)
        // After linking: "Linked to …" with Undo.
        _ = await tidy.link(threadID: "t_x", personID: "p_priya")
        Snapshot.assert(view, named: "whoIsThisLinked", width: width)
    }

    func testPeopleToTidyList() async throws {
        let b = try backend()
        let tidy = TidyStore(backend: b)
        await tidy.load()
        XCTAssertEqual(tidy.people.map(\.threadId), ["t_x"])
        let view = PeopleToTidyView(store: tidy, now: now, open: { _ in }).frame(height: 260)
        Snapshot.assertHosted(view, named: "peopleToTidy", width: width)
        let row = PeopleToTidyRow(count: 3, action: {}).padding(.vertical, 8)
        Snapshot.assert(row, named: "peopleToTidyRow", width: width)
    }

    func testLinkToExistingPersonPicker() async throws {
        let b = try backend()
        let tidy = TidyStore(backend: b)
        let prompt = await tidy.loadPrompt(threadID: "t_x")
        let item = try XCTUnwrap(prompt)
        _ = PersonPickerView(store: tidy, item: item, done: {})
        let view = PersonPickerList(store: tidy, item: item, query: "Pri",
                                    results: [.init(personId: "p_priya", name: "Priya Natarajan", reason: "search"),
                                              .init(personId: "p_prince", name: "Prince Adeyemi", reason: "search")], searched: true, done: {})
            .frame(height: 220)
        Snapshot.assertHosted(view, named: "tidyPersonPicker", width: width)
        XCTAssertEqual(CommsTidyItem.Suggestion(personId: "a", name: "A", reason: "same-name").reasonText, "Same name, different number")
    }
}
