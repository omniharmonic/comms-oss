import CommsClient
import Foundation

/// A member the owner picked from the `@` suggestions: shown in the draft as their name (the
/// "@query" is replaced by it, as Messages does).
public struct ComposerMention: Sendable, Hashable {
    public var userID: String
    public var name: String
    /// Where the name was inserted in the draft (UTF-16), kept current through edits
    /// (`MentionText.track`). Nil = unknown: the name is looked for by word (older callers).
    public var location: Int?

    public init(userID: String, name: String, location: Int? = nil) {
        self.userID = userID
        self.name = name
        self.location = location
    }
}

/// From the composer's draft + picked mentions to the wire's UTF-16 ranges, and back to rich
/// text for the pending bubble.
public enum MentionText {
    /// The `@query` being typed at the end of `draft` (after a space / line start), or nil.
    /// "Hi @Sa" → "Sa"; "@" → ""; "mail@x" → nil.
    public static func activeQuery(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex {
            let before = draft[draft.index(before: at)]
            guard before.isWhitespace || before.isPunctuation else { return nil }
        }
        let query = draft[draft.index(after: at)...]
        guard query.count <= 30, !query.contains(where: \.isNewline), query.split(separator: " ").count <= 2, !query.hasSuffix("  ") else { return nil }
        return String(query)
    }

    /// The draft with the trailing `@query` replaced by `name` + a space, and where the name now
    /// starts (UTF-16) — the pick binds to exactly that place.
    public static func completeLocated(_ draft: String, with name: String) -> (draft: String, location: Int)? {
        guard activeQuery(in: draft) != nil, let at = draft.lastIndex(of: "@") else { return nil }
        let head = String(draft[..<at])
        return (head + name + " ", head.utf16.count)
    }

    /// Keep picks bound to their names while the draft is edited from `old` to `new`: the one
    /// edited span (common prefix/suffix) shifts picks after it and drops picks it touches.
    public static func track(_ picks: [ComposerMention], from old: String, to new: String) -> [ComposerMention] {
        guard old != new else { return picks }
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let editEnd = a.count - suffix
        let delta = b.count - a.count
        let inserted = Array(b[prefix..<(b.count - suffix)])
        // Letters typed right against a name extend the word ("Sam" → "Sammy"): not the name.
        func wordy(_ u: UInt16?) -> Bool { u.flatMap { Unicode.Scalar($0) }.map { $0.properties.isAlphabetic || ("0"..."9").contains(Character($0)) } ?? false }
        return picks.compactMap { p in
            guard let l = p.location else { return p }
            let end = l + p.name.utf16.count
            if end < prefix || (end == prefix && !wordy(inserted.first)) { return p }
            if l > editEnd || (l == editEnd && !wordy(inserted.last)) { var q = p; q.location = l + delta; return q }
            return nil // the edit touched the name: no longer a mention
        }
    }

    /// The draft with the trailing `@query` replaced by `name` + a space.
    public static func complete(_ draft: String, with name: String) -> String {
        guard activeQuery(in: draft) != nil, let at = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<at]) + name + " "
    }

    /// Members matching `query` (a word of their name starts with it; case/diacritic-blind),
    /// in the order given, without the owner.
    public static func candidates(_ members: [CommsMember], query: String, excluding selfIDs: Set<String>, limit: Int = 8) -> [CommsMember] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let matches = members.filter { m in
            guard !selfIDs.contains(m.id), !m.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            if q.isEmpty { return true }
            let name = m.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let needle = q.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return name.hasPrefix(needle) || name.split(whereSeparator: { $0 == " " || $0 == "-" }).contains { $0.hasPrefix(needle) }
        }
        return Array(matches.prefix(limit))
    }

    /// Where each picked name stands in `text`. A pick with a `location` binds to exactly that
    /// range (shifted by `offset`, the characters trimmed off the front) and only if the name is
    /// still there; without one, the first free whole-word occurrence. Never overlapping.
    public static func resolve(_ text: String, picks: [ComposerMention], offset: Int = 0) -> [CommsMention] {
        let ns = text as NSString
        var taken: [NSRange] = []
        var out: [CommsMention] = []
        for pick in picks where !pick.name.isEmpty {
            if let l = pick.location {
                let r = NSRange(location: l - offset, length: (pick.name as NSString).length)
                guard r.location >= 0, r.location + r.length <= ns.length, ns.substring(with: r) == pick.name,
                      !taken.contains(where: { NSIntersectionRange($0, r).length > 0 }) else { continue }
                taken.append(r)
                out.append(CommsMention(userId: pick.userID, start: r.location, length: r.length))
                continue
            }
            var from = 0
            while from < ns.length {
                let r = ns.range(of: pick.name, options: [], range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound else { break }
                from = r.location + max(1, r.length)
                guard isWordBoundary(ns, before: r.location), isWordBoundary(ns, after: r.location + r.length),
                      !taken.contains(where: { NSIntersectionRange($0, r).length > 0 }) else { continue }
                taken.append(r)
                out.append(CommsMention(userId: pick.userID, start: r.location, length: r.length))
                break
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    private static func isWordBoundary(_ s: NSString, before i: Int) -> Bool {
        guard i > 0 else { return true }
        return !isWordCharacter(s.character(at: i - 1))
    }
    private static func isWordBoundary(_ s: NSString, after i: Int) -> Bool {
        guard i < s.length else { return true }
        return !isWordCharacter(s.character(at: i))
    }
    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true } // a surrogate half: part of a word-ish glyph
        return scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar)) || scalar == "_"
    }

    /// The text as the server would echo it: plain runs and bold mention spans.
    public static func richText(_ text: String, mentions: [CommsMention]) -> CommsRichText {
        let ns = text as NSString
        var spans: [CommsSpan] = []
        var at = 0
        for m in mentions.sorted(by: { $0.start < $1.start }) where m.start >= at && m.start + m.length <= ns.length {
            if m.start > at { spans.append(.text(ns.substring(with: NSRange(location: at, length: m.start - at)))) }
            spans.append(.mention(id: m.userId, name: ns.substring(with: NSRange(location: m.start, length: m.length))))
            at = m.start + m.length
        }
        if at < ns.length { spans.append(.text(ns.substring(from: at))) }
        return CommsRichText(spans: spans, plain: text, jumboEmoji: false)
    }
}
