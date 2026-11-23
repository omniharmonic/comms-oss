import CommsClient
import Foundation
import Observation
import PrismTransport

/// A token in the search field (Messages: "Messages with Ann", "in Trail Crew"; Comms adds
/// network and "From me").
public enum SearchToken: Hashable, Sendable, Identifiable {
    case person(id: String, name: String)
    case conversation(id: String, title: String)
    case network(CommsNetwork)
    case fromMe

    public var id: String {
        switch self {
        case .person(let id, _): "person:\(id)"
        case .conversation(let id, _): "thread:\(id)"
        case .network(let n): "network:\(n.wire)"
        case .fromMe: "from:me"
        }
    }

    /// What the token reads in the field.
    public var label: String {
        switch self {
        case .person(_, let name): name
        case .conversation(_, let title): title
        case .network(let n): n.displayName
        case .fromMe: "From Me"
        }
    }

    /// The suggestion row's wording.
    public var suggestion: String {
        switch self {
        case .person(_, let name): "Messages with \(name)"
        case .conversation(_, let title): "Messages in \(title)"
        case .network(let n): "Messages on \(n.displayName)"
        case .fromMe: "Messages from Me"
        }
    }

    public var systemImage: String {
        switch self {
        case .person: "person.crop.circle"
        case .conversation: "bubble.left.and.bubble.right"
        case .network: "network"
        case .fromMe: "person.fill"
        }
    }
}

/// What the results show: everything, or one of Messages' "See All" lists.
public enum SearchScope: String, Sendable, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", links = "Links"
    public var id: String { rawValue }
}

/// Messages-style search over every message (`GET /search`): the hits as bubbles with their
/// highlighted words, conversation suggestions ("Messages with" / "in" tokens), and the Photos /
/// Links of about the last 90 days. Typing is debounced; a newer keystroke cancels the request
/// in flight and stale answers are dropped. A server without full search (`search_disabled`)
/// leaves `isAvailable` false: the list's own thread search still answers.
@MainActor @Observable
public final class MessageSearchStore {
    private let backend: any ChatBackend

    public var text = "" { didSet { if text != oldValue { restart() } } }
    public var tokens: [SearchToken] = [] { didSet { if tokens != oldValue { restart() } } }
    public var scope: SearchScope = .all { didSet { if scope != oldValue { loadMediaIfNeeded() } } }

    public private(set) var hits: [CommsSearchHit] = []
    /// The threads hits belong to, by id (title, avatar, network for each result).
    public private(set) var threads: [String: CommsThread] = [:]
    public private(set) var suggestions: [CommsThread] = []
    public private(set) var photos: [CommsMediaItem] = []
    public private(set) var links: [CommsMediaItem] = []
    public private(set) var isSearching = false
    public private(set) var hasMore = false
    /// False once the server said it has no full search.
    public private(set) var isAvailable = true
    public private(set) var error: String?
    /// Vault transcripts still waiting to be indexed (older history may be missing).
    public private(set) var historyPending = 0
    /// The server ranked only its newest matches (a per-request bound).
    public private(set) var isPartial = false
    /// When the server last said it has no full search; asked again after `availabilityRetry`
    /// (review M4: turning the server flag on needs no app restart).
    @ObservationIgnored private var unavailableSince: Date?
    @ObservationIgnored public var availabilityRetry: TimeInterval = 300

    @ObservationIgnored public var debounce: Duration
    @ObservationIgnored public var pageSize = 30
    /// The task running the current request (tests await it).
    @ObservationIgnored public private(set) var work: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var mediaGeneration = 0

    public init(backend: any ChatBackend, debounce: Duration = .milliseconds(250)) {
        self.backend = backend
        self.debounce = debounce
    }

    /// The typed text, trimmed.
    public var term: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Search shows results (the list hides) while there is text or a token.
    public var isActive: Bool { !term.isEmpty || !tokens.isEmpty }

    public var filter: CommsSearchFilter {
        var f = CommsSearchFilter()
        for t in tokens {
            switch t {
            case .person(let id, _): f.personId = id
            case .conversation(let id, _): f.threadId = id
            case .network(let n): f.networks.append(n)
            case .fromMe: f.fromSelf = true
            }
        }
        return f
    }

    /// Tokens to offer under the field: a matching DM's person ("Messages with"), a matching
    /// group ("in"), at most three, never one already chosen.
    public var suggestedTokens: [SearchToken] {
        var out: [SearchToken] = []
        for t in suggestions {
            let token: SearchToken = t.kind == .dm
                ? (t.personId.map { .person(id: $0, name: t.title) } ?? .conversation(id: t.id, title: t.title))
                : .conversation(id: t.id, title: t.title)
            if !tokens.contains(token), !out.contains(token) { out.append(token) }
            if out.count == 3 { break }
        }
        return out
    }

    public func add(_ token: SearchToken) {
        guard !tokens.contains(token) else { return }
        // One person / conversation at a time (the server filters by one of each).
        tokens.removeAll { existing in
            switch (existing, token) {
            case (.person, .person), (.conversation, .conversation), (.fromMe, .fromMe): true
            default: false
            }
        }
        tokens.append(token)
        // The words that suggested the token are now the token.
        if case .person(_, let name) = token, name.localizedCaseInsensitiveContains(term) { text = "" }
        if case .conversation(_, let title) = token, title.localizedCaseInsensitiveContains(term) { text = "" }
    }

    public func remove(_ token: SearchToken) { tokens.removeAll { $0 == token } }

    public func clear() {
        text = ""
        tokens = []
        scope = .all
    }

    private func restart() {
        if !isAvailable, let since = unavailableSince, Date().timeIntervalSince(since) >= availabilityRetry {
            isAvailable = true
            unavailableSince = nil
        }
        generation += 1
        work?.cancel()
        cursor = nil
        hasMore = false
        error = nil
        guard isActive else {
            hits = []
            threads = [:]
            suggestions = []
            photos = []
            links = []
            isSearching = false
            work = nil
            return
        }
        let gen = generation
        let q = term
        let filter = filter
        isSearching = !q.isEmpty
        work = Task { [backend, debounce, pageSize] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, gen == self.generation else { return }
            self.loadMediaIfNeeded()
            guard !q.isEmpty else {
                self.hits = []
                self.suggestions = []
                self.isSearching = false
                return
            }
            do {
                let r = try await backend.search(query: q, filter: filter, cursor: nil, limit: pageSize)
                guard gen == self.generation else { return }
                self.apply(r, replacing: true)
            } catch {
                guard gen == self.generation, !Task.isCancelled else { return }
                self.fail(error)
            }
            self.isSearching = false
        }
    }

    /// The next page (the results' end).
    public func loadMore() async {
        guard let cursor, !isSearching, isAvailable else { return }
        let gen = generation
        isSearching = true
        defer { if gen == generation { isSearching = false } }
        do {
            let r = try await backend.search(query: term, filter: filter, cursor: cursor, limit: pageSize)
            guard gen == generation else { return }
            apply(r, replacing: false)
        } catch {
            guard gen == generation else { return }
            fail(error)
        }
    }

    private func apply(_ r: CommsSearchResults, replacing: Bool) {
        if replacing { hits = r.messages } else {
            let seen = Set(hits.map(\.id))
            hits += r.messages.filter { !seen.contains($0.id) }
        }
        for t in r.threads { threads[t.id] = t }
        if let s = r.suggestions { suggestions = s }
        for t in suggestions { threads[t.id] = threads[t.id] ?? t }
        cursor = r.next
        hasMore = r.next != nil
        historyPending = r.history?.pending ?? 0
        if replacing { isPartial = r.partial } else { isPartial = isPartial || r.partial }
        error = nil
    }

    private func fail(_ error: any Error) {
        if error is SearchUnavailable || (error as? PrismError)?.serverCode == "search_disabled" {
            isAvailable = false
            unavailableSince = Date()
            hits = []
            return
        }
        self.error = "Search isn't available right now."
    }

    /// Photos (recent, or in the chosen conversation) and links matching the text.
    private func loadMediaIfNeeded() {
        guard isActive, isAvailable else { return }
        mediaGeneration += 1
        let gen = mediaGeneration
        let q = term
        let thread = filter.threadId
        let wantPhotos = scope == .photos || (scope == .all && thread != nil)
        Task { [backend] in
            async let links = try? backend.searchMedia(kind: .links, query: q.isEmpty ? nil : q, threadID: thread, cursor: nil)
            async let photos = wantPhotos ? try? backend.searchMedia(kind: .photos, query: nil, threadID: thread, cursor: nil) : nil
            let (l, p) = await (links, photos)
            guard gen == self.mediaGeneration else { return }
            self.links = l?.items ?? []
            self.photos = p?.items ?? (wantPhotos ? [] : self.photos)
        }
    }
}
