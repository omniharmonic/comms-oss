import PrismModels
import SwiftUI

/// A rich link: a card in the bubble shape with the preview image on top and the title
/// (semibold, two lines) and site below on the neutral grey, for both directions, as
/// Messages draws it (UX spec §5). The tail, when present, continues the grey text area.
/// Clicking the card opens its URL in the browser when it is http or https (`SafeLinks`).
public struct LinkPreviewCard: View {
    let preview: CommsLinkPreview
    let outgoing: Bool
    let tail: Bool

    @Environment(\.bubbleMetrics) private var metrics
    @Environment(\.bubbleMaxWidth) private var maxWidth
    @Environment(\.colorScheme) private var scheme

    public init(_ preview: CommsLinkPreview, outgoing: Bool, tail: Bool) {
        self.preview = preview
        self.outgoing = outgoing
        self.tail = tail
    }

    /// Open Graph images are 1.91 : 1.
    static let imageAspect: CGFloat = 1.91

    public var body: some View {
        let palette = BubblePalette(scheme: scheme)
        let width = min(metrics.mediaMaxWidth, maxWidth ?? metrics.mediaMaxWidth).rounded()
        let drop = tail ? metrics.tailDrop : 0
        VStack(alignment: .leading, spacing: 0) {
            if let token = preview.imageToken {
                MediaImageView(token: token, placeholder: palette.incomingFill)
                    .frame(width: width, height: (width / Self.imageAspect).rounded())
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.title ?? Self.host(preview.url))
                    .font(.system(size: metrics.previewTitleSize, weight: .semibold))
                    .foregroundStyle(palette.incomingText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.site(preview))
                    .font(.system(size: metrics.previewSiteSize))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, metrics.padH)
            .padding(.top, metrics.padV)
            .padding(.bottom, metrics.padV + drop)
            .frame(width: width, alignment: .leading)
            .background(palette.incomingFill)
        }
        .frame(width: width)
        .clipShape(BubbleShape(tail: tail, outgoing: outgoing, radius: metrics.radius, bottomInset: drop))
        .padding(.bottom, -drop)
        .contentShape(Rectangle())
        // Click opens the page in the browser (http/https only; anything else is inert).
        .onTapGesture { SafeLinks.openPreview(preview.url) }
        .help(SafeLinks.webURL(preview.url)?.absoluteString ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
        .accessibilityAction { SafeLinks.openPreview(preview.url) }
    }

    static func host(_ url: String) -> String {
        guard let host = URL(string: url)?.host() else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func site(_ p: CommsLinkPreview) -> String {
        if let s = p.siteName, !s.isEmpty { return s }
        return host(p.url)
    }

    /// True when a message's text is just this preview's URL (Messages then shows the card alone).
    static func isBareURL(_ text: String, of preview: CommsLinkPreview) -> Bool {
        func norm(_ s: String) -> String {
            var s = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
            if s.hasPrefix("www.") { s.removeFirst(4) }
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return norm(text) == norm(preview.url)
    }
}
