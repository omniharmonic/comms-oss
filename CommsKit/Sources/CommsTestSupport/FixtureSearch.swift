import CommsClient
import CommsCore
import Foundation
import os

/// Full search and contact tidy-up over the fixture's own threads and message pages, behaving
/// like the server's contract (Task 4): every word must be present (the last one as a prefix),
/// highlight ranges in UTF-16, newest first; tidy acts on threads with `needsTidy`. Synthetic.
public final class FixtureSearchState: @unchecked Sendable {
    struct State {
        var enabled = true
        var queries: [(String, CommsSearchFilter)] = []
        var tidyCalls: [String] = []
        var undo: [String: CommsThread] = [:]
        var seq = 0
        var tidyPeople: [String: [CommsTidyItem.Suggestion]] = [:]
        var refuseCreate: CommsTidyRefusal?
    }
    let lock = OSAllocatedUnfairLock(initialState: State())
}

extension FixtureBackend {
    /// Answer search like a server without full search (`SearchUnavailable`).
    public func setSearchEnabled(_ on: Bool) { searchState.lock.withLock { $0.enabled = on } }
    /// Every search made (text, filter).
    public var searchQueries: [String] { searchState.lock.withLock { $0.queries.map(\.0) } }
    /// Every tidy call ("link th p", "create th name", "ignore th", "undo id").
    public var tidyCalls: [String] { searchState.lock.withLock { $0.tidyCalls } }
    /// Suggestions offered for a thread's "Who is this?".
    public func setTidySuggestions(_ s: [CommsTidyItem.Suggestion], threadID: String) { searchState.lock.withLock { $0.tidyPeople[threadID] = s } }
    /// Make the next create refuse (e.g. `.similarPeople`) unless `allowSimilar`.
    public func setCreateRefusal(_ r: CommsTidyRefusal?) { searchState.lock.withLock { $0.refuseCreate = r } }

    private func allMessages() -> [(CommsThread, CommsMessage)] {
        let threads = state.withLock { $0.threads }
        var out: [(CommsThread, CommsMessage)] = []
        for t in threads {
            let pages = state.withLock { $0.messagePages[t.id] } ?? [:]
            var seen = Set<String>()
            for page in pages.values {
                for m in page.messages where !m.redacted && seen.insert(m.id).inserted { out.append((t, m)) }
            }
        }
        return out
    }

    static func words(_ q: String) -> [String] {
        fold(q).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Highlight ranges (UTF-16) of every word in `text` (word starts only; the last word a prefix).
    static func highlights(_ text: String, words: [String]) -> [CommsTextRange]? {
        let folded = fold(text) as NSString
        var out: [CommsTextRange] = []
        for (i, w) in words.enumerated() {
            var found = false
            var range = NSRange(location: 0, length: folded.length)
            while true {
                let r = folded.range(of: w, options: [], range: range)
                if r.location == NSNotFound { break }
                let startOK = r.location == 0 || !CharacterSet.alphanumerics.contains(folded.character(at: r.location - 1).scalar)
                let end = r.location + r.length
                let endOK = i == words.count - 1 || end >= folded.length || !CharacterSet.alphanumerics.contains(folded.character(at: end).scalar)
                if startOK, endOK {
                    found = true
                    out.append(CommsTextRange(start: r.location, length: r.length))
                }
                range = NSRange(location: end, length: folded.length - end)
            }
            if !found { return nil }
        }
        return out.sorted { $0.start < $1.start }
    }

    public func search(query: String, filter: CommsSearchFilter, cursor: String?, limit: Int) async throws -> CommsSearchResults {
        let enabled = searchState.lock.withLock { s -> Bool in
            s.queries.append((query, filter))
            return s.enabled
        }
        guard enabled else { throw SearchUnavailable() }
        let words = Self.words(query)
        var hits: [CommsSearchHit] = []
        for (t, m) in allMessages() {
            if let id = filter.threadId, t.id != id { continue }
            if let p = filter.personId, t.personId != p { continue }
            if !filter.networks.isEmpty, Set(filter.networks).isDisjoint(with: t.networks) { continue }
            if let s = filter.fromSelf, m.sender.isSelf != s { continue }
            let text = m.body?.plain ?? ""
            guard !text.isEmpty, let h = Self.highlights(text, words: words) else { continue }
            hits.append(CommsSearchHit(id: "sr_\(t.id)_\(m.id)", threadId: t.id, messageId: m.id, sentAt: m.sentAt,
                                       sender: .init(name: m.sender.name, isSelf: m.sender.isSelf), text: text, highlights: h, origin: .live))
        }
        hits.sort { $0.sentAt > $1.sentAt }
        let offset = cursor.flatMap { Int($0.dropFirst(2)) } ?? 0
        let end = min(hits.count, offset + limit)
        let page = offset < end ? Array(hits[offset..<end]) : []
        let threads = state.withLock { $0.threads }
        let byID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let used = Array(Set(page.map(\.threadId))).compactMap { byID[$0] }
        let folded = Self.fold(query)
        let suggestions = cursor == nil ? Array(threads.filter { Self.fold($0.title).contains(folded) }.prefix(8)) : nil
        return CommsSearchResults(query: query, messages: page, threads: used, suggestions: suggestions,
                                  history: CommsSearchHistory(sources: 1, pending: 0, failed: 0, messages: hits.count),
                                  next: end < hits.count ? "o:\(end)" : nil)
    }

    public func searchMedia(kind: CommsMediaKind, query: String?, threadID: String?, cursor: String?) async throws -> CommsMediaPage {
        guard searchState.lock.withLock({ $0.enabled }) else { throw SearchUnavailable() }
        var items: [CommsMediaItem] = []
        let q = query.map(Self.fold) ?? ""
        for (t, m) in allMessages() {
            if let threadID, t.id != threadID { continue }
            let sender = CommsSearchHit.Sender(name: m.sender.name, isSelf: m.sender.isSelf)
            if kind == .photos {
                for (i, a) in m.attachments.enumerated() where a.kind == .image || a.kind == .video {
                    items.append(CommsMediaItem(id: "m_\(m.id)_\(i)", threadId: t.id, messageId: m.id, sentAt: m.sentAt, sender: sender, attachment: a))
                }
            } else {
                for l in m.linkPreviews where q.isEmpty || Self.fold("\(l.url) \(l.title ?? "")").contains(q) {
                    items.append(CommsMediaItem(id: "m_\(m.id)_\(l.url)", threadId: t.id, messageId: m.id, sentAt: m.sentAt, sender: sender,
                                                link: .init(url: l.url, title: l.title, siteName: l.siteName, imageToken: l.imageToken)))
                }
            }
        }
        return CommsMediaPage(items: items.sorted { $0.sentAt > $1.sentAt }, next: nil)
    }

    // MARK: Tidy

    private func tidyItem(_ t: CommsThread) -> CommsTidyItem {
        let count = (state.withLock { $0.messagePages[t.id] } ?? [:]).values.reduce(0) { $0 + $1.messages.count }
        let suggestions = searchState.lock.withLock { $0.tidyPeople[t.id] } ?? []
        let handle: CommsTidyItem.Handle? = t.titleSource == .handle ? .init(kind: "phone", value: t.title) : nil
        return CommsTidyItem(threadId: t.id, network: t.networks.first ?? .unknown(""), name: t.title, avatar: t.avatar, handle: handle,
                             messageCount: count, lastActivityAt: t.lastActivityAt, suggestions: suggestions)
    }

    public func tidyList(cursor: String?, limit: Int) async throws -> CommsTidyPage {
        let items = state.withLock { $0.threads }.filter { $0.needsTidy == true }.map(tidyItem)
            .sorted { ($0.messageCount, $0.lastActivityAt) > ($1.messageCount, $1.lastActivityAt) }
        return CommsTidyPage(people: Array(items.prefix(limit)), total: items.count, next: nil)
    }

    public func tidyItem(threadID: String) async throws -> CommsTidyItem? {
        guard let t = currentThread(id: threadID), t.needsTidy == true else { return nil }
        return tidyItem(t)
    }

    private func resolve(_ threadID: String, call: String, kind: String, personID: String?, name: String?) throws -> CommsTidyResult {
        guard let before = currentThread(id: threadID), before.needsTidy == true else { throw CommsTidyRefusal.alreadyDone }
        var t = before
        let id = searchState.lock.withLock { s -> String in
            s.tidyCalls.append(call)
            s.seq += 1
            s.undo["ta_\(s.seq)"] = before
            return "ta_\(s.seq)"
        }
        t.needsTidy = nil
        if kind != "ignore" { t.personId = personID }
        replaceThread(t)
        return CommsTidyResult(action: CommsTidyAction(id: id, kind: kind, threadId: threadID, personId: personID, personName: name), thread: t)
    }

    public func tidyLink(threadID: String, personID: String) async throws -> CommsTidyResult {
        let name = (searchState.lock.withLock { $0.tidyPeople[threadID] } ?? []).first { $0.personId == personID }?.name
        return try resolve(threadID, call: "link \(threadID) \(personID)", kind: "link", personID: personID, name: name)
    }

    public func tidyCreate(threadID: String, name: String, allowSimilar: Bool) async throws -> CommsTidyResult {
        if !allowSimilar, let r = searchState.lock.withLock({ $0.refuseCreate }) { throw r }
        return try resolve(threadID, call: "create \(threadID) \(name)", kind: "create", personID: "p_new_\(threadID)", name: name)
    }

    public func tidyIgnore(threadID: String) async throws -> CommsTidyResult {
        try resolve(threadID, call: "ignore \(threadID)", kind: "ignore", personID: nil, name: nil)
    }

    public func tidyUndo(actionID: String) async throws -> CommsTidyResult {
        guard let before = searchState.lock.withLock({ s -> CommsThread? in
            s.tidyCalls.append("undo \(actionID)")
            return s.undo.removeValue(forKey: actionID)
        }) else { throw CommsTidyRefusal.alreadyDone }
        replaceThread(before)
        return CommsTidyResult(action: CommsTidyAction(id: actionID, kind: "undo", threadId: before.id, undone: true), thread: before)
    }

}

private extension unichar {
    var scalar: Unicode.Scalar { Unicode.Scalar(self) ?? " " }
}
