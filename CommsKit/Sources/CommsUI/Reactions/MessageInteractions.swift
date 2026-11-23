import CommsCore
import PrismModels
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What a message's long-press / right-click menu and tapbacks can do. The transcript
/// controllers put the open thread's store behind it (`.store(_:)`); `.none` offers nothing
/// but Copy (previews, snapshots).
public struct MessageInteractions: Sendable {
    /// The message as drawn now (pending reactions included); nil when it left the transcript.
    public var message: @MainActor @Sendable (String) -> CommsMessage?
    public var canReact: @MainActor @Sendable (CommsMessage) -> Bool
    /// Tap a tapback (toggle / replace, Messages' rules).
    public var react: @MainActor @Sendable (_ key: String, _ messageID: String) -> Void
    public var canReply: @MainActor @Sendable (CommsMessage) -> Bool
    public var reply: @MainActor @Sendable (CommsMessage) -> Void
    /// Who reacted with what.
    public var people: @MainActor @Sendable (String) -> [ReactionPerson]
    /// Group members by sender id (avatars in the reaction details).
    public var avatar: @MainActor @Sendable (String) -> CommsAvatar?
    /// "Ask Omni about this" (nil = Omni is off): the composer becomes Omni's instruction field
    /// with this message as context.
    public var askOmni: (@MainActor @Sendable (CommsMessage) -> Void)?

    public init(message: @escaping @MainActor @Sendable (String) -> CommsMessage? = { _ in nil },
                canReact: @escaping @MainActor @Sendable (CommsMessage) -> Bool = { _ in false },
                react: @escaping @MainActor @Sendable (String, String) -> Void = { _, _ in },
                canReply: @escaping @MainActor @Sendable (CommsMessage) -> Bool = { _ in false },
                reply: @escaping @MainActor @Sendable (CommsMessage) -> Void = { _ in },
                people: @escaping @MainActor @Sendable (String) -> [ReactionPerson] = { _ in [] },
                avatar: @escaping @MainActor @Sendable (String) -> CommsAvatar? = { _ in nil },
                askOmni: (@MainActor @Sendable (CommsMessage) -> Void)? = nil) {
        self.message = message
        self.canReact = canReact
        self.react = react
        self.canReply = canReply
        self.reply = reply
        self.people = people
        self.avatar = avatar
        self.askOmni = askOmni
    }

    public static let none = MessageInteractions()

    /// Interactions on `store`'s messages.
    @MainActor public static func store(_ store: TimelineStore, omni: OmniStore? = nil) -> MessageInteractions {
        let threadID = store.threadID
        var ask: (@MainActor @Sendable (CommsMessage) -> Void)?
        if let omni, omni.isAvailable {
            ask = { [weak omni] (m: CommsMessage) in omni?.beginAsk(threadID: threadID, about: m.id) }
        }
        return MessageInteractions(
            message: { [weak store] id in
                store?.rows.lazy.compactMap { if case .message(let m, _, _, _) = $0, m.id == id { m } else { nil } }.first
            },
            canReact: { [weak store] m in store?.canReact(to: m) ?? false },
            react: { [weak store] key, id in
                RecentReactions.note(key)
                store?.react(key, on: id)
            },
            canReply: { [weak store] m in store?.offersReply(to: m) ?? false },
            reply: { [weak store] m in store?.beginReply(to: m) },
            people: { [weak store] id in store?.reactionPeople(on: id) ?? [] },
            avatar: { [weak store] senderID in
                guard let store else { return nil }
                if let a = store.members.first(where: { $0.id == senderID })?.avatar { return a }
                return store.rows.lazy.compactMap { if case .message(let m, _, _, _) = $0, m.sender.id == senderID { m.sender.avatar } else { nil } }.first
            },
            askOmni: ask)
    }

    /// The text Copy / Translate / Select work on (nil when the message has none).
    static func text(of m: CommsMessage) -> String? {
        guard !m.redacted, m.system == nil, let t = m.body?.plain.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    @MainActor static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

extension EnvironmentValues {
    @Entry public var messageInteractions: MessageInteractions = .none
    /// A tap on a message's tapback badges (iOS: the transcript shows who reacted). Nil = the
    /// badges are not interactive (snapshots, the lifted copy in the menu).
    @Entry var reactionBadgeTap: (@MainActor @Sendable (String) -> Void)? = nil
    /// Where a message's bubbles are drawn (the iOS transcript places its long-press menu by it):
    /// (message id, frame in `TranscriptRowView.space`).
    @Entry var bubbleContentReporter: (@MainActor @Sendable (String, CGRect) -> Void)? = nil
}

/// One row of the message menu.
struct MessageMenuItem: Identifiable {
    enum Kind: String { case reply, copy, translate, select, showReactions, askOmni }
    let kind: Kind
    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .reply: "Reply"
        case .copy: "Copy"
        case .translate: "Translate"
        case .select: "Select"
        case .showReactions: "Show Reactions…"
        case .askOmni: "Ask Omni about this"
        }
    }

    var systemImage: String {
        switch kind {
        case .reply: "arrowshape.turn.up.left"
        case .copy: "doc.on.doc"
        case .translate: "translate"
        case .select: "crop"
        case .showReactions: "face.smiling"
        case .askOmni: "sparkle"
        }
    }

    /// Messages' groups: [Reply] | [Copy, Translate, Select] (separators between them).
    /// Mac (no Select): `showReactions` adds a third group, "Show Reactions…".
    @MainActor static func groups(for m: CommsMessage, interactions: MessageInteractions, platformSelect: Bool,
                                  showReactions: Bool = false) -> [[MessageMenuItem]] {
        var first: [MessageMenuItem] = []
        if interactions.canReply(m) { first.append(.init(kind: .reply)) }
        var second: [MessageMenuItem] = []
        if MessageInteractions.text(of: m) != nil {
            second.append(.init(kind: .copy))
            second.append(.init(kind: .translate))
            if platformSelect { second.append(.init(kind: .select)) }
        }
        let third: [MessageMenuItem] = showReactions ? [.init(kind: .showReactions)] : []
        // Omni (PRD §5.7): its own group at the end, as Messages keeps app actions apart.
        let fourth: [MessageMenuItem] = interactions.askOmni != nil && !m.redacted && m.system == nil ? [.init(kind: .askOmni)] : []
        return [first, second, third, fourth].filter { !$0.isEmpty }
    }
}

/// Messages' glass action menu under a lifted bubble (iOS long press).
struct MessageActionMenu: View {
    let groups: [[MessageMenuItem]]
    let action: (MessageMenuItem.Kind) -> Void

    #if os(macOS)
    static let width: CGFloat = 220
    static let rowHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 14
    static let iconSize: CGFloat = 14
    static let rowInset: CGFloat = 12
    #else
    static let width: CGFloat = 250
    static let rowHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 30
    static let iconSize: CGFloat = 19
    static let rowInset: CGFloat = 20
    #endif

    static func height(_ groups: [[MessageMenuItem]]) -> CGFloat {
        CGFloat(groups.reduce(0) { $0 + $1.count }) * rowHeight + CGFloat(max(0, groups.count - 1)) * 9 + 16
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { i, group in
                if i > 0 {
                    Rectangle().fill(.separator).frame(height: 0.5).padding(.horizontal, 20).padding(.vertical, 4)
                }
                ForEach(group) { item in
                    Button { action(item.kind) } label: {
                        HStack(spacing: Self.rowInset * 0.7) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: Self.iconSize))
                                .frame(width: Self.iconSize + 7)
                            Text(item.title)
                                .font(.body)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, Self.rowInset)
                        .frame(minHeight: Self.rowHeight)
                        .contentShape(.rect)
                    }
                    .buttonStyle(MenuRowStyle())
                    .accessibilityIdentifier("message-menu-\(item.kind.rawValue)")
                }
            }
        }
        .padding(.vertical, Self.rowHeight > 30 ? 8 : 5)
        .frame(width: Self.width)
        .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message-menu")
    }
}

struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : .clear, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 6)
    }
}
