import CommsClient
import CommsCore
import SwiftUI

/// The Mac window: the inset floating Liquid Glass sidebar (the system's `NavigationSplitView`
/// sidebar on macOS 26) holding the conversation list, the Filter button in the sidebar's
/// toolbar, and the detail column.
public struct ThreadListSplitView<Detail: View>: View {
    @Bindable var store: ThreadListStore
    @Binding var selection: String?
    let detail: (String?) -> Detail
    /// The compose button (New Message, ⌘N); nil hides it.
    let onCompose: (() -> Void)?
    /// Full message search and contact tidy-up (Task 4); nil = the list's own search only.
    let messageSearch: MessageSearchStore?
    let tidy: TidyStore?

    public init(store: ThreadListStore, selection: Binding<String?>, messageSearch: MessageSearchStore? = nil, tidy: TidyStore? = nil,
                onCompose: (() -> Void)? = nil, @ViewBuilder detail: @escaping (String?) -> Detail) {
        self.store = store
        _selection = selection
        self.messageSearch = messageSearch
        self.tidy = tidy
        self.onCompose = onCompose
        self.detail = detail
    }

    @State private var query = ""
    @State private var searchFocused = false
    @State private var tokens: [SearchToken] = []
    @State private var showsTidy = false
    @Environment(\.omniStore) private var omni
    /// Pending Omni proposals for the folder menu; nil = no Omni on this server.
    private var needsYouCount: Int? { omni.flatMap { $0.isAvailable ? $0.needsYou.count : nil } }

    public var body: some View {
        NavigationSplitView {
            Sidebar(store: store, selection: $selection, searchText: query, messageSearch: messageSearch, tokens: $tokens, tidy: tidy,
                    onOpenTidy: { showsTidy = true })
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
                // Messages: a full-width search field at the top of the sidebar (⌘F), with tokens.
                .searchable(text: $query, tokens: $tokens, isPresented: $searchFocused, placement: .sidebar, prompt: "Search") { token in
                    Label(token.label, systemImage: token.systemImage)
                }
                // A chosen token replaces the words that suggested it (the store clears its text).
                .onChange(of: messageSearch?.text ?? "") { _, t in if query != t { query = t } }
                .sheet(isPresented: $showsTidy) {
                    if let tidy {
                        NavigationStack {
                            PeopleToTidyView(store: tidy) { id in showsTidy = false; selection = id }
                                .navigationTitle("People to Tidy")
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsTidy = false } } }
                        }
                        .frame(minWidth: 420, minHeight: 480)
                    }
                }
                .background {
                    Button("Search") { searchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .hidden()
                        .accessibilityHidden(true)
                }
                .toolbar {
                    // The sidebar's top glass group: Folders · Filter · Compose (round 3).
                    if store.canUseFolders || needsYouCount != nil || (tidy?.total ?? 0) > 0 {
                        ToolbarItem(placement: .automatic) {
                            FolderMenuButton(store: store, needsYouCount: needsYouCount, tidyCount: tidy?.total ?? 0, onTidy: { showsTidy = true })
                        }
                    }
                    ToolbarItem(placement: .automatic) { FilterMenu(filter: $store.filter) }
                    if let onCompose {
                        ToolbarItem(placement: .automatic) {
                            Button(action: onCompose) { Label("New Message", systemImage: "square.and.pencil") }
                                .keyboardShortcut("n", modifiers: .command)
                                .help("New Message")
                                .accessibilityIdentifier("list-compose")
                        }
                    }
                }
                // Only the Filter and compose circles in the sidebar's toolbar, as in Messages.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(selection)
        }
        .toolbar(removing: .title)
        .task { await store.load() }
    }
}

/// The conversation list: pinned grid, then rows; arrow keys move the selection, the last row
/// appearing loads the next page.
public struct Sidebar: View {
    @Bindable var store: ThreadListStore
    @Binding var selection: String?
    /// The Search field's text: handed to the store, which answers from the loaded list at
    /// once and from the server after a short pause (empty = the list).
    var searchText: String
    /// Full message search (nil = the list's own search only) and the field's tokens.
    var messageSearch: MessageSearchStore?
    @Binding var tokens: [SearchToken]
    var tidy: TidyStore?
    var onOpenTidy: () -> Void

    public init(store: ThreadListStore, selection: Binding<String?>, searchText: String = "", messageSearch: MessageSearchStore? = nil,
                tokens: Binding<[SearchToken]> = .constant([]), tidy: TidyStore? = nil, onOpenTidy: @escaping () -> Void = {}) {
        self.store = store
        _selection = selection
        self.searchText = searchText
        self.messageSearch = messageSearch
        _tokens = tokens
        self.tidy = tidy
        self.onOpenTidy = onOpenTidy
    }

    /// Full search answers while there is text or a token and the server has it.
    private var fullSearch: MessageSearchStore? {
        guard let messageSearch, messageSearch.isAvailable, messageSearch.isActive else { return nil }
        return messageSearch
    }

    /// The list's row swipes: one open row at a time, closed by a scroll or a touch elsewhere
    /// (and on the Mac, the trackpad's scroll-wheel monitor).
    @State private var swipes = SwipeCoordinator()
    @Environment(\.omniStore) private var omni

    /// Pending Omni proposals for the folder menu; nil = no Omni on this server.
    var needsYouCount: Int? { omni.flatMap { $0.isAvailable ? $0.needsYou.count : nil } }

    public var body: some View {
        TimelineView(.everyMinute) { context in
            ScrollView {
                FilterSummaryBar(filter: $store.filter)
                if let search = fullSearch {
                    SearchResultsView(search: search, conversations: store.searchResults ?? [], now: context.date, open: { selection = $0 })
                } else if let results = store.searchResults {
                    // Search: one list of matches (no pins grid), as Messages shows them.
                    SidebarContent(pinned: [], threads: results, selection: selection, now: context.date,
                                   onSelect: { selection = $0 }, onReachEnd: { Task { await store.loadMoreSearchResults() } },
                                   onSetRead: setRead, pins: pinActions, actions: conversationActions)
                    searchFooter(results)
                } else if store.showsNeedsYou {
                    // Omni's proposals waiting for the owner: a page of its own (the folder menu).
                    NeedsYouPage(selection: $selection)
                } else {
                    SidebarContent(
                        pinned: store.pinned, threads: store.threads, selection: selection, now: context.date,
                        onSelect: { selection = $0 },
                        onReachEnd: { Task { await store.loadMore() } },
                        onSetRead: setRead,
                        pins: pinActions,
                        actions: conversationActions,
                        selecting: store.isSelecting,
                        selected: store.selectedIDs,
                        onToggleSelected: { store.toggleSelected($0) }
                    )
                    footer
                }
            }
            // Messages: an open swipe closes as soon as the list scrolls.
            .onScrollPhaseChange { _, phase in
                if phase != .idle { swipes.closeAll() }
            }
        }
        .onChange(of: searchText, initial: true) { _, text in
            store.searchText = text
            messageSearch?.text = text
        }
        .onChange(of: tokens) { _, t in if messageSearch?.tokens != t { messageSearch?.tokens = t } }
        .onChange(of: messageSearch?.tokens ?? []) { _, t in if tokens != t { tokens = t } }
        .task { await tidy?.load() }
        .task { await store.loadFolders() }
        // Needs You's count for the folder menu (and the page itself).
        .task { await omni?.loadNeedsYou() }
        #if os(macOS)
        .background { SwipeHostWindow(coordinator: swipes).frame(width: 0, height: 0).accessibilityHidden(true) }
        .onAppear { swipes.start() }
        .onDisappear { swipes.stop() }
        #endif
        .environment(swipes)
        .overlay(alignment: .bottom) { UndoBanner(store: store).animation(.snappy, value: store.undoOffer) }
        .modifier(NewFolderPrompt(threadIDs: $store.newFolderRequest, store: store))
        .background { Color.clear.modifier(StatusSheet(store: store, actions: conversationActions)) }
        .sheet(isPresented: $store.showsEditFolders) {
            NavigationStack {
                EditFoldersView(store: store)
                    .navigationTitle("Edit Folders")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    .environment(\.editMode, .constant(.active))
                    #endif
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { store.showsEditFolders = false }.accessibilityIdentifier("edit-folders-done") } }
            }
            #if os(macOS)
            .frame(minWidth: 360, minHeight: 360)
            #endif
        }
        .alert("Comms", isPresented: Binding(get: { store.actionNotice != nil }, set: { if !$0 { store.dismissActionNotice() } })) {
            Button("OK", role: .cancel) { store.dismissActionNotice() }
        } message: {
            Text(store.actionNotice ?? "")
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
        .background { FolderShortcuts(filter: $store.filter) }
        .background { FolderPageShortcuts(store: store) }
        .alert("Can't Pin", isPresented: Binding(get: { store.pinNotice != nil }, set: { if !$0 { store.dismissPinNotice() } })) {
            Button("OK", role: .cancel) { store.dismissPinNotice() }
        } message: {
            Text(store.pinNotice ?? "")
        }
    }

    /// Mute / Archive / Status / folders, as far as the server offers them (sprint Task 9).
    private var conversationActions: ConversationActions? {
        let support = store.rowActions
        let folders = store.canUseFolders
        guard !support.isEmpty || folders else { return nil }
        let store = store
        return ConversationActions(
            support: support,
            toggleMute: { id in Task { await store.toggleMute(id) } },
            setArchived: { id, on in Task { await store.setArchived(id, on) } },
            setStatus: { id, s in Task { await store.setStatus(id, s) } },
            foldersEnabled: folders,
            folders: store.folders,
            toggleFolder: { t, f in Task { await store.toggleMembership(t, f) } },
            addToFolder: { ids, f in Task { await store.add(ids, toFolder: f); store.isSelecting = false } },
            newFolder: { ids in store.newFolderRequest = ids },
            currentFolder: store.currentFolder,
            removeFromFolder: { t, f in Task { await store.remove([t], fromFolder: f) } },
            targets: { store.actionTargets(for: $0) },
            askStatus: { store.statusRequest = $0 })
    }

    /// Pin / Unpin / reorder, when the server offers pins (sprint Task 8).
    private var pinActions: PinActions? {
        guard store.canPin else { return nil }
        let store = store
        return PinActions(
            isPinned: { store.isPinned($0) },
            toggle: { id in Task { await store.togglePin(id) } },
            move: { id, index in Task { await store.movePin(id, to: index) } })
    }

    @ViewBuilder private func searchFooter(_ results: [CommsThread]) -> some View {
        if store.isSearchingServer || store.searchHasMore {
            ProgressView().controlSize(.small).padding(results.isEmpty ? 24 : 12)
                .accessibilityLabel("Searching")
        } else if results.isEmpty {
            Text("No Results").font(.callout).foregroundStyle(.secondary).padding(24)
                .accessibilityIdentifier("search-no-results")
        }
    }

    @ViewBuilder private var footer: some View {
        if let error = store.error {
            VStack(spacing: 8) {
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await store.load() } }
            }
            .padding(24)
        } else if store.isLoading, store.threads.isEmpty, store.pinned.isEmpty {
            ProgressView().controlSize(.small).padding(24)
        } else if store.threads.isEmpty, store.pinned.isEmpty {
            Text("No Conversations").font(.callout).foregroundStyle(.secondary).padding(24)
        } else if store.hasMore {
            ProgressView().controlSize(.small).padding(12)
        }
    }

    /// Mark as Read / Mark as Unread (row context menu, iOS leading swipe).
    private func setRead(_ id: String, _ read: Bool) {
        if read { store.markRead(id) } else { store.markUnread(id) }
    }

    private func move(by delta: Int) -> KeyPress.Result {
        let ids = store.searchResults?.map(\.id) ?? (store.pinned.map(\.id) + store.threads.map(\.id))
        guard !ids.isEmpty else { return .ignored }
        let current = selection.flatMap { ids.firstIndex(of: $0) }
        let next = current.map { min(max($0 + delta, 0), ids.count - 1) } ?? (delta > 0 ? 0 : ids.count - 1)
        selection = ids[next]
        return .handled
    }
}

/// The list body without scrolling (rendered directly by snapshots and the design comparison).
struct SidebarContent: View {
    let pinned: [CommsThread]
    let threads: [CommsThread]
    let selection: String?
    let now: Date
    let onSelect: (String) -> Void
    let onReachEnd: () -> Void
    /// Mark a thread read (true) or unread (false); nil = no read actions (snapshots).
    var onSetRead: ((String, Bool) -> Void)? = nil
    var pins: PinActions? = nil
    var actions: ConversationActions? = nil
    /// Multi-select (Task 9): rows show a selection circle; a tap toggles instead of opening.
    var selecting = false
    var selected: Set<String> = []
    var onToggleSelected: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if !pinned.isEmpty {
                PinnedGrid(threads: pinned, selection: selection, onSelect: onSelect, pins: pins)
                    .padding(.top, ListMetrics.pinnedGridTop)
                    .padding(.bottom, ListMetrics.pinnedGridBottom)
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(threads.enumerated()), id: \.element.id) { i, t in
                    HStack(spacing: 0) {
                        if selecting {
                            Image(systemName: selected.contains(t.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected.contains(t.id) ? AnyShapeStyle(ListMetrics.accent) : AnyShapeStyle(.tertiary))
                                .padding(.leading, 12)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                                .accessibilityHidden(true)
                        }
                        // Select mode shows the checkmark only (Messages); a Mac ⌘-click selection is highlighted.
                        ThreadRow(thread: t, isSelected: t.id == selection || (!selecting && selected.contains(t.id)), now: now)
                    }
                        .overlay(alignment: .bottom) {
                            if showsSeparator(after: i) { separator }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { tap(t.id) }
                        .accessibilityAction { tap(t.id) }
                        .accessibilityAddTraits(selecting && selected.contains(t.id) ? .isSelected : [])
                        // The row's id before RowActions: the swipe's buttons keep their own ids.
                        .accessibilityIdentifier("thread-row-\(t.id)")
                        .modifier(RowActions(thread: t, onSetRead: onSetRead, pins: pins, actions: selecting ? nil : actions))
                        .onAppear { if i == threads.count - 1 { onReachEnd() } }
                }
            }
        }
        .padding(.horizontal, ListMetrics.sidebarInset)
    }

    @Environment(\.colorScheme) private var colorScheme

    private func tap(_ id: String) {
        if selecting { return onToggleSelected(id) }
        #if os(macOS)
        // Mac: ⌘-click adds a row to the multi-selection (for Add to Folder), as in Mail.
        if NSEvent.modifierFlags.contains(.command) {
            if let current = selection, selected.isEmpty, current != id { onToggleSelected(current) }
            return onToggleSelected(id)
        }
        if !selected.isEmpty { selected.forEach(onToggleSelected) }
        #endif
        onSelect(id)
    }

    @ViewBuilder private var separator: some View {
        #if os(iOS)
        // Messages on iPhone: a 1 pt line from the text column (x 83) to 16 pt from the edge,
        // under every row including the last.
        Rectangle()
            .fill(ListMetrics.separator(colorScheme))
            .frame(height: 1)
            .padding(.leading, ListMetrics.textColumn).padding(.trailing, ListMetrics.rowTrailing)
        #else
        Divider().padding(.leading, ListMetrics.textColumn).padding(.trailing, ListMetrics.rowTrailing)
        #endif
    }

    /// Hairlines sit between rows, never touching the selected rect (iOS: under every row).
    private func showsSeparator(after i: Int) -> Bool {
        #if os(iOS)
        return true
        #else
        guard i < threads.count - 1 else { return false }
        return threads[i].id != selection && threads[i + 1].id != selection
        #endif
    }
}
