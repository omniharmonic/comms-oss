import CommsCore
import PrismModels
import SwiftUI

/// Above the composer while replying: "Replying to Alex" and the quoted text, with ✕.
struct ReplyComposeBanner: View {
    let message: CommsMessage
    /// Where replies can't be threaded (iMessage / SMS): "Sent as a normal message — …".
    var note: String? = nil
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(Tokens.color.accent.color).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(message.sender.isSelf ? "yourself" : message.sender.name)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tokens.color.accent.color)
                Text(MessageInteractions.text(of: message) ?? MessageBubble.accessibilityLabel(for: message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("reply-note")
                }
            }
            Spacer(minLength: 8)
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel Reply")
            .accessibilityIdentifier("reply-cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reply-banner")
    }
}

/// A short glass notice after a reaction failed; goes by itself after a few seconds.
struct ReactionNoticeToast: View {
    let notice: ReactionNotice?
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            if let notice {
                Text(notice.text)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 24)
                    .onTapGesture(perform: dismiss)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(4))
                        dismiss()
                    }
                    .accessibilityIdentifier("reaction-notice")
                    .onAppear { AccessibilityNotification.Announcement(notice.text).post() }
            }
        }
        .animation(.snappy, value: notice)
    }
}
