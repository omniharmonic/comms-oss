import CommsCore
import PrismModels
import SwiftUI

/// The colourful tapback glyphs of the iOS 26 / macOS 26 picker (the badges on bubbles stay
/// Messages' monochrome style, `ReactionBadges`). Any other key draws as its emoji.
struct TapbackGlyph: View {
    let key: String
    var size: CGFloat = 28

    var body: some View {
        if let classic = ClassicTapback(key: key) {
            switch classic {
            case .laugh:
                VStack(spacing: -size * 0.16) {
                    Text("HA")
                    Text("HA")
                }
                .font(.system(size: size * 0.42, weight: .black, design: .rounded))
                .foregroundStyle(Self.gradient(classic))
                .frame(width: size, height: size)
            default:
                Image(systemName: classic.symbol ?? "questionmark")
                    .font(.system(size: size * (classic == .question || classic == .emphasize ? 0.86 : 0.8), weight: classic == .question || classic == .emphasize ? .heavy : .regular))
                    .foregroundStyle(Self.gradient(classic))
                    .frame(width: size, height: size)
            }
        } else {
            Text(key)
                .font(.system(size: size * 0.86))
                .frame(width: size, height: size)
        }
    }

    /// Hues of Apple's colour tapbacks (iOS 18+), top → bottom.
    static func gradient(_ t: ClassicTapback) -> LinearGradient {
        let (a, b): (Color, Color) = switch t {
        case .love: (Color(red: 1, green: 0.47, blue: 0.75), Color(red: 0.96, green: 0.27, blue: 0.6))
        case .like: (Color(red: 1, green: 0.84, blue: 0.29), Color(red: 0.96, green: 0.62, blue: 0.13))
        case .dislike: (Color(red: 1, green: 0.73, blue: 0.27), Color(red: 0.94, green: 0.5, blue: 0.12))
        case .laugh: (Color(red: 0.42, green: 0.8, blue: 1), Color(red: 0.18, green: 0.49, blue: 0.96))
        case .emphasize: (Color(red: 1, green: 0.38, blue: 0.45), Color(red: 0.9, green: 0.14, blue: 0.35))
        case .question: (Color(red: 0.74, green: 0.62, blue: 1), Color(red: 0.56, green: 0.36, blue: 0.96))
        }
        return LinearGradient(colors: [a, b], startPoint: .top, endPoint: .bottom)
    }
}

extension ClassicTapback {
    /// VoiceOver / menu name, as Messages says it.
    public var spokenName: String {
        switch self {
        case .love: "Heart"
        case .like: "Thumbs Up"
        case .dislike: "Thumbs Down"
        case .laugh: "Ha Ha"
        case .emphasize: "Exclamation Marks"
        case .question: "Question Mark"
        }
    }

    /// Accessibility identifier suffix (`tapback-love`).
    var identifier: String { "tapback-\(rawValue)" }
}

/// Messages' tapback bar: a Liquid Glass capsule of the six tapbacks (and any emoji recently
/// used for reactions). The owner's current reaction sits on a tinted circle; tapping it again
/// removes it (the store decides).
public struct TapbackPicker: View {
    let selected: Set<String>
    let recents: [String]
    let onPick: (String) -> Void

    #if os(iOS)
    static let itemSize: CGFloat = 46
    static let glyphSize: CGFloat = 30
    static let height: CGFloat = 58
    #else
    static let itemSize: CGFloat = 34
    static let glyphSize: CGFloat = 22
    static let height: CGFloat = 44
    #endif

    public init(selected: Set<String>, recents: [String] = [], onPick: @escaping (String) -> Void) {
        self.selected = selected
        self.recents = recents
        self.onPick = onPick
    }

    var keys: [String] { Tapbacks.keys + recents.filter { !Tapbacks.keys.contains($0) }.prefix(2) }

    /// The bar's width for `count` items.
    static func width(count: Int) -> CGFloat { CGFloat(count) * itemSize + 12 }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(keys, id: \.self) { key in
                let on = selected.contains(key) || (ClassicTapback(key: key).map { c in selected.contains { ClassicTapback(key: $0) == c } } ?? false)
                Button { onPick(key) } label: {
                    TapbackGlyph(key: key, size: Self.glyphSize)
                        .frame(width: Self.itemSize, height: Self.itemSize)
                        .background {
                            if on { Circle().fill(Tokens.color.accent.color.opacity(0.22)).padding(2) }
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(TapbackButtonStyle())
                .accessibilityLabel(ClassicTapback(key: key)?.spokenName ?? key)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier(ClassicTapback(key: key)?.identifier ?? "tapback-\(key)")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tapback")
        .accessibilityIdentifier("tapback-bar")
    }
}

/// A tapback grows a little under the finger, as in Messages.
struct TapbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.25 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The smiley "thought bubble" beside the bar: any emoji (`EmojiPicker`). Its two dots trail toward `trailingDots` side.
struct EmojiMoreButton: View {
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "face.smiling")
                .font(.system(size: size * 0.5))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .overlay(alignment: .bottomLeading) {
            Circle().fill(.clear).frame(width: size * 0.2, height: size * 0.2)
                .glassEffect(.regular, in: .circle)
                .offset(x: -size * 0.12, y: size * 0.22)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("More Emoji")
        .accessibilityIdentifier("tapback-more")
    }
}

/// Emoji the owner reacted with lately (beyond the six), newest first; per device.
public enum RecentReactions {
    static let defaultsKey = "comms.recentReactions"

    public static var all: [String] {
        (UserDefaults.standard.array(forKey: defaultsKey) as? [String]) ?? []
    }

    /// An emoji reaction: presentation by default (😀), or text-default (©, ™, 1, #) made
    /// emoji by a variation selector or keycap. Letters and plain digits are not.
    public static func isEmoji(_ c: Character) -> Bool {
        let scalars = c.unicodeScalars
        guard let head = scalars.first, head.properties.isEmoji else { return false }
        return head.properties.isEmojiPresentation || scalars.count > 1
    }

    public static func note(_ key: String) {
        guard !Tapbacks.keys.contains(key), ClassicTapback(key: key) == nil else { return }
        var list = all.filter { $0 != key }
        list.insert(key, at: 0)
        // The bar shows two; the picker's Frequently Used row shows them all.
        UserDefaults.standard.set(Array(list.prefix(24)), forKey: defaultsKey)
    }
}
