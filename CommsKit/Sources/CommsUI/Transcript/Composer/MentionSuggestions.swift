import CommsClient
import SwiftUI

/// The `@` suggestions above the composer: a glass panel of matching members (avatar + name),
/// as Messages lists the people of a group when "@" is typed. Tapping one puts their name in
/// the draft.
struct MentionSuggestions: View {
    let members: [CommsMember]
    let fontSize: CGFloat
    let onPick: (CommsMember) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(members.prefix(5), id: \.id) { m in
                Button { onPick(m) } label: {
                    HStack(spacing: 10) {
                        AvatarView(m.avatar, size: fontSize + 11, name: m.name)
                        Text(m.name)
                            .font(.system(size: fontSize))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mention \(m.name)")
                .accessibilityIdentifier("mention-suggestion")
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 320, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
