import CommsClient
import CommsCore
import Foundation

/// A synthetic Telegram forum for the demo and the UI tests (`-CommsDemoForum YES`): ONE thread,
/// "Trailhead Collective", with three topics (General, Gear, Rides), All Topics merged and each
/// topic on its own, as the server answers them. Made-up names; nothing real.
public enum DemoForum {
    public static let threadID = "th_demo_forum"
    public static let topics: [(id: String, title: String, unread: Int)] = [
        ("tp_gear", "Gear", 2), ("tp_general", "General", 0), ("tp_rides", "Rides", 1),
    ]
    /// `-CommsDemoForum YES` (UI tests, demo).
    public static var enabled: Bool { UserDefaults.standard.bool(forKey: "CommsDemoForum") }

    /// Lines per topic, oldest first: (topic, sender or nil = the owner, text).
    static let lines: [(topic: String, who: String?, text: String)] = [
        ("tp_general", "Maya Chen", "Welcome to the collective — introduce yourselves here."),
        ("tp_rides", "Eli Brooks", "Saturday ride leaves the trailhead at 8."),
        ("tp_general", nil, "Thanks for setting this up!"),
        ("tp_gear", "Ivy Moreno", "Anyone have a spare tube for a 29er?"),
        ("tp_rides", "Maya Chen", "I'll bring coffee for the 8 am group."),
        ("tp_gear", "Eli Brooks", "I do — I'll leave it at the shop."),
    ]

    public static func install(on backend: FixtureBackend, before anchor: Date) {
        let title: [String: String] = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0.title) })
        let messages: [CommsMessage] = lines.enumerated().map { i, l in
            var m = FixtureMessages.message(id: "forum_m\(i)", threadID: threadID, network: "telegram", sender: l.who ?? "Me", outgoing: l.who == nil,
                                            at: anchor.addingTimeInterval(Double(i - lines.count) * 300), text: l.text)
            m.topic = CommsTopicRef(id: l.topic, title: title[l.topic] ?? l.topic)
            return m
        }
        var thread = FixtureMessages.thread(id: threadID, title: "Trailhead Collective", kind: "group", network: "telegram", avatar: ["monogram": "TC"])
        thread.forum = .init(topicCount: topics.count)
        thread.unread = .init(count: topics.reduce(0) { $0 + $1.unread }, trusted: true)
        let last = messages.last!
        thread.lastActivityAt = last.sentAt
        thread.lastMessage = FixtureMessages.preview(text: "Gear · Eli: I do — I'll leave it at the shop.", senderName: "Eli Brooks", isSelf: false, at: last.sentAt)
        thread.channels = [CommsChannelRef(network: .telegram, capabilities: CommsChannelCapabilities(react: true, reply: true, attachments: true, send: true))]
        backend.upsertThread(thread)
        let topicList = topics.map { t in
            CommsTopic(id: t.id, title: t.title, lastActivityAt: messages.last { $0.topic?.id == t.id }?.sentAt ?? anchor, unread: t.unread,
                       capabilities: CommsChannelCapabilities(react: true, reply: true, attachments: true, send: true))
        }
        backend.setThreadDetail(CommsThreadDetail(thread: thread, topics: topicList))
        backend.setMessagePages([nil: FixtureMessages.page(messages, before: nil, hasMore: false)], threadID: threadID)
        for t in topics {
            backend.setMessagePages([nil: FixtureMessages.page(messages.filter { $0.topic?.id == t.id }, before: nil, hasMore: false)], threadID: threadID, topic: t.id)
        }
    }
}
