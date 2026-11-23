import CommsCore
import PrismModels
import SwiftUI

/// One message in the transcript, Messages-style: its attachments, text and link previews as
/// separate bubbles stacked with the same-sender gap, the tail on the last of them (when the
/// run position has one), tapbacks on the first. Incoming is grey on every network; outgoing
/// is the network's blue (`BubbleFill`). Emoji-only text renders jumbo with no bubble.
/// Redacted and system messages render as a centred caption.
///
/// A reply shows its quoted parent (`ReplyQuote`, an outline bubble) above its bubbles.
///
/// Groups: an incoming run shows the sender's name above its first bubble and the sender's
/// avatar beside its last (every incoming group run has an avatar, D16).
///
/// Sizes come from `\.bubbleMetrics`, the width cap from `\.bubbleMaxWidth`, media from
/// `\.mediaLoader`. (The plan's `mediaURL:` closure is replaced by that loader so media goes
/// only through the authenticated backend.)
public struct MessageBubble: View {
    let message: CommsMessage
    let position: RunPosition
    let isGroup: Bool

    @Environment(\.bubbleMetrics) private var metrics
    @Environment(\.bubbleMaxWidth) private var maxWidth
    @Environment(\.colorScheme) private var scheme
    @Environment(\.selfSenderIDs) private var selfIDs
    @Environment(\.reactionBadgeTap) private var badgeTap
    @Environment(\.bubbleContentReporter) private var reporter
    @Environment(\.sendActions) private var sendActions

    public init(message: CommsMessage, position: RunPosition, isGroup: Bool) {
        self.message = message
        self.position = position
        self.isGroup = isGroup
    }

    var outgoing: Bool { message.sender.isSelf }
    var fill: BubbleFill { BubbleFill(message: message) }

    public var body: some View {
        Group {
            if message.redacted {
                SystemCaption(actor: outgoing ? "You" : message.sender.shownName, text: " unsent a message")
            } else if let system = message.system {
                SystemCaption(actor: nil, text: system.text)
            } else {
                row
            }
        }
        // A message is never compressible: a parent offering less height than it needs gets
        // the full height anyway, so the background can never shrink under its text (F1).
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Layout

    private var showsAvatarColumn: Bool { isGroup && !outgoing }

    private var row: some View {
        HStack(alignment: .bottom, spacing: metrics.avatarGap) {
            if showsAvatarColumn {
                Group {
                    if position.hasTail {
                        SenderAvatar(sender: message.sender, size: metrics.groupAvatar)
                            // The avatar's bottom lines up with the tail tip (CALIBRATION).
                            .offset(y: metrics.tailDrop)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: metrics.groupAvatar, height: metrics.groupAvatar)
            }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: metrics.gapSameSender) {
                if let topic = message.topic, position.startsRun {
                    // A forum's All Topics: which topic this run was posted in.
                    TopicLabel(title: topic.title, size: metrics.captionSize - 1)
                        .padding(.leading, outgoing ? 0 : metrics.padH)
                        .padding(.trailing, outgoing ? metrics.padH : 0)
                }
                if isGroup, !outgoing, position.startsRun {
                    Text(message.sender.shownName)
                        .font(.system(size: metrics.captionSize))
                        .foregroundStyle(BubblePalette(scheme: scheme).secondary)
                        .padding(.leading, metrics.padH)
                        .lineLimit(1)
                }
                if let reply = message.replyTo {
                    ReplyQuote(reply: reply, outgoing: outgoing)
                }
                let parts = self.parts
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    partView(part, tail: position.hasTail && i == parts.count - 1)
                        .reactionBadges(i == 0 ? message.reactions : [], outgoing: outgoing, metrics: metrics,
                                        onTap: badgeTap.map { tap in { [id = message.id] in tap(id) } })
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TranscriptRowView.space)) } action: { [id = message.id] frame in
                reporter?(id, frame)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: message, selfIDs: selfIDs))
        // The combined label hides the children's own actions, so the row carries them:
        // "Open photo" (Quick Look) and "Open link …" for every picture and link.
        .accessibilityActions {
            ForEach(Self.accessibilityActions(for: message), id: \.self) { action in
                Button(action.name) { action.perform() }
            }
            // Email: "View Full Email" (the bubble's own button is inside the combined element).
            if let email = message.email, EmailBubbleText.offersFullEmail(email, body: message.body),
               PendingSend.clientID(ofMessageID: message.id) == nil, let open = sendActions.openEmailOriginal {
                Button("View Full Email") { [id = message.id] in open(id) }
            }
        }
        // After the accessibility element: VoiceOver's frame hugs the bubbles (as in Messages),
        // not the whole row.
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }

    enum Part {
        case attachment(CommsAttachment)
        case email(CommsMessage.Email)
        case text(CommsRichText)
        case jumbo(String)
        case preview(CommsLinkPreview)
    }

    /// Attachments first, then the text, then link previews (a text that is only the preview's
    /// URL is dropped: the card stands for it).
    var parts: [Part] {
        var out: [Part] = message.attachments.map(Part.attachment)
        // An email is one bubble: subject, caption, body (never jumbo, no link-preview folding).
        if let email = message.email {
            out.append(.email(email))
            return out + message.linkPreviews.map(Part.preview)
        }
        if let body = message.body, !body.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if body.jumboEmoji {
                out.append(.jumbo(body.plain))
            } else if !message.linkPreviews.contains(where: { LinkPreviewCard.isBareURL(body.plain, of: $0) }) {
                out.append(.text(body))
            }
        }
        out += message.linkPreviews.map(Part.preview)
        if out.isEmpty, let body = message.body { out.append(.text(body)) }
        return out
    }

    @ViewBuilder
    private func partView(_ part: Part, tail: Bool) -> some View {
        switch part {
        case .attachment(let a):
            MediaBubble(a, fill: fill, tail: tail)
        case .email(let e):
            EmailBubbleText(message: message, email: e, outgoing: outgoing, tail: tail, fill: fill)
        case .text(let t):
            MaxWidthLayout(maxWidth: maxWidth) {
                RichTextView(t, outgoing: outgoing)
                    .padding(.horizontal, metrics.padH)
                    .padding(.vertical, metrics.padV)
                    .frame(minWidth: metrics.minHeight, minHeight: metrics.minHeight)
                    .background(BubbleFillView(shape: BubbleShape(tail: tail, outgoing: outgoing, radius: metrics.radius), fill: fill))
            }
            .fixedSize(horizontal: false, vertical: true)
        case .jumbo(let s):
            Text(s)
                .font(.system(size: metrics.jumboEmojiSize))
                .fixedSize()
        case .preview(let p):
            LinkPreviewCard(p, outgoing: outgoing, tail: tail)
        }
    }
}

/// A VoiceOver action on a message row (the row is one combined element, so the photo's and
/// links' own actions would otherwise be unreachable).
public struct BubbleAccessibilityAction: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        case media(CommsAttachment)
        case link(URL)
    }

    public let name: String
    public let target: Target

    /// Quick Look for media; the system for links (already scheme-checked by `SafeLinks`).
    @MainActor public func perform() {
        switch target {
        case .media(let a):
            if a.kind == .voice || a.kind == .audio { VoicePlayer.shared.toggle(a) } else { MediaViewer.shared.open(a) }
        case .link(let url): SafeLinks.opener(url)
        }
    }
}

extension MessageBubble {
    /// "Open photo" / "Open video" for each picture that opens in Quick Look, then
    /// "Open link <title or host>" for each link preview (http/https) and each allowed link
    /// in the text (http/https/mailto), without repeating a URL.
    public static func accessibilityActions(for message: CommsMessage) -> [BubbleAccessibilityAction] {
        guard !message.redacted, message.system == nil else { return [] }
        var out: [BubbleAccessibilityAction] = []
        var photos = 0, videos = 0
        for a in message.attachments where a.mediaToken ?? a.thumbToken != nil {
            switch a.kind {
            case .image:
                photos += 1
                out.append(.init(name: photos == 1 ? "Open photo" : "Open photo \(photos)", target: .media(a)))
            case .video:
                videos += 1
                out.append(.init(name: videos == 1 ? "Open video" : "Open video \(videos)", target: .media(a)))
            case .voice where a.mediaToken != nil, .audio where a.mediaToken != nil:
                out.append(.init(name: "Play audio message", target: .media(a)))
            default:
                break
            }
        }
        var seen = Set<String>()
        func add(_ url: URL, label: String) {
            guard seen.insert(url.absoluteString).inserted else { return }
            out.append(.init(name: "Open link \(label)", target: .link(url)))
        }
        for p in message.linkPreviews {
            if let url = SafeLinks.webURL(p.url) { add(url, label: p.title ?? LinkPreviewCard.host(p.url)) }
        }
        func walk(_ spans: [CommsSpan]) {
            for span in spans {
                switch span {
                case .link(let href, _):
                    if let url = SafeLinks.textURL(href) {
                        let label = url.scheme?.lowercased() == "mailto"
                            ? String(url.absoluteString.dropFirst("mailto:".count))
                            : LinkPreviewCard.host(url.absoluteString)
                        add(url, label: label)
                    }
                case .bold(let c), .italic(let c), .strike(let c), .code(let c), .quote(let c), .listItem(let c):
                    walk(c)
                default:
                    break
                }
            }
        }
        walk(message.body?.spans ?? [])
        return out
    }

    /// The VoiceOver label: "<Sender or You>: <text>", then the quoted parent ("Replying to
    /// Sam: <snippet>"), then the attachments ("Photo",
    /// "Voice message 0:07", "Link: <title>"), then the reactions ("Loved by you and Alex").
    /// `selfIDs` are the owner's sender ids (the message's own sender counts when it is self).
    public static func accessibilityLabel(for message: CommsMessage, selfIDs: Set<String> = []) -> String {
        if message.redacted { return "\(message.sender.isSelf ? "You" : message.sender.shownName) unsent a message" }
        if let system = message.system { return system.text }
        var ids = selfIDs
        if message.sender.isSelf { ids.insert(message.sender.id) }

        var parts: [String] = []
        // A forum's All Topics names the topic too ("Ann in Dev: …").
        let who = (message.sender.isSelf ? "You" : message.sender.shownName) + (message.topic.map { " in \($0.title)" } ?? "")
        let text = message.body?.plain.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previews = message.linkPreviews
        let bareURL = previews.contains { LinkPreviewCard.isBareURL(text, of: $0) }
        if let email = message.email {
            let subject = email.subject.isEmpty ? "No subject" : email.subject
            parts.append(text.isEmpty ? "\(who), email: \(subject)" : "\(who), email: \(subject). \(text)")
        } else {
            parts.append(text.isEmpty || bareURL ? who : "\(who): \(text)")
        }
        if let reply = message.replyTo {
            parts.append("Replying to \(reply.senderName): \(ReplyQuote.snippet(reply))")
        }
        for a in message.attachments {
            switch a.kind {
            case .image: parts.append("Photo")
            case .video: parts.append("Video")
            case .sticker: parts.append("Sticker")
            case .voice: parts.append("Voice message \(spokenDuration(a.durationMs))")
            case .audio: parts.append("Audio \(spokenDuration(a.durationMs))")
            case .file: parts.append("File \(a.name ?? "")".trimmingCharacters(in: .whitespaces))
            case .location: parts.append("Location")
            case .unknown: parts.append("Attachment")
            }
        }
        for p in previews { parts.append("Link: \(p.title ?? LinkPreviewCard.host(p.url))") }
        for r in message.reactions { parts.append(ReactionBadges.phrase(r, selfIDs: ids)) }
        return parts.joined(separator: ". ")
    }

    /// 7 000 ms → "0:07".
    static func spokenDuration(_ ms: Int?) -> String {
        let s = max(0, (ms ?? 0) / 1000)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// A centred transcript caption ("Alex unsent a message"): secondary, with the actor semibold.
struct SystemCaption: View {
    let actor: String?
    let text: String

    @Environment(\.bubbleMetrics) private var metrics

    var body: some View {
        var s = AttributedString()
        if let actor {
            var a = AttributedString(actor)
            a.font = .system(size: metrics.captionSize, weight: .semibold)
            s += a
        }
        var rest = AttributedString(text)
        rest.font = .system(size: metrics.captionSize)
        s += rest
        return Text(s)
            .foregroundStyle(Tokens.color.secondaryLabel.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }
}

/// A group sender's avatar: their picture through the media loader, or a monogram on
/// Apple's grey gradient.
struct SenderAvatar: View {
    let sender: CommsMessage.Sender
    let size: CGFloat

    var body: some View {
        ZStack {
            if sender.isOmniAgent {
                // Omni (its own bridge account, e.g. the Omni Telegram bot): the sparkle.
                LinearGradient(colors: [Color(red: 0.45, green: 0.42, blue: 0.98), Color(red: 0.62, green: 0.36, blue: 0.94)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                LinearGradient(colors: [Color(white: 0.66), Color(white: 0.53)], startPoint: .top, endPoint: .bottom)
                Text(Self.initials(sender.name))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            if case .token(let token) = sender.avatar {
                MediaImageView(token: token, placeholder: .clear, retryable: false)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).filter { $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

extension CommsMessage.Sender {
    /// Omni speaking from its own account on the other side of the chat (never the owner).
    var isOmniAgent: Bool { isOmni && !isSelf }
    /// The name a bubble shows: "Omni" for the agent's own accounts, else the sender's.
    var shownName: String { isOmniAgent ? "Omni" : name }
}
