import CommsClient
import Foundation

/// The six tapbacks the Messages picker offers, in its order, as the keys Comms sends.
public enum Tapbacks {
    public static let keys = ["❤️", "👍", "👎", "😂", "‼️", "❓"]
}

/// One reaction the owner made from this device that the server has not shown yet: drawn at
/// once (optimistic), undone if the server refuses, dropped when the loaded message agrees.
public struct ReactionChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case add, remove }
    public var kind: Kind
    public var key: String
    /// The add's `clientId` (a UUID); unused for a remove.
    public var clientID: String
    /// When the server accepted it (nil while in flight). An accepted change stays drawn until
    /// the echo agrees, or `ReactionOverlay.confirmedTTL` passes.
    public var confirmedAt: Date?

    public init(kind: Kind, key: String, clientID: String = UUID().uuidString, confirmedAt: Date? = nil) {
        self.kind = kind
        self.key = key
        self.clientID = clientID
        self.confirmedAt = confirmedAt
    }
}

/// One request of the owner's reaction queue for a message. A message's requests go out one
/// after another, in the order they were made (`TimelineStore.toggleReaction`), so a rapid
/// second tap can never race the first: replacing ❤️ with 👍 is "add 👍, then remove ❤️", and
/// when the add fails the remove is dropped and ❤️ stays.
public struct ReactionOp: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case queued
        case inFlight
        case confirmed(Date)
    }
    public var kind: ReactionChange.Kind
    public var key: String
    /// The add's `clientId` (a UUID; also identifies the op).
    public var clientID: String
    /// The ops of one tap (an add and the removes it replaces).
    public var batch: UUID
    /// A remove that replaces the owner's earlier tapback.
    public var replacing: Bool
    public var state: State = .queued

    public init(kind: ReactionChange.Kind, key: String, batch: UUID, replacing: Bool = false) {
        self.kind = kind
        self.key = key
        self.clientID = UUID().uuidString
        self.batch = batch
        self.replacing = replacing
    }

    public var confirmedAt: Date? { if case .confirmed(let d) = state { d } else { nil } }
    public var isSettled: Bool { confirmedAt != nil }
}

/// A short notice after a reaction failed ("Couldn't react."). Never retried by itself.
public struct ReactionNotice: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let text: String
}

/// Who reacted with what, one entry per person (the reaction details list).
public struct ReactionPerson: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var isSelf: Bool
    public var keys: [String]

    public init(id: String, name: String, isSelf: Bool, keys: [String]) {
        self.id = id
        self.name = name
        self.isSelf = isSelf
        self.keys = keys
    }
}

/// Pure functions behind the optimistic reactions (unit-tested).
public enum ReactionOverlay {
    /// An accepted change waits this long for its echo before the server's state is trusted.
    public static let confirmedTTL: TimeInterval = 120

    /// Two keys are the same reaction ("❤" and "❤️", skin tones aside the server keeps them apart).
    static func same(_ a: String, _ b: String) -> Bool { a == b }

    /// `reactions` with the owner's pending `changes` drawn on top.
    public static func apply(_ changes: [ReactionChange], to reactions: [CommsReaction], selfID: String, selfIDs: Set<String>) -> [CommsReaction] {
        var out = reactions
        for c in changes {
            let i = out.firstIndex { same($0.key, c.key) }
            switch c.kind {
            case .add:
                if let i {
                    guard !out[i].mine else { continue }
                    out[i].mine = true
                    out[i].count += 1
                    out[i].senders.append(.init(id: selfID, name: "You"))
                } else {
                    out.append(CommsReaction(key: c.key, count: 1, mine: true, senders: [.init(id: selfID, name: "You")]))
                }
            case .remove:
                guard let i, out[i].mine else { continue }
                out[i].mine = false
                out[i].count = max(0, out[i].count - 1)
                if let s = out[i].senders.firstIndex(where: { isSelf($0, selfIDs: selfIDs) }) { out[i].senders.remove(at: s) }
                if out[i].count == 0 { out.remove(at: i) }
            }
        }
        return out
    }

    /// The changes still worth drawing over the server's `reactions`: one the server already
    /// shows is done; an accepted one older than `confirmedTTL` gives way to the server.
    public static func pending(_ changes: [ReactionChange], against reactions: [CommsReaction], now: Date) -> [ReactionChange] {
        changes.filter { c in
            let mine = reactions.contains { same($0.key, c.key) && $0.mine }
            if c.kind == .add ? mine : !mine { return false }
            if let at = c.confirmedAt, now.timeIntervalSince(at) > confirmedTTL { return false }
            return true
        }
    }

    /// The queue as drawn: per key, its LAST op wins (a later tap supersedes an earlier one).
    public static func effective(_ ops: [ReactionOp]) -> [ReactionChange] {
        var order: [String] = []
        var last: [String: ReactionOp] = [:]
        for op in ops {
            if last[op.key] == nil { order.append(op.key) }
            last[op.key] = op
        }
        return order.compactMap { last[$0] }.map { ReactionChange(kind: $0.kind, key: $0.key, clientID: $0.clientID, confirmedAt: $0.confirmedAt) }
    }

    /// The ops still worth keeping: queued and in-flight ones always; an accepted one only while
    /// it is its key's last op, the server does not show it yet, and `confirmedTTL` has not passed.
    public static func prune(_ ops: [ReactionOp], against reactions: [CommsReaction], now: Date) -> [ReactionOp] {
        var lastIndex: [String: Int] = [:]
        for (i, op) in ops.enumerated() { lastIndex[op.key] = i }
        return ops.enumerated().filter { i, op in
            guard let at = op.confirmedAt else { return true }
            guard lastIndex[op.key] == i else { return false }
            let mine = reactions.contains { same($0.key, op.key) && $0.mine }
            if op.kind == .add ? mine : !mine { return false }
            return now.timeIntervalSince(at) <= confirmedTTL
        }.map(\.1)
    }

    static func isSelf(_ s: CommsReaction.Sender, selfIDs: Set<String>) -> Bool {
        selfIDs.contains(s.id) || ["you", "me"].contains(s.name.lowercased())
    }

    /// One row per person: the owner first ("You"), then the others in the order they appear.
    /// A reaction whose count is larger than its named senders adds an "N others" row.
    public static func people(_ reactions: [CommsReaction], selfIDs: Set<String>) -> [ReactionPerson] {
        var rows: [ReactionPerson] = []
        var index: [String: Int] = [:]
        func add(id: String, name: String, isSelf: Bool, key: String) {
            if let i = index[id] {
                if !rows[i].keys.contains(key) { rows[i].keys.append(key) }
            } else {
                index[id] = rows.count
                rows.append(ReactionPerson(id: id, name: name, isSelf: isSelf, keys: [key]))
            }
        }
        for r in reactions {
            var selfSeen = false
            var named = 0
            for s in r.senders {
                let me = isSelf(s, selfIDs: selfIDs)
                if me {
                    guard r.mine || !selfSeen else { continue }
                    selfSeen = true
                    add(id: "self", name: "You", isSelf: true, key: r.key)
                } else {
                    add(id: s.id, name: s.name.isEmpty ? "Someone" : s.name, isSelf: false, key: r.key)
                }
                named += 1
            }
            if r.mine, !selfSeen {
                add(id: "self", name: "You", isSelf: true, key: r.key)
                named += 1
            }
            let unnamed = r.count - named
            if unnamed > 0 {
                add(id: "others-\(r.key)", name: unnamed == 1 ? "1 other" : "\(unnamed) others", isSelf: false, key: r.key)
            }
        }
        return rows.sorted { $0.isSelf && !$1.isSelf }
    }
}

extension TimelineStore {
    /// The thread's channel lets the owner react (`capabilities.react`: false for iMessage,
    /// SMS, email, plain Matrix and encrypted rooms).
    public var canReact: Bool {
        capabilities?.react ?? thread?.channels.first?.capabilities?.react ?? false
    }

    /// This message can take a reaction: the channel reacts, and it is a real (echoed), live,
    /// non-system message.
    ///
    /// In a thread with several channels (one person on several networks) the message's own
    /// channel decides: a tapback on an iMessage message is never offered because WhatsApp reacts.
    public func canReact(to m: CommsMessage) -> Bool {
        guard PendingSend.clientID(ofMessageID: m.id) == nil, !m.redacted, m.system == nil else { return false }
        if let channels = thread?.channels, channels.count > 1 {
            let own = channels.first { $0.network == m.channel.network && $0.accountLabel == m.channel.accountLabel }
                ?? channels.first { $0.network == m.channel.network }
            return canReact && (own?.capabilities?.react ?? false)
        }
        return canReact
    }

    /// The owner's reactions on `m` as drawn (pending changes included).
    public func myReactionKeys(on m: CommsMessage) -> Set<String> {
        Set(m.reactions.filter(\.mine).map(\.key))
    }

    /// A reaction request for `key` on `messageID` is queued or on its way to the server.
    public func isReactionInFlight(_ key: String, on messageID: String) -> Bool {
        reactionOps[messageID]?.contains { $0.key == key && !$0.isSettled } ?? false
    }

    /// Messages' tapback: tapping one of mine removes it; tapping another replaces mine with it
    /// (one tapback per person, as Messages: the add first, then the removes, so a failed add
    /// leaves the old one). Shows at once, even while an earlier tap is still on its way: the
    /// requests for one message go out strictly one after another. A refusal puts the drawing
    /// back and leaves a `reactionNotice`. Nothing is retried on its own. Returns when this
    /// tap's requests (and any queued before them) have been answered.
    public func toggleReaction(_ key: String, on messageID: String) async {
        guard let m = displayedMessage(id: messageID), canReact(to: m) else { return }
        let mine = myReactionKeys(on: m)
        let batch = UUID()
        let plan: [ReactionOp]
        if mine.contains(key) {
            plan = [ReactionOp(kind: .remove, key: key, batch: batch)]
        } else {
            plan = [ReactionOp(kind: .add, key: key, batch: batch)]
                + mine.sorted().map { ReactionOp(kind: .remove, key: $0, batch: batch, replacing: true) }
        }
        reactionOps[messageID, default: []] += plan
        reactionsChanged()
        await drainReactions(messageID)
    }

    /// Fire-and-forget form for views.
    public func react(_ key: String, on messageID: String) {
        Task { await toggleReaction(key, on: messageID) }
    }

    public func dismissReactionNotice() { reactionNotice = nil }

    /// Who reacted on `messageID`, one row per person.
    public func reactionPeople(on messageID: String) -> [ReactionPerson] {
        guard let m = displayedMessage(id: messageID) else { return [] }
        return ReactionOverlay.people(m.reactions, selfIDs: selfSenderIDs)
    }

    /// Send `messageID`'s queued requests one at a time (one runner per message; a caller that
    /// finds a runner waits for it, and the runner takes everything queued meanwhile).
    func drainReactions(_ messageID: String) async {
        if let running = reactionRunners[messageID] { await running.value }
        guard reactionRunners[messageID] == nil, reactionOps[messageID]?.contains(where: { $0.state == .queued }) == true else { return }
        let runner = Task { @MainActor in
            while let op = self.reactionOps[messageID]?.first(where: { $0.state == .queued }) {
                await self.send(op, on: messageID)
            }
            self.reactionRunners[messageID] = nil
        }
        reactionRunners[messageID] = runner
        await runner.value
    }

    private func update(_ op: ReactionOp, on messageID: String, _ change: (inout ReactionOp) -> Void) {
        guard let i = reactionOps[messageID]?.firstIndex(where: { $0.clientID == op.clientID }) else { return }
        change(&reactionOps[messageID]![i])
    }

    private func send(_ op: ReactionOp, on messageID: String) async {
        update(op, on: messageID) { $0.state = .inFlight }
        do {
            switch op.kind {
            case .add:
                _ = try await reactionBackend.addReaction(threadID: threadID, messageID: messageID, clientID: op.clientID, key: op.key, topic: topicID(ofMessage: messageID))
            case .remove:
                try await reactionBackend.removeReaction(threadID: threadID, messageID: messageID, key: op.key, topic: topicID(ofMessage: messageID))
            }
            update(op, on: messageID) { $0.state = .confirmed(reactionNow()) }
            reactionsChanged()
        } catch {
            let f = Self.sendFailure(error)
            if op.kind == .add, f.reason == .alreadyReacted {
                // The owner already has it (his phone, or an earlier attempt): it stands.
                update(op, on: messageID) { $0.state = .confirmed(reactionNow()) }
                reactionsChanged()
                return
            }
            var ops = reactionOps[messageID] ?? []
            let index = ops.firstIndex { $0.clientID == op.clientID }
            ops.removeAll { $0.clientID == op.clientID }
            if op.kind == .add, let index {
                // The removes this add would have replaced stay undone (the old tapback stays),
                // and a later remove of this key has nothing to remove.
                ops = ops.enumerated().filter { i, o in
                    !(o.state == .queued && (o.batch == op.batch || (i >= index && o.key == op.key && o.kind == .remove)))
                }.map(\.1)
            }
            reactionOps[messageID] = ops.isEmpty ? nil : ops
            reactionNotice = ReactionNotice(text: Self.reactionFailureText(f, kind: op.kind, replacing: op.replacing))
            reactionsChanged()
        }
    }

    static func reactionFailureText(_ f: CommsSendFailure, kind: ReactionChange.Kind, replacing: Bool = false) -> String {
        if replacing, f.reason == .notFound {
            return "Your earlier reaction was added from another device, so it couldn't be replaced here."
        }
        switch (kind, f.reason) {
        case (.remove, .notFound):
            return "This reaction was added from another device, so it can't be removed here."
        case (_, .notFound): return "This message is no longer available."
        case (_, .rateLimited): return "Too many reactions. Try again in a moment."
        case (_, .unreachable): return "Can't reach the server. Try again."
        case (_, .unsupportedNetwork), (_, .encryptedRoom): return "Reactions aren't available in this conversation."
        case (_, .outcomeUnknown), (_, .sendFailed) where f.maybeSent:
            return kind == .add ? "Your reaction may not have been sent. Check before trying again." : "The reaction may not have been removed."
        default:
            return kind == .add ? "Couldn't send your reaction." : "Couldn't remove your reaction."
        }
    }
}
