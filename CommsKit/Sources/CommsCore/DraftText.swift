import CoreGraphics
import Foundation

/// The chat-draft character policy — the Swift twin of the server's `comms/draft-text.ts` (Task 2
/// review rounds 1–3; controller rulings of round 3: strict and simple, same rule both sides).
///
/// Whitespace: only U+0020 and LF; no tab, no CR, no trailing spaces on a line, at most 2 blank
/// lines in a row, no leading/trailing blank lines (the server normalises at propose, so a valid
/// draft already has this shape). Refused: every control but LF; every space separator but U+0020;
/// line/paragraph separators; every Cf; every Default_Ignorable_Code_Point; tags U+E0000–E007F
/// (no subdivision flags); every variation selector; U+2800; U+FFFC; a skin tone not directly
/// after an Emoji_Modifier_Base. Exceptions: ONE U+FE0F directly after a character with the Emoji
/// property; ZWJ only between two emoji-presented pictographs (each optionally with one FE0F or one
/// skin tone), at most 4 per sequence; a skin tone directly after a modifier base.
public enum DraftText {
    public static let maxCharacters = 4_000
    public static let maxZWJPerSequence = 4

    private static let zwj: UInt32 = 0x200D, vs16: UInt32 = 0xFE0F

    private static func props(_ v: UInt32) -> Unicode.Scalar.Properties? { Unicode.Scalar(v)?.properties }
    private static func hasEmoji(_ v: UInt32) -> Bool { props(v)?.isEmoji ?? false }
    private static func isSkinTone(_ v: UInt32) -> Bool { (0x1F3FB...0x1F3FF).contains(v) }
    private static func isRegional(_ v: UInt32) -> Bool { (0x1F1E6...0x1F1FF).contains(v) }
    /// Emoji ∩ Extended_Pictographic (as the server computes it).
    public static func isPictograph(_ v: UInt32) -> Bool { v > 0x7F && hasEmoji(v) && !isRegional(v) && !isSkinTone(v) }

    /// A code point a draft may not hold where no exception applies.
    public static func isRefused(_ v: UInt32) -> Bool {
        if v == 0x0A || v == 0x20 { return false }
        if v < 0x20 || (0x7F...0x9F).contains(v) { return true }
        if (0xFE00...0xFE0F).contains(v) || (0xE0100...0xE01EF).contains(v) || (0xE0000...0xE007F).contains(v) { return true }
        if v == 0x2800 || v == 0xFFFC || isSkinTone(v) { return true }
        guard let p = props(v) else { return true }
        switch p.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator, .format: return true
        default: return p.isDefaultIgnorableCodePoint
        }
    }

    private static func element(_ c: [UInt32], _ i: Int) -> Int {
        guard i + 1 < c.count else { return i + 1 }
        let next = c[i + 1]
        if next == vs16 { return i + 2 }
        if isSkinTone(next), props(c[i])?.isEmojiModifierBase ?? false { return i + 2 }
        return i + 1
    }

    private static func presented(_ c: [UInt32], _ i: Int, _ end: Int) -> Bool {
        (props(c[i])?.isEmojiPresentation ?? false) || (end - i == 2 && c[i + 1] == vs16)
    }

    /// The index (in scalars) of the first refused code point, or nil.
    public static func firstRefused(_ text: String) -> Int? {
        let c = text.unicodeScalars.map(\.value)
        var i = 0
        while i < c.count {
            let v = c[i]
            if isPictograph(v) {
                var start = i
                var j = element(c, i)
                var zwjs = 0
                while j + 1 < c.count, c[j] == zwj, zwjs < maxZWJPerSequence, isPictograph(c[j + 1]), presented(c, start, j) {
                    let k = element(c, j + 1)
                    if !presented(c, j + 1, k) { break }
                    zwjs += 1
                    start = j + 1
                    j = k
                }
                i = j
                continue
            }
            if hasEmoji(v), !isSkinTone(v) {
                i += (i + 1 < c.count && c[i + 1] == vs16) ? 2 : 1
                continue
            }
            if isRefused(v) { return i }
            i += 1
        }
        return nil
    }

    /// The whitespace shape a draft must have (nil = fine).
    public static func whitespaceProblem(_ t: String) -> String? {
        if t.contains("\t") { return "Tabs are not allowed." }
        if t.unicodeScalars.contains("\r") { return "Carriage returns are not allowed." }
        if t.hasSuffix(" ") || t.contains(" \n") { return "Trailing spaces are not allowed." }
        if t.contains("\n\n\n\n") { return "At most 2 blank lines in a row." }
        if t.hasPrefix("\n") || t.hasSuffix("\n") { return "No blank lines at the start or end." }
        return nil
    }

    /// Why this draft text may not be approved (nil = fine).
    public static func problem(_ text: String) -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "The draft is empty." }
        if text.unicodeScalars.count > maxCharacters { return "This draft is longer than \(maxCharacters) characters." }
        if let ws = whitespaceProblem(text) { return "This draft can't be sent: \(ws) Discard it." }
        if firstRefused(text) != nil { return "This draft contains invisible or formatting characters, so it can't be sent. Discard it." }
        return nil
    }
}

/// Which parts of a scrolled text have been ON SCREEN (review round 2, N1): the union of the
/// visible content ranges seen so far. Approve & Send needs all of [0, contentHeight] covered —
/// jumps (scroll-indicator drags) leave gaps, and gaps keep it disabled.
public struct ReadCoverage: Equatable, Sendable {
    public private(set) var ranges: [ClosedRange<CGFloat>] = []
    public private(set) var contentHeight: CGFloat = 0
    /// The width the ranges were measured at: a different width reflows the lines (review M1).
    public private(set) var width: CGFloat = 0
    public static let tolerance: CGFloat = 2

    public init() {}

    /// Record what is visible now (`visible` in content coordinates). A different content height
    /// (Dynamic Type, rotation reflow) starts over: positions no longer mean the same lines.
    public mutating func see(_ visible: ClosedRange<CGFloat>, contentHeight h: CGFloat, width w: CGFloat = 0) {
        if abs(h - contentHeight) > Self.tolerance || abs(w - width) > Self.tolerance {
            contentHeight = h
            width = w
            ranges = []
        }
        let r = max(0, visible.lowerBound)...max(max(0, visible.lowerBound), min(h, visible.upperBound))
        guard r.upperBound > r.lowerBound else { return }
        var merged: [ClosedRange<CGFloat>] = []
        var cur = r
        for x in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if x.upperBound + Self.tolerance < cur.lowerBound || cur.upperBound + Self.tolerance < x.lowerBound {
                merged.append(x)
            } else {
                cur = min(x.lowerBound, cur.lowerBound)...max(x.upperBound, cur.upperBound)
            }
        }
        merged.append(cur)
        ranges = merged.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Every line has been on screen.
    public var isComplete: Bool {
        guard contentHeight > 0, ranges.count == 1, let r = ranges.first else { return false }
        return r.lowerBound <= Self.tolerance && r.upperBound >= contentHeight - Self.tolerance
    }
}
