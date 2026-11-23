import CommsCore
import PrismModels
import SwiftUI

/// One email as a bubble (PRD §5.8): the subject in bold with a "to you, Cc 2" caption, the
/// newly written text, the quoted history and signature collapsed behind Mail's "…" button, and
/// "View Full Email" for an HTML or long message (a sandboxed sheet, `EmailOriginalView`).
/// Same fill, shape and tail as a text bubble; the body is plain text (never Markdown).
struct EmailBubbleText: View {
    let message: CommsMessage
    let email: CommsMessage.Email
    let body_: CommsRichText?
    let outgoing: Bool
    let tail: Bool
    let fill: BubbleFill

    @Environment(\.bubbleMetrics) private var metrics
    @Environment(\.bubbleMaxWidth) private var maxWidth
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sendActions) private var actions
    @Environment(\.emailOriginalOpener) private var openerOverride
    private var openOriginal: (@MainActor (String) -> Void)? {
        if let openerOverride { return openerOverride }
        guard let f = actions.openEmailOriginal else { return nil }
        return { id in f(id) }
    }
    @State private var expanded: Bool

    init(message: CommsMessage, email: CommsMessage.Email, outgoing: Bool, tail: Bool, fill: BubbleFill, expanded: Bool = false) {
        self.message = message
        self.email = email
        self.body_ = message.body
        self.outgoing = outgoing
        self.tail = tail
        self.fill = fill
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        let color = BubblePalette(scheme: scheme).text(outgoing: outgoing)
        let parts = Self.split(body_)
        MaxWidthLayout(maxWidth: maxWidth) {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(email.subject.isEmpty ? "(No Subject)" : email.subject)
                        .font(.system(size: metrics.bodySize, weight: .semibold))
                        .accessibilityIdentifier("email-subject")
                    Text(Self.caption(email, outgoing: outgoing))
                        .font(.system(size: metrics.captionSize))
                        .opacity(0.65)
                }
                if let fresh = parts.fresh {
                    RichTextView(fresh, outgoing: outgoing)
                }
                if let quoted = parts.quoted {
                    if expanded {
                        RichTextView(quoted, outgoing: outgoing)
                            .transition(.opacity)
                    }
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: metrics.captionSize, weight: .bold))
                            .frame(width: 30, height: 16)
                            .background(Capsule().fill(color.opacity(0.14)))
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Hide Quoted Text" : "Show Quoted Text")
                    .accessibilityIdentifier("email-quoted-toggle")
                }
                if Self.offersFullEmail(email, body: body_), let openOriginal, PendingSend.clientID(ofMessageID: message.id) == nil {
                    Button { openOriginal(message.id) } label: {
                        HStack(spacing: 2) {
                            Text("View Full Email")
                            Image(systemName: "chevron.forward").font(.system(size: metrics.captionSize - 2, weight: .semibold))
                        }
                        .font(.system(size: metrics.captionSize, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityIdentifier("email-view-full")
                }
            }
            .foregroundStyle(color)
            .padding(.horizontal, metrics.padH)
            .padding(.vertical, metrics.padV + 2)
            .frame(minWidth: metrics.minHeight, minHeight: metrics.minHeight, alignment: .leading)
            .background(BubbleFillView(shape: BubbleShape(tail: tail, outgoing: outgoing, radius: metrics.radius), fill: fill))
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("email-bubble")
    }

    /// "to you", "to you & 2 others, Cc 1" (incoming: the owner is a recipient); outgoing:
    /// "to ann@x.test, Cc 2".
    static func caption(_ e: CommsMessage.Email, outgoing: Bool) -> String {
        var s: String
        if outgoing {
            s = e.to.isEmpty ? "to —" : "to \(e.to[0])" + (e.to.count > 1 ? " & \(e.to.count - 1) more" : "")
        } else {
            let others = max(0, e.to.count - 1)
            s = others == 0 ? "to you" : "to you & \(others) other\(others == 1 ? "" : "s")"
        }
        if !e.cc.isEmpty { s += ", Cc \(e.cc.count)" }
        return s
    }

    /// The server collapses quoted history + signature into ONE top-level `quote` span at the end.
    static func split(_ body: CommsRichText?) -> (fresh: CommsRichText?, quoted: CommsRichText?) {
        guard let body else { return (nil, nil) }
        guard case .quote(let q)? = body.spans.last else { return (body.plain.isEmpty && body.spans.isEmpty ? nil : body, nil) }
        let top = Array(body.spans.dropLast())
        return (top.isEmpty ? nil : CommsRichText(spans: top, plain: body.plain), CommsRichText(spans: q, plain: ""))
    }

    /// HTML, a body the server truncated, or a long one: the full message has more to show.
    static func offersFullEmail(_ e: CommsMessage.Email, body: CommsRichText?) -> Bool {
        e.hasHtml || (body?.truncated ?? false) || (body?.plain.count ?? 0) > 1_500
    }
}

extension EnvironmentValues {
    /// Opens "View Full Email" for a message id (the transcript installs it).
    @Entry public var emailOriginalOpener: (@MainActor (String) -> Void)? = nil
}
