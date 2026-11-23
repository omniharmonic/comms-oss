import CommsClient
import Foundation

/// Where a message sits in a run of consecutive messages from one sender. The tail is drawn
/// only on `.single` and `.last` (UX spec §5). The only run-position type: the layout
/// produces it and `MessageBubble` consumes it.
public enum RunPosition: Sendable, Hashable, CustomStringConvertible {
    case single, first, middle, last

    public var hasTail: Bool { self == .single || self == .last }
    /// The first message of a run carries the group sender name.
    public var startsRun: Bool { self == .single || self == .first }

    public var description: String {
        switch self {
        case .single: "single"
        case .first: "first"
        case .middle: "middle"
        case .last: "last"
        }
    }
}

/// One row of the transcript, oldest first.
public enum TranscriptRow: Identifiable, Hashable, Sendable {
    /// A centred time header, carrying the send time of the message it introduces.
    case time(Date)
    /// A message, its place in its sender's run, and (groups, incoming) whether this row shows
    /// the sender's name (first of the run) and avatar (last of the run).
    case message(CommsMessage, RunPosition, showSenderName: Bool, showAvatar: Bool)
    /// A centred system line ("Alex joined"), id = the message id.
    case system(String, id: String)

    /// Stable across reloads: a message or system row is its message id; a time row is its
    /// date (two headers never share one: they are over an hour or a day apart).
    public var id: String {
        switch self {
        case .time(let date): return "time:\(date.timeIntervalSince1970)"
        case .message(let m, _, _, _): return m.id
        case .system(_, let id): return id
        }
    }

    /// The row's identity on screen (diffing, anchors, cell identity). A message sent from this
    /// device keeps ONE identity from its pending bubble to the server's echo: both are keyed
    /// by the send's clientId (`pending-<clientId>`), so the swap updates the row in place —
    /// never a frame with the pending bubble and the echo at once, never an insert + delete.
    /// Everything else is `id`.
    public var diffID: String {
        if case .message(let m, _, _, _) = self, let c = m.clientId, !c.isEmpty {
            return PendingSend.messageID(for: c.lowercased())
        }
        return id
    }
}

/// Apple Messages' grouping rules (UX spec §5):
/// - a time row before the first message, and before any message more than `gapMinutes`
///   after the previous one or on a different local day;
/// - runs break on a sender change, a time row, a system row or an unsent message;
/// - in groups, an incoming run shows the sender's name on its first message and the
///   sender's avatar on its last.
public enum TranscriptLayout {
    /// `messages` oldest first (the server's order). `gapMinutes` is
    /// `Tokens.transcript.timeHeaderGapMinutes` (60).
    public static func rows(for messages: [CommsMessage], isGroup: Bool, gapMinutes: Int, calendar: Calendar) -> [TranscriptRow] {
        let gap = TimeInterval(gapMinutes * 60)

        // Pass 1: where time headers go, and which messages can be part of a run.
        enum Item { case time(Date), system(CommsMessage), message(CommsMessage) }
        var items: [Item] = []
        items.reserveCapacity(messages.count + messages.count / 8 + 1)
        var previous: Date?
        for m in messages {
            if let p = previous {
                if m.sentAt.timeIntervalSince(p) > gap || !calendar.isDate(m.sentAt, inSameDayAs: p) { items.append(.time(m.sentAt)) }
            } else {
                items.append(.time(m.sentAt))
            }
            previous = m.sentAt
            items.append(m.system != nil && !m.redacted ? .system(m) : .message(m))
        }

        // Pass 2: run positions. A message joins the previous one's run when both are ordinary
        // (not unsent) messages from the same sender with nothing between them.
        func joinable(_ m: CommsMessage) -> Bool { !m.redacted }
        func sameRun(_ a: Item?, _ b: Item?) -> Bool {
            guard case .message(let x)? = a, case .message(let y)? = b, joinable(x), joinable(y) else { return false }
            // A forum's All Topics: a run never crosses topics (each run is labelled with its topic).
            return x.sender.id == y.sender.id && x.topic?.id == y.topic?.id
        }

        var rows: [TranscriptRow] = []
        rows.reserveCapacity(items.count)
        for (i, item) in items.enumerated() {
            switch item {
            case .time(let d):
                rows.append(.time(d))
            case .system(let m):
                rows.append(.system(m.system?.text ?? "", id: m.id))
            case .message(let m):
                let joinsPrevious = i > 0 && sameRun(items[i - 1], item)
                let joinsNext = i + 1 < items.count && sameRun(item, items[i + 1])
                let position: RunPosition = switch (joinsPrevious, joinsNext) {
                case (false, false): .single
                case (false, true): .first
                case (true, true): .middle
                case (true, false): .last
                }
                let decorated = isGroup && !m.sender.isSelf && !m.redacted
                rows.append(.message(m, position, showSenderName: decorated && position.startsRun, showAvatar: decorated && position.hasTail))
            }
        }
        return rows
    }
}
