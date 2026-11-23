import CommsClient
import CommsCore
import SwiftUI

/// A Telegram forum's topic switcher under the transcript header: a glass pill ("All Topics ⌄",
/// "# General ⌄") whose menu offers All Topics, then every topic, newest activity first, with
/// Messages' blue dot on the ones holding unread messages. Choosing one reloads the transcript for
/// that view; the composer then replies in that topic.
struct ForumTopicSwitcher: View {
    let topics: [CommsTopic]
    let selected: CommsTopic?
    let onSelect: @MainActor (String?) -> Void

    #if os(iOS)
    static let fontSize: CGFloat = 13
    static let padH: CGFloat = 12
    static let padV: CGFloat = 6
    #else
    static let fontSize: CGFloat = 12
    static let padH: CGFloat = 10
    static let padV: CGFloat = 4
    #endif

    var body: some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                if selected == nil { Label("All Topics", systemImage: "checkmark") } else { Text("All Topics") }
            }
            .accessibilityIdentifier("topic-all")
            Divider()
            ForEach(topics) { t in
                Button {
                    onSelect(t.id)
                } label: {
                    Label(Self.menuTitle(t, selected: selected?.id == t.id), systemImage: Self.symbol(t, selected: selected?.id == t.id))
                }
                .accessibilityLabel(Self.accessibilityTitle(t))
                .accessibilityIdentifier("topic-\(t.id)")
            }
        } label: {
            // One Text (symbols interpolated): a Mac menu button keeps a single label run.
            HStack(spacing: 4) {
                Self.title(selected)
                    .lineLimit(1)
                if Self.unreadElsewhere(topics, selected: selected) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(Image(systemName: "chevron.down"))
                    .font(.system(size: Self.fontSize - 3, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Self.padH)
            .padding(.vertical, Self.padV)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(Self.pillLabel(topics, selected: selected))
        .accessibilityHint("Chooses a topic")
        .accessibilityIdentifier("topic-switcher")
    }

    /// "# General" / "All Topics", semibold.
    static func title(_ selected: CommsTopic?) -> Text {
        let name = Text(selected?.title ?? "All Topics").font(.system(size: fontSize, weight: .semibold))
        guard selected != nil else { return name }
        return Text("\(Text(Image(systemName: "number")).font(.system(size: fontSize - 1, weight: .semibold)).foregroundStyle(.secondary)) \(name)")
    }

    /// The menu row's symbol: a check on the shown topic, Messages' unread dot, else "#".
    static func symbol(_ t: CommsTopic, selected: Bool) -> String {
        if selected { return "checkmark" }
        return t.unread > 0 ? "circle.fill" : "number"
    }
    static func menuTitle(_ t: CommsTopic, selected: Bool) -> String {
        t.unread > 0 && !selected ? "\(t.title) (\(t.unread))" : t.title
    }
    static func accessibilityTitle(_ t: CommsTopic) -> String {
        switch t.unread {
        case 0: return t.title
        case 1: return "\(t.title), 1 unread message"
        case let n: return "\(t.title), \(n) unread messages"
        }
    }
    /// A topic other than the one on screen has unread messages (the pill's dot).
    static func unreadElsewhere(_ topics: [CommsTopic], selected: CommsTopic?) -> Bool {
        guard let selected else { return false }
        return topics.contains { $0.id != selected.id && $0.unread > 0 }
    }
    static func pillLabel(_ topics: [CommsTopic], selected: CommsTopic?) -> String {
        let shown = selected.map { "Topic \($0.title)" } ?? "All Topics"
        return unreadElsewhere(topics, selected: selected) ? "\(shown), other topics have unread messages" : shown
    }
}

/// The small "# Dev" over a run of messages in a forum's All Topics.
struct TopicLabel: View {
    let title: String
    let size: CGFloat

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "number")
                .font(.system(size: size - 1, weight: .semibold))
            Text(title)
                .font(.system(size: size, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("in \(title)")
        .accessibilityIdentifier("topic-label")
    }
}

/// The transcript's composer (both platforms): in a forum's All Topics, a "To #General ⌄" chip
/// above the field says where Send posts — frozen when the owner starts typing, changed only by
/// the chip (or a reply, which answers in its message's topic and locks it). Fix round 1, C-1.
struct TranscriptComposer: View {
    let store: TimelineStore
    let dropInbox: ComposerDropInbox?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.isForum, store.selectedTopicID == nil, let target = store.composeTopic {
                ForumComposeTargetChip(target: target, topics: store.topics, locked: store.replyTarget != nil) { store.pickComposeTopic($0) }
                    .padding(.leading, ComposerBar.composerLeading)
            }
            ComposerBar(network: store.sendNetwork, canSend: store.canSend,
                        encrypted: store.isEncrypted, canAttach: !store.isEmail, maxAttachmentBytes: store.maxAttachmentBytes, dropInbox: dropInbox,
                        omniThreadID: store.threadID,
                        channelChoices: store.channelChoices, selectedChannel: store.outgoingChannel,
                        onPickChannel: { store.pickedChannel = $0 },
                        mentionCandidates: store.canMention ? { store.mentionCandidates($0) } : nil,
                        placeholder: store.composerPlaceholder,
                        onComposingChange: { store.composingChanged($0) }) { text, files, mentions in
                Task { await store.sendComposed(text: text, attachments: files, mentions: mentions) }
            }
        }
    }
}

/// "To #General ⌄": where a message typed in All Topics goes (a menu of the topics; locked while
/// replying, since a reply answers in its message's topic).
struct ForumComposeTargetChip: View {
    let target: CommsTopicRef
    let topics: [CommsTopic]
    let locked: Bool
    let onPick: @MainActor (String) -> Void

    var body: some View {
        if locked {
            label(chevron: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Replying in \(target.title)")
                .accessibilityIdentifier("compose-topic")
        } else {
            Menu {
                ForEach(topics) { t in
                    Button { onPick(t.id) } label: {
                        if t.id == target.id { Label(t.title, systemImage: "checkmark") } else { Text(t.title) }
                    }
                    .accessibilityIdentifier("compose-topic-\(t.id)")
                }
            } label: {
                label(chevron: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Sending to \(target.title)")
            .accessibilityHint("Chooses the topic this message goes to")
            .accessibilityIdentifier("compose-topic")
        }
    }

    private func label(chevron: Bool) -> some View {
        HStack(spacing: 4) {
            Text("To \(Text(Image(systemName: "number")).foregroundStyle(.secondary))\(target.title)")
                .font(.system(size: ForumTopicSwitcher.fontSize - 1, weight: .semibold))
                .lineLimit(1)
            if chevron {
                Text(Image(systemName: "chevron.down"))
                    .font(.system(size: ForumTopicSwitcher.fontSize - 4, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, ForumTopicSwitcher.padH - 2)
        .padding(.vertical, ForumTopicSwitcher.padV - 1)
        .contentShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

extension ComposerBar {
    /// Where the text field starts (the "To #…" chip lines up with it).
    static var composerLeading: CGFloat { sideMargin + plusSize + gap }
}
