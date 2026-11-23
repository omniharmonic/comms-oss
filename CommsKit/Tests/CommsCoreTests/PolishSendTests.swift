import CommsClient
@testable import CommsCore
import CommsTestSupport
import XCTest

/// Task 5: `@Name` mentions and the merged conversation's channel pick.
@MainActor
final class PolishSendTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    func testActiveQueryCompleteAndCandidates() {
        XCTAssertEqual(MentionText.activeQuery(in: "Hi @Sa"), "Sa")
        XCTAssertEqual(MentionText.activeQuery(in: "@"), "")
        XCTAssertNil(MentionText.activeQuery(in: "mail@example"), "an address is not a mention")
        XCTAssertNil(MentionText.activeQuery(in: "Hi Sam"))
        XCTAssertEqual(MentionText.complete("Hi @sa", with: "Sam Rivera"), "Hi Sam Rivera ")
        let members = [CommsMember(id: "@me:hs", name: "Me Myself"), CommsMember(id: "@wa_1:hs", name: "Sam Rivera"),
                       CommsMember(id: "@wa_2:hs", name: "Ana Sánchez"), CommsMember(id: "@wa_3:hs", name: "Samira Patel")]
        XCTAssertEqual(MentionText.candidates(members, query: "sa", excluding: ["@me:hs"]).map(\.id), ["@wa_1:hs", "@wa_2:hs", "@wa_3:hs"], "first or last name, accent-blind")
        XCTAssertEqual(MentionText.candidates(members, query: "", excluding: ["@me:hs"]).count, 3, "never the owner")
        XCTAssertEqual(MentionText.candidates(members, query: "pat", excluding: []).map(\.id), ["@wa_3:hs"])
    }

    func testResolveFindsWholeWordsAndDropsDeletedNames() {
        let picks = [ComposerMention(userID: "@a:hs", name: "Ana"), ComposerMention(userID: "@s:hs", name: "Sam"), ComposerMention(userID: "@x:hs", name: "Gone")]
        // "Sam" inside "Samuel" is not a mention; the standalone one is. UTF-16: the emoji counts 2.
        let text = "😀 Samuel and Ana, Sam!"
        let r = MentionText.resolve(text, picks: picks)
        XCTAssertEqual(r, [CommsMention(userId: "@a:hs", start: 14, length: 3), CommsMention(userId: "@s:hs", start: 19, length: 3)])
        let rich = MentionText.richText(text, mentions: r)
        XCTAssertEqual(rich.spans, [.text("😀 Samuel and "), .mention(id: "@a:hs", name: "Ana"), .text(", "), .mention(id: "@s:hs", name: "Sam"), .text("!")])
        XCTAssertEqual(rich.plain, text)
    }

    private func group(mentions: Bool) async throws -> (TimelineStore, FixtureBackend) {
        let backend = try FixtureBackend()
        var thread = FixtureMessages.thread(id: "th_g", title: "Climbers", kind: "group", network: "whatsapp")
        thread.channels[0].capabilities = CommsChannelCapabilities(reply: true, attachments: true, send: true, mentions: mentions)
        backend.upsertThread(thread)
        backend.setThreadDetail(FixtureMessages.detail(thread, members: [CommsMember(id: "@wa_1:hs", name: "Sam Rivera"), CommsMember(id: "@wa_2:hs", name: "Ana Diaz")]))
        backend.setMessagePages([nil: FixtureMessages.page([
            FixtureMessages.message(id: "m1", threadID: "th_g", network: "whatsapp", sender: "Sam Rivera", at: base, text: "Hi"),
        ], before: nil, hasMore: false)], threadID: "th_g")
        backend.setSendEcho(.none)
        let store = TimelineStore(backend: backend, threadID: "th_g", now: { [base] in base.addingTimeInterval(120) })
        await store.loadLatest()
        return (store, backend)
    }

    func testMentionsGoOutAsRangesAndThePendingBubbleShowsThem() async throws {
        let (store, backend) = try await group(mentions: true)
        XCTAssertTrue(store.canMention)
        XCTAssertEqual(store.mentionCandidates("an").map(\.id), ["@wa_2:hs"])
        await store.send(text: "  Ana Diaz, lunch?  ", mentions: [ComposerMention(userID: "@wa_2:hs", name: "Ana Diaz")])
        let call = try XCTUnwrap(backend.sendCalls.last)
        XCTAssertEqual(call.text, "Ana Diaz, lunch?")
        XCTAssertEqual(call.mentions, [CommsMention(userId: "@wa_2:hs", start: 0, length: 8)], "ranges in the trimmed text")
        XCTAssertNil(call.channel, "one channel: no pick sent")
        let pending = store.rows.compactMap { if case .message(let m, _, _, _) = $0 { m } else { nil } }.last
        XCTAssertEqual(pending?.body?.spans.first, .mention(id: "@wa_2:hs", name: "Ana Diaz"))
    }

    func testNoMentionsWhereTheChannelDoesNotDeclareThem() async throws {
        let (store, backend) = try await group(mentions: false)
        XCTAssertFalse(store.canMention)
        XCTAssertTrue(store.mentionCandidates("").isEmpty)
        await store.send(text: "Ana Diaz hi", mentions: [ComposerMention(userID: "@wa_2:hs", name: "Ana Diaz")])
        XCTAssertEqual(backend.sendCalls.last?.mentions, [], "a plain name")
    }

    func testMergedConversationDefaultsToTheLatestInboundChannelAndSendsThePick() async throws {
        let backend = try FixtureBackend()
        var thread = FixtureMessages.thread(id: "th_p", title: "Sam", network: "whatsapp")
        let caps = CommsChannelCapabilities(reply: true, attachments: true, send: true)
        thread.channels = [CommsChannelRef(network: .whatsapp, capabilities: caps), CommsChannelRef(network: .telegram, capabilities: caps),
                           CommsChannelRef(network: .imessage, capabilities: CommsChannelCapabilities(send: false))]
        thread.networks = [.whatsapp, .telegram, .imessage]
        backend.upsertThread(thread)
        backend.setMessagePages([nil: FixtureMessages.page([
            FixtureMessages.message(id: "m1", threadID: "th_p", network: "whatsapp", sender: "Sam", at: base, text: "on WhatsApp"),
            FixtureMessages.message(id: "m2", threadID: "th_p", network: "telegram", sender: "Sam", at: base.addingTimeInterval(60), text: "on Telegram"),
            FixtureMessages.message(id: "m3", threadID: "th_p", network: "whatsapp", outgoing: true, at: base.addingTimeInterval(90), text: "mine"),
        ], before: nil, hasMore: false)], threadID: "th_p")
        backend.setSendEcho(.none)
        let store = TimelineStore(backend: backend, threadID: "th_p", now: { [base] in base.addingTimeInterval(120) })
        await store.loadLatest()

        XCTAssertEqual(store.channelChoices.map(\.network), [.whatsapp, .telegram, .imessage])
        XCTAssertEqual(store.outgoingChannel?.network, .telegram, "the newest INBOUND message's channel (not my own)")
        XCTAssertEqual(store.sendNetwork, .telegram)
        await store.send(text: "hi")
        XCTAssertEqual(backend.sendCalls.last?.channel, CommsChannelRef(network: .telegram))

        store.pickedChannel = CommsChannelRef(network: .whatsapp, capabilities: caps)
        XCTAssertEqual(store.outgoingChannel?.network, .whatsapp)
        await store.send(text: "again")
        XCTAssertEqual(backend.sendCalls.last?.channel, CommsChannelRef(network: .whatsapp))

        // A channel that can't send disables the composer instead of falling back to another.
        store.pickedChannel = store.channelChoices[2]
        XCTAssertEqual(store.outgoingChannel?.network, .imessage)
        XCTAssertFalse(store.canSend)
        XCTAssertEqual(store.voiceNoteFormat, .opusCAF)
        // A pick that is not one of the thread's channels is ignored.
        store.pickedChannel = CommsChannelRef(network: .x)
        XCTAssertNil(store.pickedChannel)
    }

    func testSingleChannelThreadOffersNoPicker() async throws {
        let backend = try FixtureBackend()
        backend.upsertThread(FixtureMessages.thread(id: "th_1", title: "Sam"))
        let store = TimelineStore(backend: backend, threadID: "th_1")
        await store.loadLatest()
        XCTAssertTrue(store.channelChoices.isEmpty)
        XCTAssertEqual(store.outgoingChannel?.network, .whatsapp)
    }
}

/// Review I2: a mention binds to exactly the place it was inserted, through edits.
@MainActor
final class MentionBindingTests: XCTestCase {
    func testThePickBindsToTheInsertedNameNotTheFirstOccurrence() throws {
        let draft = "Sam, are you free? @Sa"
        let done = try XCTUnwrap(MentionText.completeLocated(draft, with: "Sam"))
        XCTAssertEqual(done.draft, "Sam, are you free? Sam ")
        let pick = ComposerMention(userID: "@sam:hs", name: "Sam", location: done.location)
        XCTAssertEqual(MentionText.resolve(done.draft, picks: [pick]), [CommsMention(userId: "@sam:hs", start: 19, length: 3)],
                       "the greeting stays plain text")
    }

    func testTwoPeopleWithTheSameNameKeepTheirOwnPlaces() throws {
        var draft = "@Sa"
        let a = try XCTUnwrap(MentionText.completeLocated(draft, with: "Sam"))
        var picks = [ComposerMention(userID: "@wa_1:hs", name: "Sam", location: a.location)]
        draft = a.draft + "and @Sa"
        picks = MentionText.track(picks, from: a.draft, to: draft)
        let b = try XCTUnwrap(MentionText.completeLocated(draft, with: "Sam"))
        picks = MentionText.track(picks, from: draft, to: b.draft)
        picks.append(ComposerMention(userID: "@wa_2:hs", name: "Sam", location: b.location))
        XCTAssertEqual(b.draft, "Sam and Sam ")
        XCTAssertEqual(MentionText.resolve(b.draft, picks: picks),
                       [CommsMention(userId: "@wa_1:hs", start: 0, length: 3), CommsMention(userId: "@wa_2:hs", start: 8, length: 3)])
    }

    func testEditsShiftOrDropTheBinding() {
        let pick = ComposerMention(userID: "@s:hs", name: "Sam", location: 4)
        let text = "Hi, Sam see you"
        // Typing before the name shifts it.
        let shifted = MentionText.track([pick], from: text, to: "Oh hi, Sam see you")
        XCTAssertEqual(shifted.first?.location, 7)
        XCTAssertEqual(MentionText.resolve("Oh hi, Sam see you", picks: shifted).first?.start, 7)
        // Typing after it leaves it.
        XCTAssertEqual(MentionText.track([pick], from: text, to: text + "!").first?.location, 4)
        // Editing inside the name drops the mention.
        XCTAssertTrue(MentionText.track([pick], from: text, to: "Hi, Sammy see you").isEmpty)
        XCTAssertTrue(MentionText.track([pick], from: text, to: "Hi, see you").isEmpty)
        // Leading whitespace trimmed at send: the offset keeps the binding.
        XCTAssertEqual(MentionText.resolve("Hi, Sam", picks: [ComposerMention(userID: "@s:hs", name: "Sam", location: 6)], offset: 2).first?.start, 4)
    }

    func testOutboxSendsTheBoundRangeAfterTrimming() async throws {
        let backend = try FixtureBackend()
        var thread = FixtureMessages.thread(id: "th_g", title: "Crew", kind: "group", network: "whatsapp")
        thread.channels[0].capabilities = CommsChannelCapabilities(send: true, mentions: true)
        backend.upsertThread(thread)
        backend.setSendEcho(.none)
        let store = TimelineStore(backend: backend, threadID: "th_g")
        await store.loadLatest()
        // "  Sam, hi @Sam" with the pick at the second Sam (location 11 in the untrimmed draft).
        await store.send(text: "  Sam, hi Sam ", mentions: [ComposerMention(userID: "@sam:hs", name: "Sam", location: 10)])
        XCTAssertEqual(backend.sendCalls.last?.mentions, [CommsMention(userId: "@sam:hs", start: 8, length: 3)])
    }
}
