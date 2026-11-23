import PrismModels
import SwiftUI

/// The six classic Messages tapbacks. Apple draws them as MONOCHROME glyphs (white on blue
/// for mine, grey on grey for others), never as colour emoji; any other emoji keeps its colour.
public enum ClassicTapback: String, CaseIterable, Sendable {
    case love, like, dislike, laugh, emphasize, question

    /// Recognises the emoji and text keys networks send ("❤️", "♥️", "heart", "👍🏽", "+1",
    /// "😂", "haha", "HA HA", "‼️", "!!", "❓", "?", …).
    public init?(key: String) {
        let k = String(String.UnicodeScalarView(key.unicodeScalars.filter {
            $0.value != 0xFE0F && $0.value != 0xFE0E && !(0x1F3FB...0x1F3FF).contains($0.value)
        })).trimmingCharacters(in: .whitespaces).lowercased()
        switch k {
        case "❤", "♥", "heart", "love": self = .love
        case "👍", "like", "thumbsup", "+1": self = .like
        case "👎", "dislike", "thumbsdown", "-1": self = .dislike
        case "😂", "haha", "ha ha", "laugh": self = .laugh
        case "‼", "!!", "emphasize", "emphasis": self = .emphasize
        case "❓", "❔", "?", "question": self = .question
        default: return nil
        }
    }

    /// SF Symbol for the glyph (laugh is the "HA HA" wordmark instead).
    var symbol: String? {
        switch self {
        case .love: "heart.fill"
        case .like: "hand.thumbsup.fill"
        case .dislike: "hand.thumbsdown.fill"
        case .emphasize: "exclamationmark.2"
        case .question: "questionmark"
        case .laugh: nil
        }
    }

    /// VoiceOver verb: "Loved by you and Alex".
    public var verb: String {
        switch self {
        case .love: "Loved"
        case .like: "Liked"
        case .dislike: "Disliked"
        case .laugh: "Laughed at"
        case .emphasize: "Emphasized"
        case .question: "Questioned"
        }
    }
}

/// Tapbacks: round badges at the bubble's top corner on the side facing the transcript's
/// centre (top-trailing on incoming, top-leading on outgoing; SwiftUI mirrors this in
/// right-to-left layouts), each front badge with a two-dot "thought" tail toward the bubble.
/// Mine are accent blue with a white glyph; others' are grey with a grey glyph. Several
/// reactions overlap in a stack, the first in front and outermost. A key reacted by more than
/// one person becomes a small pill with the count after the glyph (caption-size, same colours);
/// counts are never covered, and reactions beyond four collapse into a "+N" badge.
///
/// Placement (CALIBRATION.md, transcript.tapbackBadge): the front badge's outer cap centre
/// sits `tapbackInset` inside the bubble edge and `tapbackRise` above its top. Apply with
/// `.reactionBadges(_:outgoing:metrics:)`, which also reserves the room above the bubble.
public struct ReactionBadges: View {
    let reactions: [CommsReaction]
    let outgoing: Bool

    @Environment(\.bubbleMetrics) private var metrics

    public init(_ reactions: [CommsReaction], outgoing: Bool) {
        self.reactions = reactions
        self.outgoing = outgoing
    }

    /// At most this many badges are drawn; more reactions collapse into a "+N" badge.
    static let maxBadges = 4

    public var body: some View {
        let size = metrics.tapbackBadge
        let overflow = reactions.count > Self.maxBadges
        let shown = Array(reactions.prefix(overflow ? Self.maxBadges - 1 : Self.maxBadges))
        let more = reactions.count - shown.count
        let overlap = size * 0.38
        // Front (index 0) is outermost: last in the row for incoming, first for outgoing.
        // A badge is covered by its front neighbour on the side facing the front. A count sits
        // on the trailing end of its pill, so on incoming (front at the trailing end) a badge
        // with a count is not overlapped: a count is never hidden.
        HStack(spacing: 0) {
            if outgoing {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, reaction in
                    badge(reaction, front: i == 0, size: size)
                        .zIndex(Double(shown.count - i))
                        .padding(.leading, i == 0 ? 0 : -overlap)
                }
                if more > 0 { MoreBadge(count: more, size: size, ring: metrics.tapbackRing).padding(.leading, -overlap * 0.5) }
            } else {
                if more > 0 { MoreBadge(count: more, size: size, ring: metrics.tapbackRing).padding(.trailing, -overlap * 0.5) }
                ForEach(Array(shown.enumerated()).reversed(), id: \.offset) { i, reaction in
                    badge(reaction, front: i == 0, size: size)
                        .zIndex(Double(shown.count - i))
                        .padding(.trailing, i == 0 || reaction.count > 1 ? 0 : -overlap)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reactions.map { Self.phrase($0, selfIDs: []) }.joined(separator: ", "))
    }

    private func badge(_ reaction: CommsReaction, front: Bool, size: CGFloat) -> some View {
        Badge(reaction: reaction, size: size, front: front, outward: outgoing ? -1 : 1, ring: metrics.tapbackRing,
              countSize: max(9, metrics.captionSize - 1))
    }

    /// "+2": the reactions beyond the badges drawn, so none goes uncounted.
    private struct MoreBadge: View {
        let count: Int
        let size: CGFloat
        let ring: CGFloat
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let palette = BubblePalette(scheme: scheme)
            Text("+\(count)")
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(palette.reactionOtherGlyph)
                .fixedSize()
                .padding(.horizontal, size * 0.2)
                .frame(minWidth: size, minHeight: size)
                .background {
                    Capsule().fill(palette.reactionOtherFill)
                        // A true cutout (erases the bubble under it inside the bubble's compositing group), not
                    // a painted ring: the transcript is black on iPhone but grey/glass on the Mac.
                    .background(Capsule().fill(.black).padding(-ring).blendMode(.destinationOut))
                }
        }
    }

    /// "Loved by you and Alex", "Laughed at by Sam", "Liked by 3 people including you".
    /// Senders whose id is in `selfIDs` (or named "You"/"Me") are the owner; when the owner's
    /// entry cannot be told apart, the phrase falls back to a count.
    public static func phrase(_ r: CommsReaction, selfIDs: Set<String>) -> String {
        let verb = ClassicTapback(key: r.key)?.verb ?? "Reacted \(r.key)"
        let total = max(r.count, r.senders.count, 1)
        let others = r.senders
            .filter { !selfIDs.contains($0.id) && !["you", "me"].contains($0.name.lowercased()) }
            .map(\.name)
        let expectedOthers = total - (r.mine ? 1 : 0)
        let people: String
        if total <= 2, others.count == expectedOthers {
            let names = (r.mine ? ["you"] : []) + others
            people = names.joined(separator: " and ")
        } else {
            people = "\(total) \(total == 1 ? "person" : "people")" + (r.mine ? " including you" : "")
        }
        return "\(verb) by \(people)"
    }

    private struct Badge: View {
        let reaction: CommsReaction
        let size: CGFloat
        let front: Bool
        /// +1 when the bubble's outer side is the trailing side (incoming), -1 otherwise.
        let outward: CGFloat
        let ring: CGFloat
        let countSize: CGFloat

        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let palette = BubblePalette(scheme: scheme)
            let fill = reaction.mine ? Tokens.color.accent.color : palette.reactionOtherFill
            let ink = reaction.mine ? Color.white : palette.reactionOtherGlyph
            HStack(spacing: size * 0.02) {
                glyph(ink: ink)
                    .frame(width: size * 0.62, height: size)
                if reaction.count > 1 {
                    Text("\(reaction.count)")
                        .font(.system(size: countSize, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(ink)
                        .fixedSize()
                }
            }
            .padding(.horizontal, size * 0.19)
            .frame(minWidth: size, minHeight: size)
            .background {
                Capsule().fill(fill)
                    .overlay {
                        if !reaction.mine, let hairline = palette.reactionOtherHairline {
                            Capsule().strokeBorder(hairline, lineWidth: 0.5)
                        }
                    }
                    // A true cutout (erases the bubble under it inside the bubble's compositing group), not
                    // a painted ring: the transcript is black on iPhone but grey/glass on the Mac.
                    .background(Capsule().fill(.black).padding(-ring).blendMode(.destinationOut))
            }
            .overlay(alignment: outward > 0 ? .bottomTrailing : .bottomLeading) {
                if front {
                    // Thought tail: a small and a tiny dot, down and outward toward the bubble,
                    // anchored at the outer cap (a zero-size frame centred on the corner).
                    ZStack {
                        dot(fill: fill, ringColor: palette.background, d: size * 0.2)
                            .offset(x: outward * -size * 0.06, y: 0)
                        dot(fill: fill, ringColor: palette.background, d: size * 0.1)
                            .offset(x: outward * size * 0.12, y: size * 0.22)
                    }
                    .frame(width: 0, height: 0)
                }
            }
        }

        private func dot(fill: Color, ringColor: Color, d: CGFloat) -> some View {
            ZStack {
                Circle().fill(ringColor).frame(width: d + 2 * ring, height: d + 2 * ring).blendMode(.destinationOut)
                Circle().fill(fill).frame(width: d, height: d)
            }
        }

        @ViewBuilder
        private func glyph(ink: Color) -> some View {
            if let classic = ClassicTapback(key: reaction.key) {
                if let symbol = classic.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * (classic == .love ? 0.46 : 0.44), weight: .bold))
                        .foregroundStyle(ink)
                } else {
                    // "HA HA" wordmark, two lines.
                    VStack(spacing: -size * 0.07) {
                        Text("HA")
                        Text("HA")
                    }
                    .font(.system(size: size * 0.27, weight: .heavy, design: .rounded))
                    .foregroundStyle(ink)
                }
            } else if reaction.key.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0xFF }) {
                Text(reaction.key).font(.system(size: size * 0.56))
            } else {
                Text(reaction.key.uppercased())
                    .font(.system(size: size * 0.3, weight: .heavy, design: .rounded))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(size * 0.12)
            }
        }
    }
}

extension View {
    /// Attach tapback badges to a bubble and reserve room for them above it.
    func reactionBadges(_ reactions: [CommsReaction], outgoing: Bool, metrics: BubbleMetrics, onTap: (@MainActor () -> Void)? = nil) -> some View {
        let size = metrics.tapbackBadge
        let room = reactions.isEmpty ? 0 : metrics.tapbackRise + size / 2
        // SwiftUI mirrors alignment and offsets in right-to-left layouts by itself.
        let dx = (size / 2 - metrics.tapbackInset) * (outgoing ? -1 : 1)
        return self
            .overlay(alignment: outgoing ? .topLeading : .topTrailing) {
                if !reactions.isEmpty {
                    ReactionBadges(reactions, outgoing: outgoing)
                        .contentShape(.rect)
                        .onTapGesture { onTap?() }
                        .allowsHitTesting(onTap != nil)
                        .accessibilityIdentifier("reaction-badges")
                        .offset(x: dx, y: -(metrics.tapbackRise + size / 2))
                }
            }
            // Lets the badges' cutouts erase the bubble beneath them (and only it).
            .compositingGroup()
            .padding(.top, room)
    }
}
