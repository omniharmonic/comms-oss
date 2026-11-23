import PrismModels
import SwiftUI

/// The body of a text bubble: `CommsRichText` spans as Apple-style text. Inline spans (bold,
/// italic, strike, code, links, mentions) flow in one paragraph; `quote`, `pre` and list
/// items become their own blocks. Mentions are bold (UX spec §5); links are underlined in
/// the bubble's text colour, as Messages draws detected links. A paragraph whose first strong
/// character is right-to-left lays out right-to-left, so it aligns to the trailing side.
public struct RichTextView: View {
    let text: CommsRichText
    let outgoing: Bool

    @Environment(\.bubbleMetrics) private var metrics
    @Environment(\.colorScheme) private var scheme
    @Environment(\.bubbleMaxWidth) private var maxWidth

    public init(_ text: CommsRichText, outgoing: Bool) {
        self.text = text
        self.outgoing = outgoing
    }

    public var body: some View {
        let color = BubblePalette(scheme: scheme).text(outgoing: outgoing)
        let blocks = RichTextBlocks.build(text.spans, metrics: metrics)
        VStack(alignment: .leading, spacing: metrics.lineHeight * 0.25) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block, color: color)
            }
        }
        .foregroundStyle(color)
        .tint(color)
        // Clicked links go through the scheme allowlist, never straight to the system.
        .environment(\.openURL, SafeLinks.openURLAction)
    }

    @ViewBuilder
    private func blockView(_ block: RichTextBlocks.Block, color: Color) -> some View {
        switch block {
        case .paragraph(let s):
            paragraph(s)
        case .listItem(let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").font(.system(size: metrics.bodySize))
                paragraph(s)
            }
        case .quote(let s):
            HStack(alignment: .top, spacing: 7) {
                Capsule().fill(color.opacity(0.4)).frame(width: 3)
                paragraph(s).opacity(0.8)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .pre(let s):
            VStack(alignment: .leading, spacing: 0) {
                // Hard line breaks only (no measurement): a long block is still several layers.
                ForEach(Array(LongTextCache.chunks(AttributedString(s), width: nil).enumerated()), id: \.offset) { _, piece in
                    Text(piece)
                        .font(.system(size: metrics.bodySize - 1, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.1)))
        }
    }

    private func paragraph(_ s: AttributedString) -> some View {
        let rtl = RichTextBlocks.isRightToLeft(String(s.characters))
        // A very long paragraph is a stack of texts, each well under the layer size limit
        // (LongText); the pieces wrap exactly as the whole would.
        let textWidth = maxWidth.map { $0 - 2 * metrics.padH }
        var pieces = LongTextCache.chunks(s, width: textWidth)
        #if os(iOS)
        // Messages' line breaks (no push-out) for an ordinary paragraph.
        if pieces.count == 1, let textWidth, let broken = LongTextCache.messagesLineBreaks(s, width: textWidth) { pieces = [broken] }
        #endif
        return VStack(alignment: .leading, spacing: metrics.lineSpacing) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                Text(piece)
                    .lineSpacing(metrics.lineSpacing)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
    }
}

enum RichTextBlocks {
    enum Block {
        case paragraph(AttributedString)
        case quote(AttributedString)
        case listItem(AttributedString)
        case pre(String)
    }

    struct Style {
        var bold = false, italic = false, strike = false, mono = false
        var link: URL?
    }

    static func build(_ spans: [CommsSpan], metrics: BubbleMetrics) -> [Block] {
        var blocks: [Block] = []
        var current = AttributedString()
        func flush() {
            // Drop the newline a `br` leaves before a block.
            while current.characters.last == "\n" { current.characters.removeLast() }
            if !current.characters.isEmpty { blocks.append(.paragraph(current)) }
            current = AttributedString()
        }
        for span in spans {
            switch span {
            case .quote(let c):
                flush()
                blocks.append(.quote(inline(c, metrics: metrics)))
            case .listItem(let c):
                flush()
                blocks.append(.listItem(inline(c, metrics: metrics)))
            case .pre(let v):
                flush()
                blocks.append(.pre(v))
            default:
                append(span, style: Style(), metrics: metrics, into: &current)
            }
        }
        flush()
        return blocks
    }

    static func inline(_ spans: [CommsSpan], metrics: BubbleMetrics) -> AttributedString {
        var out = AttributedString()
        for s in spans { append(s, style: Style(), metrics: metrics, into: &out) }
        return out
    }

    static func append(_ span: CommsSpan, style: Style, metrics: BubbleMetrics, into out: inout AttributedString) {
        func run(_ text: String, _ style: Style) {
            var a = AttributedString(text)
            var font = Font.system(size: style.mono ? metrics.bodySize - 1 : metrics.bodySize,
                                   design: style.mono ? .monospaced : .default)
            if style.bold { font = font.bold() }
            if style.italic { font = font.italic() }
            a.font = font
            // The same face for TextKit, which measures where a very long text is cut (LongText).
            let measured = LongText.platformFont(size: style.mono ? metrics.bodySize - 1 : metrics.bodySize, bold: style.bold, italic: style.italic, mono: style.mono)
            #if canImport(UIKit)
            a.uiKit.font = measured
            #else
            a.appKit.font = measured
            #endif
            if style.strike { a.strikethroughStyle = .single }
            if let link = style.link {
                a.link = link
                a.underlineStyle = .single
            } else if !style.mono {
                // Bridged messages arrive as plain text: detect web and email addresses the way
                // Messages does, so they open with a click or tap.
                for found in SafeLinks.detectedLinks(in: text) {
                    guard let lower = AttributedString.Index(found.range.lowerBound, within: a),
                          let upper = AttributedString.Index(found.range.upperBound, within: a) else { continue }
                    a[lower..<upper].link = found.url
                    a[lower..<upper].underlineStyle = .single
                }
            }
            out += a
        }
        func children(_ c: [CommsSpan], _ s: Style) { for child in c { append(child, style: s, metrics: metrics, into: &out) } }

        switch span {
        case .text(let v): run(v, style)
        case .bold(let c): var s = style; s.bold = true; children(c, s)
        case .italic(let c): var s = style; s.italic = true; children(c, s)
        case .strike(let c): var s = style; s.strike = true; children(c, s)
        case .code(let c): var s = style; s.mono = true; children(c, s)
        case .pre(let v): var s = style; s.mono = true; run(v, s)
        case .link(let href, let c):
            var s = style
            // Only http, https and mailto become links; any other scheme is plain text.
            s.link = SafeLinks.textURL(href)
            if c.isEmpty { run(href, s) } else { children(c, s) }
        case .mention(_, let name): var s = style; s.bold = true; run(name, s)
        case .quote(let c), .listItem(let c): children(c, style)
        case .br: run("\n", style)
        case .unknown: break
        }
    }

    /// True when the first strongly directional character is Hebrew, Arabic or another
    /// right-to-left script.
    static func isRightToLeft(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                return true
            default:
                if scalar.properties.isAlphabetic { return false }
            }
        }
        return false
    }
}
