import CommsClient
import CommsCore
import Foundation
import os

/// The demo-mode backend (DEBUG builds of the apps, `-CommsDemo YES` / `COMMS_DEMO=1`): the
/// three seeded staging rooms plus `DemoThreads` (synthetic conversations on every network,
/// filed across folders, each with its server-style preview), with two
/// pages of older (synthetic) history in "Alice Example" so scrolling up pages. Nothing here
/// touches the network. Live events come from `DemoSimulator`.
public enum DemoBackend {
    /// "Alice Example" (staging): the thread with older history.
    public static let aliceThreadID = "th_stg2"
    /// Older pages for Alice: two of `olderPageSize` messages each.
    public static let olderPageSize = 25

    /// `-CommsDemoPolish YES` (UI tests): Jonah Reyes is one person on Telegram AND WhatsApp
    /// (a merged conversation, "Telegram ⌄") and has sent a ~20 000 px long message.
    public static var polishExtras: Bool { UserDefaults.standard.bool(forKey: "CommsDemoPolish") }
    public static let jonahThreadID = "th_demo_jonah"

    /// `omni`: Omni in Comms on (`-CommsDemoOmni YES`): `@Omni` drafts after a moment and one
    /// draft already waits in "Alice Example" (Needs you), with a calendar-invite proposal. Off by default so the fidelity captures
    /// show Messages exactly.
    /// `longDraft` (`-CommsDemoOmniLongDraft YES`): the waiting draft is long, to show that Approve &
    /// Send needs the whole text to have been read.
    public static func make(omni: Bool = false, longDraft: Bool = false) throws -> FixtureBackend {
        let backend = try FixtureBackend.staging()
        backend.setFiltersThreadQuery(true)

        backend.setMediaProvider { DemoThreads.media($0) }

        // The staging dump has no previews (and plain monograms): give each room the preview
        // the server derives from its newest message, and Trail Crew a member cluster (D16).
        var newestStaging = Date.distantPast
        for id in ["th_stg0", "th_stg1", "th_stg2"] {
            guard var t = backend.currentThread(id: id), let last = backend.newestMessages(threadID: id).last else { continue }
            let isGroup = t.kind == .group
            t.lastMessage = FixtureMessages.preview(
                text: DemoPreview.text(last, senderFirstName: DemoPreview.firstName(last.sender.name), isGroup: isGroup),
                senderName: last.sender.isSelf ? nil : last.sender.name, isSelf: last.sender.isSelf, at: last.sentAt)
            if isGroup { t.avatar = .monogram("", members: [.monogram("A", members: []), .monogram("B", members: [])]) }
            backend.upsertThread(t)
            newestStaging = max(newestStaging, t.lastActivityAt)
        }

        // Synthetic conversations after the staging rooms (older), across networks and folders.
        let demo = DemoThreads.make(before: newestStaging.addingTimeInterval(-60))
        for (thread, messages) in demo.reversed() {
            backend.upsertThread(thread)
            backend.setMessagePages([nil: FixtureMessages.page(messages, before: nil, hasMore: false)], threadID: thread.id)
        }
        // Staging rooms stay on top, in their seeded order (upsert puts each at the top).
        for id in ["th_stg2", "th_stg1", "th_stg0"] {
            if let t = backend.currentThread(id: id) { backend.upsertThread(t) }
        }

        DemoPeople.install(on: backend)
        DemoEmail.install(on: backend)
        // The staging rooms (Matrix-bridged networks) can send in the demo too.
        for id in ["th_stg0", "th_stg1", "th_stg2"] {
            guard var t = backend.currentThread(id: id), !t.channels.isEmpty else { continue }
            var caps = t.channels[0].capabilities ?? CommsChannelCapabilities(reply: true, attachments: true)
            caps.send = demoCanSend(network: t.channels[0].network.wire)
            caps.react = demoCanReact(network: t.channels[0].network.wire)
            t.channels[0].capabilities = caps
            backend.upsertThread(t)
        }
        for id in ["th_stg2", "th_stg1", "th_stg0"] {
            if let t = backend.currentThread(id: id) { backend.upsertThread(t) }
        }

        addOlderHistory(to: backend)
        installTidy(on: backend)
        if polishExtras { addPolishExtras(to: backend) }
        // A Telegram forum (one thread, three topics) for the forum UI tests.
        if DemoForum.enabled { DemoForum.install(on: backend, before: Date()) }
        // Sends are answered by the fixture and echoed back on the stream, as the server does.
        backend.setSendEcho(.after(.milliseconds(700)))
        backend.setReactionEcho(.after(.milliseconds(500)))
        if omni {
            backend.omni.setAvailable(true)
            backend.omni.setDelay(.milliseconds(900))
            let long = (1...12).map { "Paragraph \($0): thanks for the details — Thursday at 3 works, and I'll bring the budget sheet." }
                .joined(separator: "\n\n") + "\n\nLast line of the long draft."
            backend.omni.addDraft(threadID: aliceThreadID, body: longDraft ? long : "Thanks Alice — Thursday at 3 works for me. See you then!", summary: "Reply to Alice")
            // A proposal Comms does not decide (Needs You opens it read-only: "Approve in Omni").
            backend.omni.addProposal(payload: ["title": "Grant call with the foundation", "start": "Thu 3:00 PM", "end": "Thu 3:30 PM",
                                               "location": "FaceTime"], summary: "Grant call with the foundation")
        }
        return backend
    }

    /// Contact tidy-up in the demo: one-to-one chats with no person are "Who is this?" (as the
    /// server marks them); the unknown WhatsApp number may be Priya (same handle).
    static func installTidy(on backend: FixtureBackend) {
        for id in ["th_demo_jonah", "th_demo_lena", "th_demo_jamie", "th_demo_stranger"] {
            guard var t = backend.currentThread(id: id), t.kind == .dm, t.personId == nil else { continue }
            t.needsTidy = true
            backend.replaceThread(t)
        }
        backend.setTidySuggestions([.init(personId: DemoPeople.priya, name: "Priya Natarajan", reason: "same-handle")], threadID: "th_demo_stranger")
        backend.setTidySuggestions([.init(personId: DemoPeople.noor, name: "Noor Haddad", reason: "same-name")], threadID: "th_demo_lena")
    }

    /// Demo threads that can send: as the server (no SMS, email or Matrix-native rooms), except
    /// that the demo keeps iMessage sendable so the composer fidelity captures can type and send
    /// in an iMessage thread.
    public static func demoCanSend(network: String) -> Bool { !["sms", "email", "matrix"].contains(network) }

    /// Demo threads that can react: as the server (`capabilities.react` is false for iMessage,
    /// SMS, email and Matrix-native rooms — no tapbacks over BlueBubbles).
    public static func demoCanReact(network: String) -> Bool { !["imessage", "sms", "email", "matrix"].contains(network) }

    /// As the server's `capabilities.mentions`: bridged networks whose bridge maps mention pills.
    public static func demoCanMention(network: String) -> Bool { ["whatsapp", "telegram", "signal", "slack", "discord", "messenger"].contains(network) }

    /// The words of the long demo message (synthetic, ~2 600 words ≈ 20 000 px tall on an iPhone).
    public static func longMessageText(words: Int = 2_600) -> String {
        let pool = ["the", "climb", "was", "long", "but", "we", "kept", "going", "past", "the", "ridge,", "then", "down", "into", "the",
                    "valley", "where", "the", "river", "ran", "cold", "and", "clear", "under", "the", "evening", "light."]
        return (0..<words).map { pool[($0 * 7 + $0 / 5) % pool.count] }.joined(separator: " ") + " The end."
    }

    private static func addPolishExtras(to backend: FixtureBackend) {
        guard var jonah = backend.currentThread(id: jonahThreadID) else { return }
        let caps = CommsChannelCapabilities(react: true, reply: true, attachments: true, send: true, mentions: true)
        jonah.channels = [CommsChannelRef(network: .telegram, capabilities: caps), CommsChannelRef(network: .whatsapp, capabilities: caps)]
        jonah.networks = [.telegram, .whatsapp]
        var messages = backend.newestMessages(threadID: jonahThreadID)
        let at = (messages.last?.sentAt ?? Date()).addingTimeInterval(60)
        messages.append(FixtureMessages.message(id: "demo_long", threadID: jonahThreadID, network: "telegram",
                                                sender: "Jonah Reyes", senderID: messages.first { !$0.sender.isSelf }?.sender.id,
                                                at: at, text: longMessageText()))
        backend.setMessagePages([nil: FixtureMessages.page(messages, before: nil, hasMore: false)], threadID: jonahThreadID)
        jonah.lastActivityAt = at
        jonah.lastMessage = FixtureMessages.preview(text: "The climb was long…", senderName: "Jonah Reyes", isSelf: false, at: at)
        backend.upsertThread(jonah)
    }

    /// Alice's newest page says there is more; two synthetic older pages follow.
    private static func addOlderHistory(to backend: FixtureBackend) {
        let newest = backend.newestMessages(threadID: aliceThreadID)
        guard let first = newest.first else { return }
        let alice = newest.first { !$0.sender.isSelf && $0.system == nil }?.sender
        let network = newest.first?.channel.network.wire ?? "whatsapp"
        func older(_ pageIndex: Int) -> [CommsMessage] {
            (0..<olderPageSize).map { i in
                // Page 1 sits just before the newest page, page 2 before that; an hour apart.
                let n = pageIndex * olderPageSize + (olderPageSize - i)
                let at = first.sentAt.addingTimeInterval(-Double(n) * 3600)
                let outgoing = i % 3 == 2
                return FixtureMessages.message(
                    id: "demo_old_\(pageIndex)_\(i)", threadID: aliceThreadID, network: network,
                    sender: alice?.name ?? "Alice", senderID: alice?.id, outgoing: outgoing, at: at,
                    text: "Older message \(n) (page \(pageIndex + 1))")
            }
        }
        backend.setMessagePages([
            nil: FixtureMessages.page(newest, before: "demo_older_1", hasMore: true),
            "demo_older_1": FixtureMessages.page(older(0), before: "demo_older_2", hasMore: true),
            "demo_older_2": FixtureMessages.page(older(1), before: nil, hasMore: false),
        ], threadID: aliceThreadID)
    }
}

/// Injects live events into a demo `FixtureBackend`'s stream, as the server would send them:
/// a new incoming message (`message.created` + `thread.updated`) or a reaction on the latest
/// incoming message (`reaction.changed`). The backend's list, details and newest page are
/// updated first, so the refetch that follows sees the change.
public final class DemoSimulator: Sendable {
    public let backend: FixtureBackend
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    public init(backend: FixtureBackend) { self.backend = backend }

    private func next() -> Int { counter.withLock { $0 += 1; return $0 } }

    /// A new incoming message in `threadID`. Returns its text.
    @discardableResult
    public func injectMessage(threadID: String, text: String? = nil, now: Date = .now) -> String? {
        let n = next()
        let existing = backend.newestMessages(threadID: threadID)
        let sender = existing.last { !$0.sender.isSelf && $0.system == nil }?.sender
        let network = existing.last?.channel.network.wire ?? backend.currentThread(id: threadID)?.networks.first?.wire ?? "whatsapp"
        let body = text ?? "Live message \(n)"
        let message = FixtureMessages.message(
            id: "demo_live_\(n)", threadID: threadID, network: network,
            sender: sender?.name ?? "Alice", senderID: sender?.id, at: now, text: body)
        backend.upsertNewestMessage(message, threadID: threadID)
        if var thread = backend.currentThread(id: threadID) {
            thread.lastActivityAt = now
            thread.unread.count += 1
            let first = DemoPreview.firstName(message.sender.name)
            thread.lastMessage = FixtureMessages.preview(
                text: DemoPreview.text(message, senderFirstName: first, isGroup: thread.kind == .group),
                senderName: message.sender.name, isSelf: false, at: now)
            backend.upsertThread(thread)
        }
        backend.push(FixtureMessages.event(.messageCreated, message, id: "demo_e\(n)"))
        backend.push(Self.threadUpdated(threadID, id: "demo_t\(n)"))
        return body
    }

    /// A 😂 from a contact on the latest incoming message in `threadID` (adds one to the
    /// count if already there). Returns the reacted message's id.
    @discardableResult
    public func injectReaction(threadID: String, key: String = "😂") -> String? {
        let n = next()
        guard var message = backend.newestMessages(threadID: threadID).last(where: { !$0.sender.isSelf && $0.system == nil && !$0.redacted }) else { return nil }
        message.reactions = FixtureMessages.adding(reaction: key, to: message.reactions, senderIndex: n)
        backend.upsertNewestMessage(message, threadID: threadID)
        backend.push(FixtureMessages.event(.reactionChanged, message, id: "demo_r\(n)"))
        return message.id
    }

    static func threadUpdated(_ threadID: String, id: String) -> CommsEvent {
        CommsEvent(id: id, kind: .threadUpdated, payload: ["threadId": .string(threadID)])
    }
}

extension FixtureMessages {
    /// A thread's last-message preview.
    public static func preview(text: String, senderName: String?, isSelf: Bool, at: Date) -> CommsMessagePreview {
        var json: [String: Any] = ["text": text, "isSelf": isSelf, "sentAt": at.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))]
        if let senderName { json["senderName"] = senderName }
        return try! PrismJSON.decoder().decode(CommsMessagePreview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// `reactions` with one more `key` from a (synthetic) contact.
    public static func adding(reaction key: String, to reactions: [CommsReaction], senderIndex: Int) -> [CommsReaction] {
        var all = try! JSONSerialization.jsonObject(with: PrismJSON.encoder().encode(reactions)) as! [[String: Any]]
        let sender: [String: Any] = ["id": "@demo\(senderIndex):example.test", "name": "Demo \(senderIndex)"]
        if let i = all.firstIndex(where: { $0["key"] as? String == key }) {
            all[i]["count"] = (all[i]["count"] as? Int ?? 0) + 1
            all[i]["senders"] = (all[i]["senders"] as? [[String: Any]] ?? []) + [sender]
        } else {
            all.append(["key": key, "count": 1, "mine": false, "senders": [sender]])
        }
        return try! PrismJSON.decoder().decode([CommsReaction].self, from: JSONSerialization.data(withJSONObject: all))
    }
}
