import PrismModels
import SwiftUI

/// One attachment as Messages draws it:
/// - image / video / sticker: the picture at its aspect ratio (capped to the media box),
///   clipped by the bubble shape, tail included (the picture fills the tail too); video adds
///   a play glyph; a sticker has no bubble;
/// - voice / audio: a bubble with a play circle, a waveform and the duration;
/// - file / location / unknown: a bubble with an icon and a label.
/// Bytes come from the environment's `MediaLoader` (authenticated backend), never a URL.
public struct MediaBubble: View {
    let attachment: CommsAttachment
    let fill: BubbleFill
    let tail: Bool

    @Environment(\.bubbleMetrics) private var metrics
    @Environment(\.bubbleMaxWidth) private var maxWidth
    @Environment(\.colorScheme) private var scheme

    public init(_ attachment: CommsAttachment, fill: BubbleFill, tail: Bool) {
        self.attachment = attachment
        self.fill = fill
        self.tail = tail
    }

    var outgoing: Bool { fill != .incoming }

    public var body: some View {
        switch attachment.kind {
        case .image, .video:
            picture
        case .sticker:
            MediaImageView(token: attachment.mediaToken ?? attachment.thumbToken, placeholder: .clear)
                .scaledToFit()
                .frame(width: min(120, mediaSize.width), height: min(120, mediaSize.width) / max(aspect, 0.1))
        case .voice, .audio:
            VoiceBubble(attachment: attachment, fill: fill, tail: tail)
        case .file:
            labelBubble(symbol: "doc.fill", title: attachment.name ?? "File", subtitle: attachment.size.map(Self.byteString))
        case .location:
            labelBubble(symbol: "mappin.circle.fill", title: "Location", subtitle: attachment.geo)
        case .unknown:
            labelBubble(symbol: "paperclip", title: attachment.name ?? "Attachment", subtitle: nil)
        }
    }

    var aspect: CGFloat {
        guard let w = attachment.w, let h = attachment.h, w > 0, h > 0 else { return 4.0 / 3.0 }
        return CGFloat(w) / CGFloat(h)
    }

    /// The picture's size: as wide as the media box allows, at the attachment's aspect ratio,
    /// then shrunk to the max height.
    var mediaSize: CGSize {
        let boxW = min(metrics.mediaMaxWidth, maxWidth ?? metrics.mediaMaxWidth)
        var size = CGSize(width: boxW, height: boxW / aspect)
        if size.height > metrics.mediaMaxHeight {
            size = CGSize(width: metrics.mediaMaxHeight * aspect, height: metrics.mediaMaxHeight)
        }
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    private var picture: some View {
        let size = mediaSize
        let drop = tail ? metrics.tailDrop : 0
        let token = attachment.kind == .video ? (attachment.thumbToken ?? attachment.mediaToken) : (attachment.mediaToken ?? attachment.thumbToken)
        return MediaImageView(token: token, placeholder: BubblePalette(scheme: scheme).incomingFill)
            .frame(width: size.width, height: size.height + drop)
            .clipShape(BubbleShape(tail: tail, outgoing: outgoing, radius: metrics.radius, bottomInset: drop))
            .overlay {
                if attachment.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: metrics.bodySize * 1.2, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: metrics.minHeight * 1.4, height: metrics.minHeight * 1.4)
                        .background(Circle().fill(.black.opacity(0.4)))
                        .padding(.bottom, drop)
                }
            }
            .padding(.bottom, -drop)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture { MediaViewer.shared.open(attachment) }
            .accessibilityLabel(attachment.kind == .video ? "Video" : "Photo")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(MediaViewer.openHint)
            .accessibilityAction { MediaViewer.shared.open(attachment) }
    }

    private func labelBubble(symbol: String, title: String, subtitle: String?) -> some View {
        let palette = BubblePalette(scheme: scheme)
        let text = palette.text(outgoing: outgoing)
        return HStack(spacing: metrics.padH * 0.7) {
            Image(systemName: symbol)
                .font(.system(size: metrics.bodySize * 1.6))
                .foregroundStyle(outgoing ? AnyShapeStyle(text) : AnyShapeStyle(palette.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: metrics.bodySize, weight: .semibold)).lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(.system(size: metrics.bodySize - 2)).opacity(0.7).lineLimit(1)
                }
            }
            .foregroundStyle(text)
        }
        .padding(.horizontal, metrics.padH)
        .padding(.vertical, metrics.padV)
        .frame(minHeight: metrics.minHeight)
        .background(BubbleFillView(shape: BubbleShape(tail: tail, outgoing: outgoing, radius: metrics.radius), fill: fill))
    }

    static func byteString(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

/// Audio message: play circle, waveform, duration (UX spec §5). The waveform is drawn from
/// a stable hash of the media token until real levels are available. Tap plays it in place
/// (`VoicePlayer`): the button becomes pause, the waveform fills as it plays and the time counts
/// down, as in Messages.
struct VoiceBubble: View {
    let attachment: CommsAttachment
    let fill: BubbleFill
    let tail: Bool

    @Environment(\.bubbleMetrics) private var metrics
    @Environment(\.colorScheme) private var scheme
    private let player = VoicePlayer.shared

    var outgoing: Bool { fill != .incoming }

    var body: some View {
        let palette = BubblePalette(scheme: scheme)
        let ink = outgoing ? Color.white : palette.secondary
        let circle = metrics.minHeight * 0.75
        let current = player.isCurrent(attachment)
        let playing = current && player.isPlaying
        let loading = current && player.isLoading
        HStack(spacing: metrics.padH * 0.6) {
            ZStack {
                Circle().fill(outgoing ? Color.white : Tokens.color.accent.color)
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(outgoing ? outgoingInk : Color.white)
                } else {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: circle * 0.42, weight: .bold))
                        .foregroundStyle(outgoing ? outgoingInk : Color.white)
                        .offset(x: playing ? 0 : circle * 0.04)
                }
            }
            .frame(width: circle, height: circle)
            Waveform(seed: attachment.mediaToken ?? "", color: ink.opacity(outgoing ? 0.9 : 0.8),
                     played: current ? player.progress : 0, unplayed: ink.opacity(outgoing ? 0.45 : 0.35))
                .frame(height: metrics.minHeight * 0.5)
            Text(Self.duration(current && player.remaining != nil ? Int((player.remaining ?? 0) * 1000) : attachment.durationMs))
                .font(.system(size: metrics.bodySize - 2).monospacedDigit())
                .foregroundStyle(ink)
        }
        .padding(.leading, metrics.padV)
        .padding(.trailing, metrics.padH)
        .padding(.vertical, metrics.padV * 0.8)
        .frame(width: metrics.voiceWidth)
        .frame(minHeight: metrics.minHeight * 1.2)
        .background(BubbleFillView(shape: BubbleShape(tail: tail, outgoing: outgoing, radius: metrics.radius), fill: fill))
        .contentShape(Rectangle())
        .onTapGesture { player.toggle(attachment) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio message, \(Self.duration(attachment.durationMs))")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(playing ? "Pauses" : "Plays")
        .accessibilityAction { player.toggle(attachment) }
    }

    private var outgoingInk: Color {
        if case .outgoing(let shade) = fill { return shade.mac.color }
        return Tokens.color.accent.color
    }

    static func duration(_ ms: Int?) -> String {
        let s = max(0, (ms ?? 0) / 1000)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct Waveform: View {
    let seed: String
    let color: Color
    /// 0 … 1 played: bars before it are `color`, after it `unplayed` (when playing).
    var played: Double = 0
    var unplayed: Color? = nil

    var body: some View {
        GeometryReader { geo in
            let bars = max(8, Int(geo.size.width / 3.5))
            let levels = Self.levels(seed: seed, count: bars)
            let cut = played > 0 ? Int((Double(bars) * played).rounded(.up)) : bars
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule().fill(i < cut || unplayed == nil ? color : unplayed!).frame(height: max(2, geo.size.height * levels[i]))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    static func levels(seed: String, count: Int) -> [CGFloat] {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return (0..<count).map { _ in
            h = h &* 6364136223846793005 &+ 1442695040888963407
            return 0.2 + 0.8 * CGFloat((h >> 33) % 1000) / 1000
        }
    }
}
