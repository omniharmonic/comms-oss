import CommsCore
import PrismModels
import SwiftUI

/// How the transcript presents a message's overlay (iOS and Mac alike).
public enum MessageOverlayMode: Sendable, Equatable {
    /// Long press (iOS) / right-click, Control-click or Force Touch (Mac): blurred background,
    /// lifted bubble, tapback bar above, action menu below.
    case menu
    /// Double tap (iOS) / double-click (Mac): the tapback bar alone.
    case tapbacks
    /// A tap on the badges: who reacted with what.
    case details
}

extension EnvironmentValues {
    /// The transcript's overlay (set by both transcript controllers; nil in snapshots).
    @Entry var messageOverlayPresenter: (@MainActor @Sendable (String, MessageOverlayMode) -> Void)? = nil
}

/// A transcript message's interactions besides its own content:
/// - VoiceOver: "Show Menu", "React with Heart" … "React with Question Mark", "Show Reactions",
///   "Reply", "Copy";
/// - Mac: a double-click opens the tapback bar and a click on the badges who reacted (the
///   right-click / Control-click / Force Touch menu is caught by the transcript's table);
/// - iOS: the gestures live in `PhoneTranscriptController`.
/// Both report the message view's frame so the overlay can lift the bubble in place.
struct MessageInteractionModifier: ViewModifier {
    let message: CommsMessage

    @Environment(\.messageInteractions) private var interactions
    @Environment(\.messageOverlayPresenter) private var presenter
    @Environment(\.bubbleContentReporter) private var reporter

    /// The reporter key of a message's whole view (its bubbles report under the message id).
    static func rowKey(_ id: String) -> String { "row:" + id }

    private var interactive: Bool { !message.redacted && message.system == nil }

    func body(content: Content) -> some View {
        if interactive {
            platform(content)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TranscriptRowView.space)) } action: { [id = message.id] frame in
                    reporter?(MessageInteractionModifier.rowKey(id), frame)
                }
                .environment(\.reactionBadgeTap, badgeTap)
                .accessibilityActions { actions }
        } else {
            content
        }
    }

    @ViewBuilder private var actions: some View {
        if let presenter {
            Button("Show Menu") { presenter(message.id, .menu) }
        }
        if interactions.canReact(message) {
            ForEach(Tapbacks.keys, id: \.self) { key in
                let name = ClassicTapback(key: key)?.spokenName ?? key
                let mine = message.reactions.contains { $0.key == key && $0.mine }
                Button(mine ? "Remove \(name)" : "React with \(name)") { interactions.react(key, message.id) }
            }
        }
        if !message.reactions.isEmpty, let presenter {
            Button("Show Reactions") { presenter(message.id, .details) }
        }
        if interactions.canReply(message) {
            Button("Reply") { interactions.reply(message) }
        }
        if let text = MessageInteractions.text(of: message) {
            Button("Copy") { MessageInteractions.copy(text) }
        }
        if let ask = interactions.askOmni {
            Button("Ask Omni about this") { ask(message) }
        }
    }

    private var badgeTap: (@MainActor @Sendable (String) -> Void)? {
        guard let presenter else { return nil }
        return { id in presenter(id, .details) }
    }

    #if os(macOS)
    @ViewBuilder private func platform(_ content: Content) -> some View {
        // Mac Messages: a double-click opens the tapback bar (simultaneous, so single clicks on
        // links and photos are not delayed).
        content
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if interactions.canReact(message) { presenter?(message.id, .tapbacks) }
            })
    }
    #else
    @ViewBuilder private func platform(_ content: Content) -> some View { content }
    #endif
}
