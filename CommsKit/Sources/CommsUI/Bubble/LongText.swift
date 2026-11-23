import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Very long messages drawn as a stack of text layers.
///
/// One `Text` draws into one backing layer, and Core Animation cannot draw a layer taller than
/// ~16 384 px (the GPU texture limit): a message of a few thousand words would render blank
/// past that point (or entirely). A long paragraph is therefore cut into pieces of at most
/// `maxLines` lines (≈ 1 300 pt, under 4 000 px at 3×), each its own `Text`, stacked with the
/// paragraph's line spacing.
///
/// Cuts are made where a line STARTS when the paragraph is laid out at the bubble's text
/// width (TextKit, the paragraph's own fonts), so every piece wraps exactly as the whole would
/// and the stack is indistinguishable from one text. A cut at a hard line break drops that
/// newline (the cut itself is the break). Without a known width the cuts fall on line breaks,
/// else on spaces — at most `maxLines` hard lines or `fallbackCharacters` per piece.
///
/// The gate counts LINES, not just characters: a short paragraph is never measured, but one
/// with many hard line breaks (a pasted list of short lines: 600 lines in 1 200 characters) is.
enum LongText {
    /// Paragraphs that could not reach `maxLines` lines are never cut (and never measured):
    /// fewer characters than this AND fewer hard lines than `maxLines`.
    static let threshold = 1_200
    static let maxLines = 60
    static let fallbackCharacters = 1_200

    /// Could this paragraph be `maxLines` lines or more? (Characters or hard line breaks.)
    static func mayNeedCutting(_ string: String, maxLines: Int = maxLines, threshold: Int = threshold) -> Bool {
        if string.utf16.count >= threshold { return true }
        var lines = 1
        for u in string.utf16 where u == 0x0A {
            lines += 1
            if lines >= maxLines { return true }
        }
        return false
    }

    static func chunks(_ s: AttributedString, width: CGFloat?, maxLines: Int = maxLines, threshold: Int = threshold) -> [AttributedString] {
        let string = String(s.characters)
        guard mayNeedCutting(string, maxLines: maxLines, threshold: threshold) else { return [s] }
        let utf16 = string.utf16.count
        var cuts: [Int]
        if let width, width > 20, let lines = lineStarts(s, width: width) {
            cuts = stride(from: maxLines, to: lines.count, by: maxLines).map { lines[$0] }
        } else {
            cuts = fallbackCuts(string, maxLines: maxLines)
        }
        cuts = cuts.filter { $0 > 0 && $0 < utf16 }
        guard !cuts.isEmpty else { return [s] }
        var out: [AttributedString] = []
        var start = 0
        for cut in cuts + [utf16] {
            var end = cut
            // A hard line break right before the cut: the cut is the break.
            if cut < utf16, end > start, string.utf16[string.utf16.index(string.utf16.startIndex, offsetBy: end - 1)] == 0x0A { end -= 1 }
            if let piece = slice(s, string, start, end), !piece.characters.isEmpty { out.append(piece) }
            start = cut
        }
        return out.isEmpty ? [s] : out
    }

    /// Messages' wrapping for a bubble paragraph (iOS). SwiftUI `Text` breaks lines with
    /// TextKit's push-out strategy (it avoids a one-word last line by moving a word down);
    /// Messages' balloon text does not, so e.g. "Hey! Are we still on for dinner tonight?"
    /// wraps after "dinner" in Messages (bubble 255 pt) but after "for" in SwiftUI (202.7 pt) —
    /// design/fidelity/deltas/ios-transcript.md. This lays the paragraph out with no push-out
    /// at `width` and returns it with a line break where each line starts (nil when it is one
    /// line, or already breaks there), so `Text` draws Messages' lines.
    static func messagesLineBreaks(_ s: AttributedString, width: CGFloat) -> AttributedString? {
        // One line at most: nothing to break (no layout). Measured with the run fonts' line.
        if fitsOnOneLine(s, width: width) { return nil }
        // A hair narrower than the real width, so rounding never makes SwiftUI wrap a line again.
        guard let starts = lineStarts(s, width: width - 1, pushOut: false), starts.count > 1 else { return nil }
        let string = String(s.characters)
        let units = Array(string.utf16)
        var out = AttributedString()
        var from = 0
        for start in starts.dropFirst() where start > from && start < units.count {
            guard let piece = slice(s, string, from, start) else { return nil }
            out += piece
            if units[start - 1] != 0x0A {
                // Drop the space the line ended with: the break replaces it.
                while out.characters.last == " " { out.characters.removeLast() }
                var nl = AttributedString("\n")
                if let last = piece.runs.last { nl.mergeAttributes(last.attributes) }
                out += nl
            }
            from = start
        }
        guard let tail = slice(s, string, from, units.count) else { return nil }
        out += tail
        return String(out.characters) == string ? nil : out
    }

    /// True when the paragraph has no hard break and its single-line width is under `width`
    /// (a cheap `NSAttributedString.size`, no TextKit layout).
    static func fitsOnOneLine(_ s: AttributedString, width: CGFloat) -> Bool {
        let string = String(s.characters)
        if string.contains("\n") { return false }
        #if canImport(UIKit)
        guard let ns = try? NSAttributedString(s, including: \.uiKit) else { return false }
        #else
        guard let ns = try? NSAttributedString(s, including: \.appKit) else { return false }
        #endif
        return ns.size().width < width - 1
    }

    /// UTF-16 offsets where each laid-out line begins, at `width` (nil if TextKit can't say).
    /// `pushOut`: TextKit's standard strategy (SwiftUI's); false = plain greedy breaking.
    static func lineStarts(_ s: AttributedString, width: CGFloat, pushOut: Bool = true) -> [Int]? {
        let ns: NSAttributedString
        #if canImport(UIKit)
        guard let converted = try? NSAttributedString(s, including: \.uiKit) else { return nil }
        #else
        guard let converted = try? NSAttributedString(s, including: \.appKit) else { return nil }
        #endif
        ns = converted
        let storage = NSTextStorage(attributedString: ns)
        let style = NSMutableParagraphStyle()
        style.lineBreakStrategy = pushOut ? .standard : []
        storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: storage.length))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var starts: [Int] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, glyphs, _ in
            starts.append(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location)
        }
        return starts.isEmpty ? nil : starts
    }

    /// Pieces of at most `fallbackCharacters` UTF-16 units and `maxLines` hard lines: cut after
    /// the last newline in the window, else after its last space; never inside a surrogate pair.
    static func fallbackCuts(_ string: String, maxLines: Int = maxLines) -> [Int] {
        let units = Array(string.utf16)
        var cuts: [Int] = []
        var start = 0
        while start < units.count {
            // The window: up to fallbackCharacters, ending early after the maxLines-th newline.
            var end = min(units.count, start + fallbackCharacters)
            var lines = 0
            var i = start
            while i < end {
                if units[i] == 0x0A {
                    lines += 1
                    if lines >= maxLines { end = i + 1; break }
                }
                i += 1
            }
            if end >= units.count { break }
            var cut = end
            if units[end - 1] != 0x0A {
                if let nl = (start + 1..<end).last(where: { units[$0 - 1] == 0x0A }) {
                    cut = nl
                } else if let sp = (start + 1..<end).last(where: { units[$0 - 1] == 0x20 }) {
                    cut = sp
                }
            }
            if cut < units.count, UTF16.isTrailSurrogate(units[cut]) { cut -= 1 }
            guard cut > start else { break }
            cuts.append(cut)
            start = cut
        }
        return cuts
    }

    private static func slice(_ s: AttributedString, _ string: String, _ from: Int, _ to: Int) -> AttributedString? {
        guard from < to,
              let a = string.utf16.index(string.utf16.startIndex, offsetBy: from, limitedBy: string.utf16.endIndex),
              let b = string.utf16.index(string.utf16.startIndex, offsetBy: to, limitedBy: string.utf16.endIndex),
              let lo = AttributedString.Index(a, within: s),
              let hi = AttributedString.Index(b, within: s) else { return nil }
        return AttributedString(s[lo..<hi])
    }

    /// The platform font for a run (TextKit measures with it; SwiftUI draws with `Font`).
    static func platformFont(size: CGFloat, bold: Bool, italic: Bool, mono: Bool) -> PlatformFont {
        #if canImport(UIKit)
        var f = mono ? UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular) : UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        if italic, let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.traitItalic)) { f = UIFont(descriptor: d, size: size) }
        return f
        #else
        var f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular) : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
        #endif
    }

    #if canImport(UIKit)
    typealias PlatformFont = UIFont
    #else
    typealias PlatformFont = NSFont
    #endif
}

/// Layout results by (paragraph with its fonts, width): a bubble's body is evaluated again on
/// every scroll, rotation or state change, and TextKit must not lay the paragraph out each
/// time. Main-thread only (SwiftUI bodies); bounded (cleared past `limit` entries).
@MainActor
enum LongTextCache {
    struct Key: Hashable {
        let text: AttributedString
        let width: CGFloat
        let kind: Int
    }
    private static var pieces: [Key: [AttributedString]] = [:]
    static let limit = 400
    private(set) static var misses = 0

    static func chunks(_ s: AttributedString, width: CGFloat?) -> [AttributedString] {
        // Short paragraphs never reach the layout: no cache entry for them either.
        guard LongText.mayNeedCutting(String(s.characters)) else { return [s] }
        return cached(Key(text: s, width: width ?? -1, kind: 0)) { LongText.chunks(s, width: width) }
    }

    static func messagesLineBreaks(_ s: AttributedString, width: CGFloat) -> AttributedString? {
        cached(Key(text: s, width: width, kind: 1)) { LongText.messagesLineBreaks(s, width: width).map { [$0] } ?? [] }.first
    }

    private static func cached(_ key: Key, _ make: () -> [AttributedString]) -> [AttributedString] {
        if let hit = pieces[key] { return hit }
        misses += 1
        let value = make()
        if pieces.count >= limit { pieces.removeAll(keepingCapacity: true) }
        pieces[key] = value
        return value
    }

    /// Tests.
    static func reset() { pieces = [:]; misses = 0 }
}
