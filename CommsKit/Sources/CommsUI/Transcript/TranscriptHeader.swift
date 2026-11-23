import CommsClient
import SwiftUI

/// The transcript's floating header (UX spec §5/§9): a centred avatar overlapping a glass
/// name pill ("Alice Example ›"). Clicking either toggles the Details inspector (⌥⌘I).
/// The transcript scrolls under it.
public struct TranscriptHeader: View {
    let thread: CommsThread?
    /// A second, secondary line under the name (Messages shows the contact's subtitle, e.g.
    /// a city); nil = a one-line pill.
    let subtitle: String?
    @Binding var isInspectorPresented: Bool

    public init(thread: CommsThread?, subtitle: String? = nil, isInspectorPresented: Binding<Bool>) {
        self.thread = thread
        self.subtitle = subtitle
        _isInspectorPresented = isInspectorPresented
    }

    #if os(iOS)
    // The real iOS 27 app (design/fidelity/apple-ios/transcript-light.ax.txt): a 60 pt avatar
    // at the top of the nav bar, the glass name pill (32.3 pt tall) starting 5 pt above the
    // avatar's bottom; name Bold 16, chevron Bold 14 at 30 %.
    static let avatarSize: CGFloat = 60
    static let overlap: CGFloat = 5
    static let nameSize: CGFloat = 16
    static let nameWeight: Font.Weight = .bold
    static let chevronSize: CGFloat = 12
    static let pillPadH: CGFloat = 13
    static let pillPadV: CGFloat = 6.5
    /// The name is centred in the whole pill (its top edge just tucks under the avatar).
    static let pillTopExtra: CGFloat = 0
    #else
    // Mac guide (≈ 0.81 px/pt): avatar 31 px ≈ 38 pt at the top of the toolbar band.
    static let avatarSize: CGFloat = 38
    /// How far the pill tucks under the avatar.
    static let overlap: CGFloat = 6
    static let nameSize: CGFloat = 13
    static let nameWeight: Font.Weight = .semibold
    static let chevronSize: CGFloat = 9
    static let pillPadH: CGFloat = 12
    static let pillPadV: CGFloat = 5
    static let pillTopExtra: CGFloat = overlap
    #endif

    public var body: some View {
        VStack(spacing: -Self.overlap) {
            AvatarView(thread?.avatar, kind: thread?.kind ?? .dm, size: Self.avatarSize, badge: thread?.networks.first, name: thread?.title)
                .zIndex(1)
                .onTapGesture { isInspectorPresented.toggle() }
                .accessibilityHidden(true)
            Button {
                isInspectorPresented.toggle()
            } label: {
                VStack(spacing: 0) {
                    HStack(spacing: 3) {
                        Text(thread?.title ?? " ")
                            .font(.system(size: Self.nameSize, weight: Self.nameWeight))
                            .lineLimit(1)
                        if thread?.needsTidy == true {
                            // PRD §5.11a: a subtle dot until "Who is this?" is answered.
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                                .accessibilityIdentifier("transcript-tidy-dot")
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: Self.chevronSize, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    if let subtitle, !subtitle.isEmpty {
                        // Owner's device: a 48 pt two-line pill, the subtitle secondary.
                        Text(subtitle)
                            .font(.system(size: Self.nameSize - 3))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, Self.pillPadH)
                .padding(.top, Self.pillPadV + Self.pillTopExtra)
                .padding(.bottom, Self.pillPadV)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .keyboardShortcut("i", modifiers: [.command, .option])
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(isInspectorPresented ? "Hides the details" : "Shows details")
            .accessibilityIdentifier("transcript-name-pill")
        }
        .frame(maxWidth: 320)
    }

    private var accessibilityLabel: String {
        guard let thread else { return "Conversation" }
        let networks = thread.networks.map(\.displayName).joined(separator: ", ")
        let base = networks.isEmpty ? thread.title : "\(thread.title), \(networks)"
        return thread.needsTidy == true ? "\(base), not in your people yet" : base
    }
}
