import CommsClient
import Foundation
import Observation

/// The conversation list: pinned threads (the grid) and the rows below them, for the current
/// filter. Titles, avatars and order come from the server; the store never re-derives them.
@MainActor @Observable
public final class ThreadListStore {
    public private(set) var pinned: [CommsThread] = [] { didSet { if !patchingIndex { searchIndex = nil } } }
    public private(set) var threads: [CommsThread] = [] { didSet { if !patchingIndex { searchIndex = nil } } }
    public private(set) var isLoading = false
    public private(set) var error: String?
    /// The cursor for the next page; nil when the list is complete.
    public private(set) var nextCursor: String?
    public var hasMore: Bool { nextCursor != nil }

    /// The conversation open in the transcript. It reads as read in the list (Messages clears
    /// the dot as you open a conversation, and messages arriving while it is open are seen):
    /// its unread count is zeroed locally on open and on every refetch while it stays open.
    ///
    /// Read state (Sprint Task 1): opening tells the server (`markRead`, `viewing: true` — no
    /// notification for it meanwhile), the lease is renewed while it stays open and the app is
    /// active, messages arriving while it is open are read, and closing drops the lease. A
    /// thread the owner just marked unread stays unread while it is still selected.
    public var openThreadID: String? {
        didSet {
            guard openThreadID != oldValue else { return }
            if let old = oldValue, !keptUnread.contains(old) { reportRead(old, viewing: false) }
            keptUnread = []
            if let id = openThreadID {
                markSeen(id)
                if appActive { reportRead(id, viewing: true) }
            }
            restartLease()
        }
    }

    /// Whether the owner is actually reading the open thread: false while the app is in the
    /// background / inactive and — on the Mac — unless the window is key, the app frontmost and
    /// someone used the Mac recently (`ReadingPresence`). While false no lease is held (other
    /// devices are notified as usual) and arrivals are not marked read.
    public var appActive = true {
        didSet {
            guard appActive != oldValue, let id = openThreadID, !keptUnread.contains(id) else { return }
            reportRead(id, viewing: appActive)
            restartLease()
        }
    }

    /// Unread conversations that Need attention (the app badge), from the server; 0 until known.
    public private(set) var attentionUnread = 0

    /// Threads marked unread while open: they keep their dot until opened again.
    @ObservationIgnored private var keptUnread: Set<String> = []
    /// Read-state calls, serialized (tests await `readWork`).
    @ObservationIgnored public private(set) var readWork: Task<Void, Never>?
    @ObservationIgnored private var leaseTask: Task<Void, Never>?
    @ObservationIgnored private var badgeTask: Task<Void, Never>?
    /// How often an open thread's "viewing" lease is renewed (the server keeps it 90 s).
    @ObservationIgnored public var leaseInterval: Duration = .seconds(60)
    /// How long badge refreshes are collected after a change.
    @ObservationIgnored public var badgeDelay: Duration = .milliseconds(800)

    private func enqueueRead(_ op: @escaping @Sendable (any ChatBackend) async throws -> Void) {
        let prev = readWork
        let backend = self.backend
        readWork = Task {
            await prev?.value
            try? await op(backend)
        }
    }

    /// The open Telegram forum's read point (the transcript's view: its topic and the newest message
    /// shown). A forum is read only up to what was on screen, and one topic at a time in a topic view
    /// (fix round 1, I-4); nil = an ordinary thread (read up to its latest).
    @ObservationIgnored public var forumReadPoint: (@MainActor (String) -> ForumReadPoint?)?

    private func reportRead(_ id: String, viewing: Bool?, explicit: Bool = false) {
        // The owner's explicit Mark as Read reads the whole forum; opening / viewing reads what is shown.
        if !explicit, id == openThreadID {
            if let p = forumReadPoint?(id) {
                enqueueRead { try await $0.markRead(threadID: id, upTo: p.upTo, viewing: viewing, explicit: false, topic: p.topic) }
                return
            }
            // A forum whose transcript shows nothing yet: nothing is read; its first page reports.
            if viewing != false, isForum(id) { return }
        }
        enqueueRead { try await $0.markRead(threadID: id, upTo: nil, viewing: viewing, explicit: explicit) }
    }

    private func isForum(_ id: String) -> Bool { (pinned + threads).first { $0.id == id }?.forum != nil }

    /// The open forum's view moved (a page loaded, another topic, a message arrived): read it.
    public func forumReadPointChanged(_ id: String) {
        guard id == openThreadID, appActive, !keptUnread.contains(id) else { return }
        reportRead(id, viewing: true)
    }

    private func restartLease() {
        leaseTask?.cancel()
        leaseTask = nil
        guard let id = openThreadID, appActive, !keptUnread.contains(id) else { return }
        let interval = leaseInterval
        leaseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.openThreadID == id, self.appActive, !self.keptUnread.contains(id) else { return }
                self.reportRead(id, viewing: true)
            }
        }
    }

    /// Swipe / context menu / VoiceOver "Mark as Read" — the owner's EXPLICIT action: the server
    /// sends a network read receipt where supported even with the receipts toggle off (D10 ruling).
    /// Opening, viewing and arrivals while open are never explicit.
    public func markRead(_ id: String) {
        keptUnread.remove(id)
        setLocalUnread(id) { $0 = 0 }
        reportRead(id, viewing: id == openThreadID && appActive ? true : nil, explicit: true)
        scheduleBadgeRefresh()
    }

    /// Swipe / context menu "Mark as Unread": the dot comes back (and stays while selected).
    public func markUnread(_ id: String) {
        if id == openThreadID {
            keptUnread.insert(id)
            leaseTask?.cancel()
        }
        setLocalUnread(id) { $0 = max($0, 1) }
        enqueueRead { try await $0.markUnread(threadID: id) }
        scheduleBadgeRefresh()
    }

    private func setLocalUnread(_ id: String, _ change: (inout Int) -> Void) {
        patchingIndex = true
        defer { patchingIndex = false }
        if let i = pinned.firstIndex(where: { $0.id == id }) { change(&pinned[i].unread.count); indexPut(pinned[i]) }
        if let i = threads.firstIndex(where: { $0.id == id }) { change(&threads[i].unread.count); indexPut(threads[i]) }
        if !searchTerm.isEmpty, let i = serverMatches.firstIndex(where: { $0.id == id }) {
            change(&serverMatches[i].unread.count)
            mergeSearchResults()
        }
    }

    /// Ask the server for the badge count again (coalesced).
    public func scheduleBadgeRefresh() {
        badgeTask?.cancel()
        let delay = badgeDelay
        badgeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refreshBadge()
        }
    }

    /// The badge count now (also after `load()`).
    public func refreshBadge() async {
        await readWork?.value
        if let summary = try? await backend.unreadSummary() { attentionUnread = summary.attention }
    }

    private func markSeen(_ id: String) {
        guard !keptUnread.contains(id) else { return }
        patchingIndex = true
        defer { patchingIndex = false }
        if let i = pinned.firstIndex(where: { $0.id == id }), pinned[i].unread.count > 0 { pinned[i].unread.count = 0; indexPut(pinned[i]) }
        if let i = threads.firstIndex(where: { $0.id == id }), threads[i].unread.count > 0 { threads[i].unread.count = 0; indexPut(threads[i]) }
        if !searchTerm.isEmpty, let i = serverMatches.firstIndex(where: { $0.id == id }), serverMatches[i].unread.count > 0 {
            serverMatches[i].unread.count = 0
            mergeSearchResults()
        }
    }

    /// Folder + Filter By toggles. Setting a different value reloads the list.
    public var filter = FilterState() {
        didSet {
            guard filter != oldValue else { return }
            // A Filter choice shows conversations again (it never applies to Needs You).
            showsNeedsYou = false
            // Synchronously retire the old folder's list: no stale rows if the reload fails, and
            // no `loadMore()` can send the old cursor with the new query before `load()` runs.
            generation += 1
            nextCursor = nil
            pinned = []
            threads = []
            error = nil
            isLoading = true
            loadTask = Task { await load() }
            // Search covers every conversation (folders and filters do not apply): it stays.
            if !searchTerm.isEmpty { mergeSearchResults() }
        }
    }

    // MARK: Search

    /// The Search field's text. Search covers EVERY conversation, as in Messages: the folder
    /// and the Filter By choices do not apply while searching.
    ///
    /// 1. At once: matches from the loaded list (titles and previews, case-, diacritic- and
    ///    width-insensitive), plus the previous text's server matches that still match — they
    ///    stay on screen until the new answer replaces them (no flicker while typing).
    /// 2. After `searchDebounce` without another keystroke: the server (`q=`, every folder,
    ///    `searchLimit` per folder); a newer keystroke cancels it and stale answers are dropped.
    /// 3. Merged newest activity first. `loadMoreSearchResults()` pages further (the list's end).
    public var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            let term = Self.searchTerm(searchText)
            guard term != searchTerm else { return }
            searchTerm = term
            restartSearch()
        }
    }
    /// The rows to show while searching (nil = not searching: show the list).
    public private(set) var searchResults: [CommsThread]?
    /// The server's answer for the current text is still on its way.
    public private(set) var isSearchingServer = false
    /// The server has more matches than shown (`loadMoreSearchResults()`).
    public private(set) var searchHasMore = false
    /// Search texts the server was asked for, once per search (tests / measurements).
    @ObservationIgnored public private(set) var searchRequests: [String] = []
    /// How long typing must pause before the server is asked.
    @ObservationIgnored public var searchDebounce: Duration
    /// Results asked of the server per folder and page.
    @ObservationIgnored public var searchLimit = 30
    /// The folders a search covers. `/threads` searches one folder per request (it has no
    /// "every folder" value without a person), so a search asks each, concurrently.
    @ObservationIgnored public var searchFolders: [CommsFolder] = FilterState.folders

    @ObservationIgnored private var searchTerm = ""
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var isLoadingMoreSearch = false
    /// The server's matches (merged with the local ones). After a keystroke they are the
    /// previous text's, narrowed to the new text, until the new answer lands.
    @ObservationIgnored private var serverMatches: [CommsThread] = []
    /// The next page's cursor per folder (absent = that folder is complete).
    @ObservationIgnored private var searchCursors: [CommsFolder: String] = [:]
    /// Server rows older than this wait for the next page: a folder with more pages may hold
    /// newer matches than another folder's older ones, so paging only ever adds at the end.
    @ObservationIgnored private var searchWatermark: Date?
    /// The loaded threads (pins first) with their folded title + preview as UTF-8 bytes. Built
    /// on the first keystroke, patched in place by live changes, dropped when search ends.
    @ObservationIgnored private var searchIndex: [(thread: CommsThread, text: [UInt8])]?
    @ObservationIgnored private var patchingIndex = false
    /// The last local scan (term → matching index positions): typing on narrows it.
    @ObservationIgnored private var lastScan: (term: String, hits: [Int])?

    /// The task running the current search's server request (tests await it).
    @ObservationIgnored public private(set) var searchWork: Task<Void, Never>?

    static func searchTerm(_ text: String) -> String {
        fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func searchable(_ t: CommsThread) -> String {
        fold(t.lastMessage.map { t.title + "\n" + $0.text } ?? t.title)
    }

    /// Loaded threads (pins first) whose title or preview contains the (folded) term.
    func localMatches(_ term: String) -> [CommsThread] {
        let index: [(thread: CommsThread, text: [UInt8])]
        if let i = searchIndex {
            index = i
        } else {
            index = (pinned + threads).map { ($0, Array(Self.searchable($0).utf8)) }
            searchIndex = index
            lastScan = nil
        }
        let needle = Array(term.utf8)
        guard !needle.isEmpty else { return index.map(\.thread) }
        // Typing on (the new term extends the last one): only the last hits can still match.
        let candidates: [Int] = if let last = lastScan, term.hasPrefix(last.term) { last.hits } else { Array(index.indices) }
        let hits = needle.withUnsafeBytes { n in
            candidates.filter { i in
                index[i].text.withUnsafeBytes { h in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil }
            }
        }
        lastScan = (term, hits)
        return hits.map { index[$0].thread }
    }

    /// A live change to a loaded thread: patch its index entry (no rebuild of every thread).
    private func indexPut(_ t: CommsThread) {
        guard searchIndex != nil else { return }
        lastScan = nil
        let entry = (thread: t, text: Array(Self.searchable(t).utf8))
        if let i = searchIndex!.firstIndex(where: { $0.thread.id == t.id }) { searchIndex![i] = entry } else { searchIndex!.append(entry) }
    }

    private func indexDrop(_ id: String) {
        guard searchIndex != nil else { return }
        lastScan = nil
        searchIndex!.removeAll { $0.thread.id == id }
    }

    private func restartSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        searchCursors = [:]
        searchHasMore = false
        searchWatermark = nil
        guard !searchTerm.isEmpty else {
            serverMatches = []
            searchResults = nil
            isSearchingServer = false
            searchWork = nil
            searchIndex = nil
            lastScan = nil
            return
        }
        // Instant: what is loaded, and the last answer's rows that still match (review I3).
        let term = searchTerm
        serverMatches = serverMatches.filter { Self.searchable($0).contains(term) }
        mergeSearchResults()
        isSearchingServer = true
        let gen = searchGeneration
        let text = String(searchText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let task = Task { [weak self, searchDebounce] in
            try? await Task.sleep(for: searchDebounce)
            guard let self, !Task.isCancelled, gen == self.searchGeneration else { return }
            self.searchRequests.append(text)
            let pages = await self.fetchSearch(text, cursors: nil)
            guard !Task.isCancelled, gen == self.searchGeneration else { return }
            self.isSearchingServer = false
            // Every folder failed (offline): keep what is shown.
            guard !pages.isEmpty else { return }
            self.serverMatches = []
            self.absorb(pages)
        }
        searchTask = task
        searchWork = task
    }

    /// The server's next page of matches (each folder that has more), appended at the end.
    public func loadMoreSearchResults() async {
        guard searchHasMore, !isLoadingMoreSearch, !isSearchingServer, !searchTerm.isEmpty else { return }
        let gen = searchGeneration
        isLoadingMoreSearch = true
        defer { isLoadingMoreSearch = false }
        let text = String(searchText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let pages = await fetchSearch(text, cursors: searchCursors)
        guard gen == searchGeneration, !pages.isEmpty else { return }
        absorb(pages)
    }

    /// One page per folder, concurrently; a folder whose request fails is left out.
    private func fetchSearch(_ text: String, cursors: [CommsFolder: String]?) async -> [(CommsFolder, CommsThreadPage)] {
        let folders = cursors.map { c in searchFolders.filter { c[$0] != nil } } ?? searchFolders
        let limit = searchLimit
        let backend = self.backend
        return await withTaskGroup(of: (CommsFolder, CommsThreadPage)?.self) { group in
            for f in folders {
                let q = CommsThreadQuery(folder: f, search: text, cursor: cursors?[f], limit: limit)
                group.addTask { (try? await backend.threads(q)).map { (f, $0) } }
            }
            var out: [(CommsFolder, CommsThreadPage)] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }

    private func absorb(_ pages: [(CommsFolder, CommsThreadPage)]) {
        var seen = Set(serverMatches.map(\.id))
        for (folder, page) in pages {
            for t in page.threads where seen.insert(t.id).inserted { serverMatches.append(t) }
            if let next = page.next, !next.isEmpty { searchCursors[folder] = next } else { searchCursors[folder] = nil }
        }
        // The oldest row a folder with more pages has given: nothing older is certain yet.
        var mark: Date?
        for (folder, page) in pages where searchCursors[folder] != nil {
            if let last = page.threads.map(\.lastActivityAt).min() { mark = max(mark ?? last, last) }
        }
        searchWatermark = mark
        searchHasMore = !searchCursors.isEmpty
        mergeSearchResults()
    }

    /// Local ∪ server matches, newest activity first (ties by id): a thread keeps its place
    /// relative to the others as more results arrive, so nothing flickers or jumps. The
    /// loaded rows are already newest first, so this is a linear merge with the others.
    private func mergeSearchResults() {
        let local = localMatches(searchTerm)
        func newer(_ a: CommsThread, _ b: CommsThread) -> Bool {
            a.lastActivityAt != b.lastActivityAt ? a.lastActivityAt > b.lastActivityAt : a.id < b.id
        }
        var few = local.filter(\.pinned)
        var rows = few.isEmpty ? local : local.filter { !$0.pinned }
        if !serverMatches.isEmpty {
            // Loaded copies are the freshest (live events update them).
            let loaded = Set(local.lazy.map(\.id))
            let mark = searchWatermark
            few += serverMatches.filter { t in !loaded.contains(t.id) && (mark.map { t.lastActivityAt >= $0 } ?? true) }
        }
        if !rows.isSorted(by: newer) { rows.sort(by: newer) }
        var merged: [CommsThread]
        if few.isEmpty {
            merged = rows
        } else {
            few.sort(by: newer)
            merged = []
            merged.reserveCapacity(rows.count + few.count)
            var i = 0, j = 0
            while i < rows.count || j < few.count {
                if j == few.count || (i < rows.count && newer(rows[i], few[j])) { merged.append(rows[i]); i += 1 } else { merged.append(few[j]); j += 1 }
            }
        }
        // Publish only a real change (ids, or a row's content).
        if let current = searchResults, current.count == merged.count,
           zip(current, merged).allSatisfy({ $0.id == $1.id && $0.lastActivityAt == $1.lastActivityAt && $0.unread == $1.unread && $0.title == $1.title && $0.lastMessage == $1.lastMessage }) {
            return
        }
        searchResults = merged
    }

    @ObservationIgnored private let backend: any ChatBackend
    /// Bumped by every `load()`: answers for an older generation (filter changed, reset) are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isLoadingMore = false
    /// Per-thread refresh sequence: only the latest refetch of a thread may apply.
    @ObservationIgnored private var refreshSequence: [String: Int] = [:]
    @ObservationIgnored private var refreshCounter = 0
    /// The reload started by the last filter change (tests await it).
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    /// `thread.updated` refetches, coalesced per thread (see `RefetchCoalescer`).
    @ObservationIgnored private var refetches: RefetchCoalescer!

    /// - Parameter refetchDelay: how long `thread.updated` events are collected before the
    ///   threads they name are refetched (once each).
    public init(backend: any ChatBackend, refetchDelay: Duration = .milliseconds(300), searchDebounce: Duration = .milliseconds(150)) {
        self.backend = backend
        self.searchDebounce = searchDebounce
        refetches = RefetchCoalescer(
            delay: refetchDelay,
            fetch: { [weak self] id in await self?.refresh(threadID: id) },
            // A replay naming many threads at once (after a reconnect): one list reload.
            batch: { [weak self] _ in await self?.load() })
    }

    /// Fetch the first page for the current filter, replacing the list.
    public func load() async {
        generation += 1
        let gen = generation
        isLoading = true
        error = nil
        defer { if gen == generation { isLoading = false } }
        do {
            let page = try await backend.threads(filter.query())
            guard gen == generation else { return }
            pinned = Self.pinOrdered(page.threads.filter(\.pinned))
            threads = page.threads.filter { !$0.pinned }
            nextCursor = page.next
            if let id = openThreadID { markSeen(id) }
            if !searchTerm.isEmpty { mergeSearchResults() }
            scheduleBadgeRefresh()
        } catch {
            guard gen == generation, !(error is CancellationError) else { return }
            self.error = Self.describe(error)
        }
    }

    /// Fetch the next page and append the threads not already shown.
    public func loadMore() async {
        guard let cursor = nextCursor, !isLoading, !isLoadingMore else { return }
        let gen = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await backend.threads(filter.query(cursor: cursor))
            guard gen == generation else { return }
            var seen = Set(pinned.map(\.id)).union(threads.map(\.id))
            for t in page.threads where seen.insert(t.id).inserted {
                if t.pinned { pinned.append(t) } else { threads.append(t) }
            }
            if page.threads.contains(where: \.pinned) { pinned = Self.pinOrdered(pinned) }
            nextCursor = page.next
        } catch {
            guard gen == generation, !(error is CancellationError) else { return }
            self.error = Self.describe(error)
        }
    }

    /// Apply one live event. `thread.updated` refetches that thread and upserts it (moving it to
    /// its activity position; pins keep their place); refetches are coalesced (≈ 300 ms window,
    /// one in flight per thread, a many-thread replay becomes one reload). `reset` — and a
    /// `thread.updated` that names no thread — reloads.
    /// The returned task finishes when the list reflects the event.
    @discardableResult
    public func apply(_ event: CommsEvent) -> Task<Void, Never> {
        switch event.kind {
        case .threadUpdated:
            // `threadId: null` (a burst of triage changes, `reason: "status"`): the whole list.
            // `reason: "folders"` (a folder created / renamed / reordered / deleted anywhere):
            // the folders too.
            guard let id = event.threadID else {
                let folders = event.payload["reason"]?.stringValue == "folders"
                return Task {
                    if folders { await loadFolders() }
                    await load()
                }
            }
            refetches.request(id)
            scheduleBadgeRefresh()
            return Task { [refetches] in await refetches?.idle() }
        case .reset:
            return Task { await load() }
        case .messageCreated:
            // A message from someone else arriving in the open conversation is read at once.
            if let id = event.threadID, id == openThreadID, appActive, !keptUnread.contains(id),
               event.payload["message"]?["sender"]?["isSelf"]?.boolValue != true {
                reportRead(id, viewing: true)
            }
            return Task {}
        default:
            return Task {}
        }
    }

    private func refresh(threadID id: String) async {
        let gen = generation
        refreshCounter += 1
        let seq = refreshCounter
        refreshSequence[id] = seq
        defer { if refreshSequence[id] == seq { refreshSequence[id] = nil } }
        // A newer refetch of the same thread (started after this one) wins, whichever answers first.
        func current() -> Bool { gen == generation && refreshSequence[id] == seq }
        do {
            let detail = try await backend.thread(id: id)
            guard current() else { return }
            upsert(detail.thread)
        } catch CommsError.threadUnavailable {
            guard current() else { return }
            remove(id, gone: true)
        } catch {
            // Transient failure: keep the stale row; the next event or reload corrects it.
        }
    }

    private func upsert(_ t: CommsThread) {
        var t = t
        if t.id == openThreadID, !keptUnread.contains(t.id) { t.unread.count = 0 }
        // While searching the index is patched, not rebuilt (review m4).
        patchingIndex = true
        defer {
            patchingIndex = false
            if !searchTerm.isEmpty { refreshSearchRow(t) }
        }
        let wasShown = pinned.contains { $0.id == t.id } || threads.contains { $0.id == t.id }
        // An Unread filter keeps a row that was just read (as Messages does) but never adds a read one.
        guard filter.admits(t), !filter.unread || t.unread.count > 0 || wasShown else { return remove(t.id) }
        indexPut(t)

        if t.pinned {
            threads.removeAll { $0.id == t.id }
            if let i = pinned.firstIndex(where: { $0.id == t.id }) { pinned[i] = t } else { pinned.append(t) }
            let ordered = Self.pinOrdered(pinned)
            if ordered.map(\.id) != pinned.map(\.id) { pinned = ordered }
            return
        }
        let oldIndex = threads.firstIndex { $0.id == t.id }
        pinned.removeAll { $0.id == t.id }
        threads.removeAll { $0.id == t.id }
        // Rows are newest-activity first: a thread with new activity moves to the top, one that
        // only changed state (read, renamed) stays where it was.
        let index = threads.firstIndex { $0.lastActivityAt <= t.lastActivityAt } ?? threads.endIndex
        // Older than everything loaded while more pages exist: a new thread belongs to a later
        // page, but a row already on screen (e.g. the last loaded one, just read) keeps its place.
        if index == threads.endIndex, hasMore {
            if let oldIndex { threads.insert(t, at: min(oldIndex, threads.endIndex)) }
            return
        }
        threads.insert(t, at: index)
    }

    /// Leave the list (no longer in this folder / filter). `gone`: the thread no longer exists,
    /// so it leaves the search results too (search covers every folder, so a thread that merely
    /// moved stays found there).
    private func remove(_ id: String, gone: Bool = false) {
        let wasPatching = patchingIndex
        patchingIndex = true
        defer { patchingIndex = wasPatching }
        pinned.removeAll { $0.id == id }
        threads.removeAll { $0.id == id }
        indexDrop(id)
        if !searchTerm.isEmpty, gone {
            serverMatches.removeAll { $0.id == id }
            mergeSearchResults()
        }
    }

    /// A live change to a thread: refresh it in the search results, or add it when it now
    /// matches and is not shown (review m5). Folders and filters do not apply to search.
    private func refreshSearchRow(_ t: CommsThread) {
        if let i = serverMatches.firstIndex(where: { $0.id == t.id }) {
            serverMatches[i] = t
        } else if Self.searchable(t).contains(searchTerm), searchResults?.contains(where: { $0.id == t.id }) != true {
            serverMatches.append(t)
        }
        mergeSearchResults()
    }

    // MARK: Row actions (sprint Task 9)

    /// Which row actions the server offers (the swipe and menu show only these).
    public var rowActions: RowActionSupport { backend.rowActions }

    /// What the owner can undo right now (Mail's "Undo" after Archive / a status change).
    public struct UndoOffer: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case archive(threadID: String)
            case status(threadID: String, undoID: String)
        }
        public let id: UUID
        public let title: String
        public let kind: Kind
        init(title: String, kind: Kind) {
            id = UUID()
            self.title = title
            self.kind = kind
        }
    }
    public private(set) var undoOffer: UndoOffer?
    /// A failed row / folder action, said once (nil = nothing to tell).
    public private(set) var actionNotice: String?
    public func dismissActionNotice() { actionNotice = nil }
    public func dismissUndo() { undoOffer = nil }

    /// Every list a thread may show in (rows, pins, search) gets the server's answer.
    private func absorb(_ t: CommsThread) {
        upsert(t)
        if !searchTerm.isEmpty, let i = serverMatches.firstIndex(where: { $0.id == t.id }) {
            serverMatches[i] = t
            mergeSearchResults()
        }
    }

    /// Mute (Hide Alerts) or unmute: the bell-slash shows at once; a failure puts it back.
    public func toggleMute(_ id: String) async {
        guard var t = shown(id) else { return }
        let muted = !t.muted
        let saved = t
        t.muted = muted
        absorb(t)
        do {
            absorb(try await backend.setMuted(threadID: id, muted))
        } catch {
            absorb(saved)
            actionNotice = muted ? "Couldn't mute “\(t.title)”." : "Couldn't unmute “\(t.title)”."
        }
    }

    /// Archive (the row leaves every list but Archived) or unarchive. Archive offers Undo.
    public func setArchived(_ id: String, _ archived: Bool) async {
        guard var t = shown(id) else { return }
        let saved = t
        let wasFolder = t.folder
        t.folder = archived ? .archived : (wasFolder == .archived ? .inbox : wasFolder)
        upsert(t)
        do {
            let fresh = try await backend.setArchived(threadID: id, archived)
            absorb(fresh)
            undoOffer = archived ? UndoOffer(title: "Archived “\(t.title)”", kind: .archive(threadID: id)) : nil
        } catch {
            // Only this row goes back: live updates to other rows meanwhile stay (final review M13).
            upsert(saved)
            actionNotice = archived ? "Couldn't archive “\(t.title)”." : "Couldn't unarchive “\(t.title)”."
        }
    }

    /// Set the triage status (the server writes the vault note's tags); offers Undo.
    public func setStatus(_ id: String, _ status: CommsThreadStatus) async {
        guard var t = shown(id), t.status != status else { return }
        let saved = t
        t.status = status
        upsert(t)
        do {
            let change = try await backend.setStatus(threadID: id, status)
            absorb(change.thread)
            if let undo = change.undo {
                undoOffer = UndoOffer(title: "Marked “\(t.title)” \(status.label)", kind: .status(threadID: id, undoID: undo.id))
            }
        } catch {
            upsert(saved)
            actionNotice = switch error as? CommsError {
            case .noStatusNote?: "This conversation has no status to change."
            default: "Couldn't change the status of “\(t.title)”."
            }
        }
    }

    /// Run the current undo offer.
    public func undo() async {
        guard let offer = undoOffer else { return }
        undoOffer = nil
        do {
            switch offer.kind {
            case .archive(let id):
                absorb(try await backend.setArchived(threadID: id, false))
            case .status(let id, let undoID):
                absorb(try await backend.undoStatus(threadID: id, undoID: undoID))
            }
        } catch CommsError.statusChanged {
            actionNotice = "The status changed since, so it was left as it is."
        } catch {
            actionNotice = "Couldn't undo."
        }
    }

    // MARK: Owner folders + pages (sprint Task 9)

    /// The New Folder prompt is up (with the conversations to add once it exists), and Edit Folders.
    public var newFolderRequest: [String]?
    public var showsEditFolders = false
    /// The row whose Status sheet is up (the trailing swipe's Status button, Mail's "More" sheet).
    public var statusRequest: String?

    /// Multi-select (iPhone: Edit › Select Conversations; Mac: ⌘-click rows): the conversations
    /// a folder action applies to. Cleared when the page changes.
    public var isSelecting = false { didSet { if !isSelecting { selectedIDs = [] } } }
    public var selectedIDs: Set<String> = []
    public func toggleSelected(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }
    /// What a row's folder action applies to: the selection when the row is part of it.
    public func actionTargets(for id: String) -> [String] {
        selectedIDs.count > 1 && selectedIDs.contains(id) ? selectedIDs.sorted() : [id]
    }

    /// The server offers owner folders (else no folder strip, switcher or "Add to Folder").
    public var canUseFolders: Bool { backend.foldersSupported }
    /// The owner's folders, in their order (shared by every device).
    public private(set) var folders: [CommsChatFolder] = []

    /// The pages the list swipes through: the home page ("Comms", nil), then each folder.
    public var pages: [String?] { [nil] + folders.map(\.id) }
    public var pageIndex: Int { pages.firstIndex(of: filter.chatFolder) ?? 0 }
    public var currentFolder: CommsChatFolder? { filter.chatFolder.flatMap { id in folders.first { $0.id == id } } }

    /// The Needs You page (Omni's proposals waiting for the owner) is on screen instead of a
    /// folder of conversations (polish r2: chosen from the list's folder menu, like a folder).
    public private(set) var showsNeedsYou = false

    /// Show Needs You (the folder underneath is kept, and comes back with any page choice).
    public func showNeedsYou() {
        isSelecting = false
        showsNeedsYou = true
    }

    /// Show page `index` (0 = home); out of range does nothing.
    public func showPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        showsNeedsYou = false
        guard filter.chatFolder != pages[index] else { return }
        selectedIDs = []
        filter.chatFolder = pages[index]
    }

    /// The next (+1) or previous (-1) page; false at either end.
    @discardableResult
    public func page(by delta: Int) -> Bool {
        if showsNeedsYou {
            // Leaving Needs You lands on the folder that was under it.
            showsNeedsYou = false
            return true
        }
        let next = pageIndex + delta
        guard pages.indices.contains(next) else { return false }
        showPage(next)
        return true
    }

    public func loadFolders() async {
        guard canUseFolders else {
            folders = []
            return
        }
        do {
            folders = try await backend.folders().sorted { $0.position < $1.position }
            // The page's folder was deleted (here or on another device): back to the home page.
            if let id = filter.chatFolder, !folders.contains(where: { $0.id == id }) { filter.chatFolder = nil }
        } catch {
            // Keep the folders shown; the next event or load corrects them.
        }
        // Each folder's notification rule (its menu's "Notifications ▸"). A rule change on any
        // device is announced like a folder change, so this stays in step.
        if !folders.isEmpty, let r = try? await backend.notificationSettings() {
            folderNotify = r.settings.folders
        }
    }

    /// Owner folder id → its notification rule (missing = Default).
    public private(set) var folderNotify: [String: CommsFolderNotify] = [:]
    public func notifyRule(forFolder id: String) -> CommsFolderNotify { folderNotify[id] ?? .default }

    /// A folder's "Notifications ▸ Default / All Messages / None" (saved on the server, synced).
    public func setNotifyRule(_ rule: CommsFolderNotify, forFolder id: String) async {
        let saved = folderNotify
        folderNotify[id] = rule == .default ? nil : rule
        var patch = CommsNotifySettingsPatch()
        patch.folders = [id: rule]
        do {
            let r = try await backend.updateNotificationSettings(patch)
            folderNotify = r.settings.folders
        } catch {
            folderNotify = saved
            actionNotice = "Couldn't change the folder's notifications."
        }
    }

    @discardableResult
    public func createFolder(name: String) async -> CommsChatFolder? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        do {
            let f = try await backend.createFolder(name: name)
            if !folders.contains(where: { $0.id == f.id }) { folders.append(f) }
            return f
        } catch {
            actionNotice = Self.folderFailure(error, name: name)
            return nil
        }
    }

    public func renameFolder(_ id: String, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = folders.firstIndex(where: { $0.id == id }), folders[i].name != name else { return }
        let saved = folders
        folders[i].name = name
        do {
            let f = try await backend.renameFolder(id: id, name: name)
            if let j = folders.firstIndex(where: { $0.id == id }) { folders[j] = f }
        } catch {
            folders = saved
            actionNotice = Self.folderFailure(error, name: name)
        }
    }

    /// Delete a folder; its conversations stay in Comms.
    public func deleteFolder(_ id: String) async {
        let saved = folders
        folders.removeAll { $0.id == id }
        if filter.chatFolder == id { filter.chatFolder = nil }
        do {
            try await backend.deleteFolder(id: id)
        } catch {
            folders = saved
            actionNotice = "Couldn't delete the folder."
        }
    }

    /// Move a folder to `index` (Edit Folders: drag to reorder).
    public func moveFolder(_ id: String, to index: Int) async {
        guard let from = folders.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(index, 0), folders.count - 1)
        guard from != to else { return }
        let saved = folders
        var list = folders
        list.insert(list.remove(at: from), at: to)
        for i in list.indices { list[i].position = i }
        folders = list
        do {
            folders = try await backend.reorderFolders(list.map(\.id)).sorted { $0.position < $1.position }
        } catch CommsError.foldersChanged {
            await loadFolders()
        } catch {
            folders = saved
            actionNotice = "Couldn't move the folder."
        }
    }

    public func isInFolder(_ threadID: String, _ folderID: String) -> Bool {
        shown(threadID)?.folderIds?.contains(folderID) == true
    }

    /// Add conversations to a folder (context menu, swipe, multi-select). At once on screen.
    public func add(_ threadIDs: [String], toFolder folderID: String) async {
        guard !threadIDs.isEmpty else { return }
        patchMembership(threadIDs, folderID, member: true)
        do {
            let f = try await backend.addToFolder(id: folderID, threadIDs: threadIDs)
            if let i = folders.firstIndex(where: { $0.id == f.id }) { folders[i] = f }
        } catch {
            patchMembership(threadIDs, folderID, member: false)
            actionNotice = "Couldn't add to the folder."
        }
    }

    public func remove(_ threadIDs: [String], fromFolder folderID: String) async {
        guard !threadIDs.isEmpty else { return }
        patchMembership(threadIDs, folderID, member: false)
        do {
            let f = try await backend.removeFromFolder(id: folderID, threadIDs: threadIDs)
            if let i = folders.firstIndex(where: { $0.id == f.id }) { folders[i] = f }
        } catch {
            patchMembership(threadIDs, folderID, member: true)
            actionNotice = "Couldn't remove from the folder."
        }
    }

    public func toggleMembership(_ threadID: String, _ folderID: String) async {
        if isInFolder(threadID, folderID) { await remove([threadID], fromFolder: folderID) } else { await add([threadID], toFolder: folderID) }
    }

    private func patchMembership(_ ids: [String], _ folderID: String, member: Bool) {
        for id in ids {
            guard var t = shown(id) else { continue }
            var set = Set(t.folderIds ?? [])
            if member { set.insert(folderID) } else { set.remove(folderID) }
            t.folderIds = set.isEmpty ? nil : set.sorted()
            // On that folder's page a removed row leaves, an added one (from search) arrives.
            upsert(t)
        }
    }

    static func folderFailure(_ error: any Error, name: String) -> String {
        switch error as? CommsError {
        case .folderExists?: "There is already a folder called “\(name)”."
        case .folderLimit?: "You can have up to 20 folders."
        case .foldersDisabled?: "Folders aren't available on this server."
        default: "Couldn't save the folder “\(name)”."
        }
    }

    // MARK: Pins (sprint Task 8)

    /// Messages' limit: nine pinned conversations.
    public static let maxPins = 9
    /// What the owner must be told about the last pin action (the limit, a failure); nil = nothing.
    public private(set) var pinNotice: String?
    public func dismissPinNotice() { pinNotice = nil }
    /// The server offers pins (else the Pin actions are hidden).
    public var canPin: Bool { backend.pinsSupported }

    /// Pins in the owner's grid order; pins without an order (pinned elsewhere) last, newest first.
    static func pinOrdered(_ list: [CommsThread]) -> [CommsThread] {
        list.enumerated().sorted { a, b in
            switch (a.element.pinOrder, b.element.pinOrder) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    public func isPinned(_ id: String) -> Bool { pinned.contains { $0.id == id } }

    private func shown(_ id: String) -> CommsThread? {
        pinned.first { $0.id == id } ?? threads.first { $0.id == id } ?? searchResults?.first { $0.id == id }
    }

    public func togglePin(_ id: String) async {
        if isPinned(id) { await unpin(id) } else { await pin(id) }
    }

    /// Pin at the end of the grid, at once; the server's answer confirms it (all devices follow
    /// through `thread.updated`). A tenth pin is refused here, as Messages does.
    public func pin(_ id: String) async {
        guard !isPinned(id), var t = shown(id) else { return }
        guard pinned.count < Self.maxPins else {
            pinNotice = Self.pinLimitText
            return
        }
        let saved = (pinned, threads)
        // The server makes the order dense in the grid's current order (pins made elsewhere
        // without one included) and puts the new pin last: do the same here.
        for i in pinned.indices { pinned[i].pinOrder = i }
        t.pinned = true
        t.pinOrder = pinned.count
        threads.removeAll { $0.id == id }
        pinned.append(t)
        do {
            upsert(try await backend.pin(threadID: id))
        } catch {
            (pinned, threads) = saved
            pinNotice = Self.pinFailure(error, title: t.title, pinning: true)
            if case CommsError.pinLimit? = error as? CommsError { await load() }
        }
    }

    public func unpin(_ id: String) async {
        guard var t = pinned.first(where: { $0.id == id }) else { return }
        let saved = (pinned, threads)
        t.pinned = false
        t.pinOrder = nil
        upsert(t)
        do {
            upsert(try await backend.unpin(threadID: id))
        } catch {
            (pinned, threads) = saved
            pinNotice = Self.pinFailure(error, title: t.title, pinning: false)
        }
    }

    /// Move a pin to `index` in the grid (drag to reorder); saved on the server for every device.
    public func movePin(_ id: String, to index: Int) async {
        guard let from = pinned.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(index, 0), pinned.count - 1)
        guard from != to else { return }
        let saved = pinned
        var list = pinned
        let t = list.remove(at: from)
        list.insert(t, at: to)
        for i in list.indices { list[i].pinOrder = i }
        pinned = list
        do {
            let fresh = try await backend.reorderPins(list.map(\.id))
            let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            pinned = Self.pinOrdered(pinned.map { byID[$0.id] ?? $0 })
        } catch CommsError.pinsChanged {
            // Another device pinned or unpinned meanwhile: show what the server has.
            await load()
        } catch {
            pinned = saved
            pinNotice = "Couldn't move the pinned conversation."
        }
    }

    static let pinLimitText = "You can pin up to 9 conversations. Unpin one to pin another."

    static func pinFailure(_ error: any Error, title: String, pinning: Bool) -> String {
        switch error as? CommsError {
        case .pinLimit?: return pinLimitText
        case .pinsDisabled?: return "Pinning isn't available on this server."
        case .threadUnavailable?: return "This conversation is no longer available."
        default: return pinning ? "Couldn't pin “\(title)”." : "Couldn't unpin “\(title)”."
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error as? CommsError {
        case .sourceUnavailable(let network)?: return "\(network.wire.capitalized) is unavailable right now."
        case .clientScope?: return "This device isn't allowed to read conversations."
        case .unsupportedServer?: return "This server is not a supported Comms server."
        default: return "Couldn't load conversations."
        }
    }
}

extension Array {
    func isSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> Bool {
        guard count > 1 else { return true }
        for i in 1..<count where areInIncreasingOrder(self[i], self[i - 1]) { return false }
        return true
    }
}

// MARK: Live events

/// Reconnect delays for the live stream: 1 s, doubling, capped at 30 s.
public struct EventBackoff: Sendable, Equatable {
    public var initial: Duration
    public var maximum: Duration

    public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(30)) {
        self.initial = initial
        self.maximum = maximum
    }

    /// The delay before reconnect number `attempt` (1-based).
    public func delay(attempt: Int) -> Duration {
        let factor = 1 << min(max(attempt, 1) - 1, 30)
        return min(initial * factor, maximum)
    }
}

/// Subscribes to `backend.events` for as long as `run()`'s task lives, handing each event to
/// `handle` (the list store, the open timeline). When the stream ends or fails it reconnects
/// after `EventBackoff` with `Last-Event-ID` = the last event seen; any event resets the backoff,
/// and a `reset` drops the cursor (the server could not replay from it).
@MainActor
public final class LiveEventPump {
    public private(set) var lastEventID: String?
    private let backend: any ChatBackend
    private let backoff: EventBackoff
    private let sleep: @Sendable (Duration) async throws -> Void
    private let handle: @MainActor (CommsEvent) -> Void

    public init(
        backend: any ChatBackend,
        backoff: EventBackoff = EventBackoff(),
        lastEventID: String? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        handle: @escaping @MainActor (CommsEvent) -> Void
    ) {
        self.backend = backend
        self.backoff = backoff
        self.lastEventID = lastEventID
        self.sleep = sleep
        self.handle = handle
    }

    /// Runs until the calling task is cancelled.
    public func run() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                for try await event in backend.events(lastEventID: lastEventID) {
                    attempt = 0
                    if event.kind == .reset { lastEventID = nil } else if let id = event.id { lastEventID = id }
                    handle(event)
                }
            } catch {
                // Dropped or refused: fall through to the backoff. (A signed-out session tears
                // down the view that owns this task, which cancels it.)
            }
            if Task.isCancelled { return }
            attempt += 1
            do { try await sleep(backoff.delay(attempt: attempt)) } catch { return }
        }
    }
}

/// When the open thread counts as "being read" on the Mac (review I3). SwiftUI's `scenePhase`
/// stays `.active` while the window is merely visible behind other apps, so the Mac combines:
/// the app is frontmost, the window is key, and there was user input within `idleLimit`.
public enum ReadingPresence {
    /// Two minutes without a key press or pointer movement = nobody is reading.
    public static let idleLimit: TimeInterval = 120

    public static func isReading(appActive: Bool, windowKey: Bool, idleSeconds: TimeInterval, idleLimit: TimeInterval = idleLimit) -> Bool {
        appActive && windowKey && idleSeconds < idleLimit
    }
}
