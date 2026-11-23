import CommsCore
import PrismModels
import SwiftUI

/// Who reacted with what (tap a message's tapback badges). With up to three people it is the
/// iOS 26 card: each reaction in a white thought bubble over the person's avatar, their name
/// under it; with more (and always on the Mac) a list: avatar, name, their reactions.
struct ReactionDetailsView: View {
    let people: [ReactionPerson]
    var avatar: (String) -> CommsAvatar? = { _ in nil }
    var compact: Bool = {
        #if os(iOS)
        true
        #else
        false
        #endif
    }()

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if compact, people.count <= 3 {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(people) { person in column(person) }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(people) { person in row(person) }
                    }
                    .padding(.vertical, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: 280)
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reactions")
        .accessibilityIdentifier("reaction-details")
    }

    private func column(_ p: ReactionPerson) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: -10) {
                ForEach(p.keys, id: \.self) { key in
                    TapbackGlyph(key: key, size: 30)
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(scheme == .dark ? Color(white: 0.22) : .white))
                }
            }
            // The thought tail toward the avatar.
            Circle().fill(scheme == .dark ? Color(white: 0.22) : .white).frame(width: 8, height: 8)
            personAvatar(p, size: 34)
            Text(p.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 90)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(p))
        .accessibilityIdentifier("reaction-person")
    }

    private func row(_ p: ReactionPerson) -> some View {
        HStack(spacing: 10) {
            personAvatar(p, size: 30)
            Text(p.name)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(p.keys, id: \.self) { TapbackGlyph(key: $0, size: 22) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(p))
        .accessibilityIdentifier("reaction-person")
    }

    @ViewBuilder private func personAvatar(_ p: ReactionPerson, size: CGFloat) -> some View {
        if p.id.hasPrefix("others-") {
            Image(systemName: "person.2.fill")
                .font(.system(size: size * 0.45))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(LinearGradient(colors: [Color(white: 0.66), Color(white: 0.53)], startPoint: .top, endPoint: .bottom)))
                .accessibilityHidden(true)
        } else {
            SenderAvatar(sender: .init(id: p.id, name: p.name, avatar: p.isSelf ? nil : avatar(p.id), isSelf: p.isSelf), size: size)
        }
    }

    /// "Alex: Heart, Ha Ha" / "You: Thumbs Up".
    static func spoken(_ p: ReactionPerson) -> String {
        "\(p.name): " + p.keys.map { ClassicTapback(key: $0)?.spokenName ?? $0 }.joined(separator: ", ")
    }
}
