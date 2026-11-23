import CoreGraphics
import CoreText
import SwiftUI

/// Per-platform bubble sizes. iOS values are `Tokens` (design/tokens.json). Mac values come
/// from CALIBRATION.md (single-line height 28.5 pt, a capsule) and otherwise from the Mac
/// guide image `macos26-guide-window-sidebar-transcript.png`, which is ≈ 0.81 px/pt (its
/// single-line bubble is 23 px; ruling R19), so guide pixels are scaled by 28.5/23.
/// "est." marks judgement calls.
public struct BubbleMetrics: Sendable, Equatable {
    /// Body text size and line height (iOS Body 17/22; macOS Body 13/16, UX spec §1/§9).
    public var bodySize: CGFloat
    public var lineHeight: CGFloat
    public var radius: CGFloat
    public var padH: CGFloat
    public var padV: CGFloat
    /// A single-line bubble's height (= 2 × radius, a capsule).
    public var minHeight: CGFloat
    /// Max bubble width as a share of the transcript column.
    public var maxWidthRatio: CGFloat
    public var gapSameSender: CGFloat
    public var gapSenderChange: CGFloat
    public var gapGroupSenderChange: CGFloat
    public var groupAvatar: CGFloat
    public var avatarGap: CGFloat
    /// Group sender name and centred system captions.
    public var captionSize: CGFloat
    public var tapbackBadge: CGFloat
    public var tapbackInset: CGFloat
    public var tapbackRise: CGFloat
    /// Ring of transcript background around a tapback badge.
    public var tapbackRing: CGFloat
    public var jumboEmojiSize: CGFloat
    public var mediaMaxWidth: CGFloat
    public var mediaMaxHeight: CGFloat
    public var voiceWidth: CGFloat
    public var previewTitleSize: CGFloat
    public var previewSiteSize: CGFloat

    /// The tail path is in iOS points for a radius-20 body; it scales with the radius.
    public var tailScale: CGFloat { radius / Tokens.bubble.radius }
    public var tailDrop: CGFloat { Tokens.bubble.tail.drop * tailScale }

    public static let iOS = BubbleMetrics(
        bodySize: 17, lineHeight: 22,
        radius: Tokens.bubble.radius, padH: Tokens.bubble.padH, padV: Tokens.bubble.padV,
        minHeight: 2 * Tokens.bubble.radius,
        maxWidthRatio: Tokens.bubble.maxWidthRatio,
        gapSameSender: Tokens.bubble.gapSameSender,
        gapSenderChange: Tokens.bubble.gapSenderChange,
        gapGroupSenderChange: Tokens.bubble.gapGroupSenderChange,
        groupAvatar: Tokens.transcript.groupAvatar,
        avatarGap: 8, // UX spec §5: 8–9 pt
        captionSize: 12, // UX spec §5: group sender name ≈ 12 pt
        tapbackBadge: Tokens.transcript.tapbackBadge,
        tapbackInset: Tokens.calibration.tapbackInsetFromEdge,
        tapbackRise: Tokens.calibration.tapbackRiseAboveTop,
        tapbackRing: 2, // est.
        jumboEmojiSize: 48, // UX spec §5: "~48 pt+"
        mediaMaxWidth: 250, // ref-measured: SMS guide photo 276 px ÷ 1.107
        mediaMaxHeight: 340, // ref-measured: same photo 370 px ÷ 1.107 ≈ 334
        voiceWidth: 250, // est. (kit voice bubble 299 pt incl. transcription)
        previewTitleSize: 15, previewSiteSize: 13 // est. (Subheadline / Footnote)
    )

    /// Guide pixels → pt (CALIBRATION: Mac guide ≈ 0.81 px/pt).
    static let macGuide: CGFloat = Tokens.calibration.macBubbleHeight / 23

    public static let mac = BubbleMetrics(
        bodySize: 13, lineHeight: 16,
        radius: Tokens.calibration.macBubbleHeight / 2,
        padH: 12, // Apple's padH ÷ height ≈ 0.43 (guide text inset 10 px)
        padV: (Tokens.calibration.macBubbleHeight - 16) / 2,
        minHeight: Tokens.calibration.macBubbleHeight,
        maxWidthRatio: 0.65, // UX spec §9: 60–65 %
        gapSameSender: 3, // est. (iOS 4 × 0.7)
        gapSenderChange: (8 * macGuide).rounded(), // guide: 8 px between "Oh, wow" and the reply
        gapGroupSenderChange: 24, // est. (iOS 33 × 0.71)
        groupAvatar: (22 * macGuide).rounded(), // guide: 22 px; UX spec §9: 24–28
        avatarGap: (6 * macGuide).rounded(), // guide: 6 px
        captionSize: 11, // macOS Subheadline 11 (guide sender names ≈ 9 px tall caps+desc)
        tapbackBadge: (22 * macGuide).rounded(), // guide: "HAHA" badge 22 px
        tapbackInset: Tokens.calibration.tapbackInsetFromEdge, // guide: ≈ 2 px inside
        tapbackRise: (7.5 * macGuide).rounded(), // guide: centre 7.5 px above the bubble top
        tapbackRing: 1.5, // est.
        jumboEmojiSize: 40, // est. (no Mac reference; ≈ 3 × body)
        mediaMaxWidth: (297 * macGuide).rounded(), // guide photo 297 px wide
        mediaMaxHeight: (390 * macGuide).rounded(), // guide photo 390 px tall
        voiceWidth: 220, // est.
        previewTitleSize: 13, previewSiteSize: 11 // est. (macOS Body semibold / Subheadline)
    )

    /// Every size multiplied by `factor` (text-size scaling, ⌘+ / ⌘−); ratios are unchanged.
    public func scaled(by factor: CGFloat) -> BubbleMetrics {
        var m = self
        let sizes: [WritableKeyPath<BubbleMetrics, CGFloat>] = [\.bodySize, \.lineHeight, \.radius, \.padH, \.padV, \.minHeight,
                   \.gapSameSender, \.gapSenderChange, \.gapGroupSenderChange, \.groupAvatar, \.avatarGap,
                   \.captionSize, \.tapbackBadge, \.tapbackInset, \.tapbackRise, \.tapbackRing, \.jumboEmojiSize,
                   \.mediaMaxWidth, \.mediaMaxHeight, \.voiceWidth, \.previewTitleSize, \.previewSiteSize]
        for kp in sizes {
            m[keyPath: kp] *= factor
        }
        return m
    }

    #if os(macOS)
    public static let current = mac
    #else
    public static let current = iOS
    #endif

    /// Extra line spacing so SF's natural line height becomes `lineHeight`.
    var lineSpacing: CGFloat {
        let font = CTFontCreateUIFontForLanguage(.system, bodySize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, bodySize, nil)
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        return max(0, lineHeight - natural)
    }
}

extension EnvironmentValues {
    /// Bubble sizes; `.current` for the platform. Snapshot tests pin `.mac`.
    @Entry public var bubbleMetrics: BubbleMetrics = .current
    /// Max bubble width (transcript column × `maxWidthRatio`); nil = unconstrained.
    @Entry public var bubbleMaxWidth: CGFloat? = nil
    /// Height of the window-space outgoing gradient on iOS (the transcript's window height).
    @Entry public var outgoingGradientHeight: CGFloat = 874
    /// Sender ids that are the owner (for "Loved by you and Alex" in VoiceOver labels).
    @Entry public var selfSenderIDs: Set<String> = []
    /// Loads media tokens through the authenticated backend.
    @Entry public var mediaLoader: MediaLoader = .none
    /// Collapsed long message: the text bubble shows at most this many lines, fading out
}

extension TokenColor {
    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// A colour mixed in code (e.g. a gradient sample); `hex` is derived.
    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        hex = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

/// Colours a bubble draws with, resolved for the colour scheme.
struct BubblePalette {
    let scheme: ColorScheme

    var incomingFill: Color { (scheme == .dark ? Tokens.color.incomingDark : Tokens.color.incomingLight).color }
    var incomingText: Color { scheme == .dark ? .white : .black }
    var outgoingText: Color { .white }
    var secondary: Color { Tokens.color.secondaryLabel.color }
    var background: Color { scheme == .dark ? .black : .white }
    func text(outgoing: Bool) -> Color { outgoing ? outgoingText : incomingText }

    /// Others' tapback badge. Dark uses #3A3A3C (not the incoming #262628, which vanishes on
    /// black) plus a hairline. Estimated: owner to verify on device.
    var reactionOtherFill: Color { scheme == .dark ? Color(.sRGB, red: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255) : incomingFill }
    var reactionOtherGlyph: Color { scheme == .dark ? Color(.sRGB, red: 0xAE / 255, green: 0xAE / 255, blue: 0xB2 / 255) : secondary }
    var reactionOtherHairline: Color? { scheme == .dark ? Color.white.opacity(0.14) : nil }
}

/// Proposes at most `maxWidth` to its single child and takes the child's size, so a bubble
/// hugs short text and wraps long text at the cap.
struct MaxWidthLayout: Layout {
    var maxWidth: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(childProposal(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    /// The child always gets its ideal height (nil): a bubble is never squeezed vertically.
    private func childProposal(_ p: ProposedViewSize) -> ProposedViewSize {
        guard let maxWidth else { return ProposedViewSize(width: p.width, height: nil) }
        return ProposedViewSize(width: min(p.width ?? maxWidth, maxWidth), height: nil)
    }
}
