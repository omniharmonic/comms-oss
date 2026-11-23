import PrismModels
import SwiftUI

/// The quoted parent above a reply, drawn light as Messages does: no box — small grey text
/// ("You" / the sender's name, then a short excerpt) beside a thin rounded connector line on
/// the reply's side, sitting just above the reply's bubble. The parent's own bubble colour is
/// not on the wire (`replyTo` carries only id, snippet and sender name; the server names the
/// owner "You" and the agent "Omni"). The thread view with "N Replies" is Phase 2.
///
/// VoiceOver reads it as part of the message ("Replying to Alex: …"), so it is hidden here.
struct ReplyQuote: View {
    let reply: CommsMessage.Reply
    let outgoing: Bool

    @Environment(\.bubbleMetrics) private var metrics
    @Environment(\.bubbleMaxWidth) private var maxWidth
    @Environment(\.colorScheme) private var scheme

    /// Shown when the parent had no text (a photo, a sticker).
    static let emptySnippet = "Message"

    static func snippet(_ reply: CommsMessage.Reply) -> String {
        let s = reply.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? emptySnippet : s
    }

    /// The quoted sender as shown ("You" when the server says so; never an account id).
    static func name(_ reply: CommsMessage.Reply) -> String {
        let n = reply.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Message" : n
    }

    var body: some View {
        let palette = BubblePalette(scheme: scheme)
        let connector = Capsule()
            .fill(palette.replyConnector)
            .frame(width: 2)
        MaxWidthLayout(maxWidth: maxWidth) {
            HStack(alignment: .top, spacing: 6) {
                if !outgoing { connector }
                VStack(alignment: outgoing ? .trailing : .leading, spacing: 1) {
                    Text(Self.name(reply))
                        .font(.system(size: metrics.captionSize, weight: .semibold))
                        .lineLimit(1)
                    Text(Self.snippet(reply))
                        .font(.system(size: metrics.captionSize))
                        .lineLimit(2)
                }
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(outgoing ? .trailing : .leading)
                if outgoing { connector }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, metrics.padH * 0.5)
            .padding(.bottom, 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }
}

extension BubblePalette {
    /// The thin line beside a quoted parent.
    var replyConnector: Color { scheme == .dark ? Color.white.opacity(0.3) : Color.black.opacity(0.2) }
}
