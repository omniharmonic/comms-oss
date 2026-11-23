#if os(iOS)
import CommsClient
import CommsCore
import SwiftUI
import UIKit
import UserNotifications

/// The signed-in app on iPhone and iPad.
///
/// - iPhone (compact width): Messages' navigation stack, the conversation list pushing the
///   transcript (system push / back, swipe-back). The back button carries the unread count
///   of the other conversations in a capsule, as in Messages.
/// - iPad (regular width): a split view, the list in the sidebar and the transcript in the
///   detail column; Details opens as the inspector column.
///
/// The live event stream (`LiveEventPump`) feeds the list and the open transcript; it is
/// restarted, and the list and open transcript refetched, whenever the app returns to the
/// foreground. The open conversation reads as read.
public struct PhoneMainView: View {
    private let backend: any ChatBackend
    private let detailsAccessory: ((String) -> AnyView)?
    private let onSignOut: (() -> Void)?
    @State private var model: MainWindowModel
    @State private var selection: String?
    @State private var path: [String] = []
    @State private var query = ""
    /// The New Message sheet's store while it is up.
    @State private var compose: ComposeStore?
    /// Settings › Notifications while it is up.
    @State private var notificationSettings: NotificationSettingsStore?
    private let push = CommsPushCenter.shared
    /// Bumped on every return to the foreground: restarts the event stream.
    @State private var streamGeneration = 0
    @State private var wasBackgrounded = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    /// - Parameters:
    ///   - detailsAccessory: extra content at the top of Details for a thread (DEBUG demo only).
    ///   - onSignOut: offered in the list's Edit menu.
    public init(backend: any ChatBackend, presence: any OwnerPresence = DeviceOwnerPresence(), detailsAccessory: ((String) -> AnyView)? = nil, onSignOut: (() -> Void)? = nil) {
        self.backend = backend
        self.detailsAccessory = detailsAccessory
        self.onSignOut = onSignOut
        _model = State(initialValue: MainWindowModel(backend: backend, presence: presence))
    }

    private var openThreadID: String? { sizeClass == .regular ? selection : path.last }

    public var body: some View {
        let store = model.store
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    PhoneThreadList(store: store, search: model.search, tidy: model.tidy, query: $query, selection: Binding(get: { selection }, set: { selection = $0 }),
                                    showsSelection: true, backCount: 0, onSignOut: onSignOut, onCompose: startCompose,
                                    onNotificationSettings: openNotificationSettings)
                } detail: {
                    NavigationStack {
                        if let id = selection {
                            transcript(id)
                        } else {
                            ContentUnavailableView("No Conversation Selected", systemImage: "message")
                        }
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    PhoneThreadList(store: store, search: model.search, tidy: model.tidy, query: $query, selection: Binding(get: { nil }, set: { id in if let id { path = [id] } }),
                                    showsSelection: false, backCount: unreadElsewhere, onSignOut: onSignOut, onCompose: startCompose,
                                    onNotificationSettings: openNotificationSettings)
                        .navigationDestination(for: String.self) { id in transcript(id) }
                }
            }
        }
        .sheet(isPresented: Binding(get: { compose != nil }, set: { if !$0 { compose = nil } })) {
            if let compose {
                NavigationStack {
                    ComposeView(store: compose) { id in openComposed(id) }
                        .navigationTitle("New Message")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel", role: .cancel) { self.compose = nil }
                                    .accessibilityIdentifier("compose-cancel")
                            }
                        }
                }
                .environment(\.avatarLoader, model.avatars)
                .environment(\.omniStore, model.omni)
                .presentationDragIndicator(.hidden)
            }
        }
        .sheet(isPresented: Binding(get: { notificationSettings != nil }, set: { if !$0 { notificationSettings = nil } })) {
            if let notificationSettings {
                NavigationStack {
                    NotificationSettingsView(store: notificationSettings, devicePermission: push.permissionGranted)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { self.notificationSettings = nil }
                                    .accessibilityIdentifier("notify-done")
                            }
                        }
                }
            }
        }
        // Sprint Task 1: push registration, notification taps, the app badge, presence.
        .task { push.setBackend(backend) }
        .onDisappear { push.setBackend(nil) }
        .onChange(of: push.pendingThreadID, initial: true) { _, id in
            guard let id else { return }
            push.pendingThreadID = nil
            compose = nil
            notificationSettings = nil
            if sizeClass == .regular { selection = id } else { path = [id] }
        }
        .onChange(of: model.store.attentionUnread) { _, n in
            UNUserNotificationCenter.current().setBadgeCount(n)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in model.store.appActive = phase == .active }
        .environment(\.avatarLoader, model.avatars)
        .environment(\.omniStore, model.omni)
        .environment(\.mediaLoader, model.media)
        .environment(\.mediaFetcher, MediaFetcher(backend: backend))
        .environment(\.peopleDirectory, PeopleDirectory { [backend] id in try await backend.person(id: id) })
        .environment(\.tidyStore, model.tidy)
        .environment(\.openConversation, OpenConversationAction { [$selection, $path, sizeClass] id in
            // A shared conversation from Details replaces the open one (Details goes with it).
            if sizeClass == .regular { $selection.wrappedValue = id } else { $path.wrappedValue = [id] }
        })
        .task { await store.load() }
        .task(id: streamGeneration) {
            let timeline = model.timeline
            let tidy = model.tidy
            let omni = model.omni
            let pump = LiveEventPump(backend: backend) { event in
                store.apply(event)
                timeline.store?.apply(event)
                // Decisions made on another device (owner-testing round 4).
                tidy.apply(event)
                omni.apply(event)
            }
            await pump.run()
        }
        .onChange(of: openThreadID, initial: true) { _, id in store.openThreadID = id }
        .onChange(of: sizeClass) { old, new in
            // Keep the open conversation across a size-class change (iPad multitasking).
            if new == .regular, let id = path.last { selection = id }
            if new == .compact, let id = selection { path = [id] }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: wasBackgrounded = true
            case .active where wasBackgrounded:
                wasBackgrounded = false
                streamGeneration += 1
                // A reconnect is a fresh chance for media that failed before.
                AvatarCache.shared.forgetFailures()
                model.media.forgetFailures()
                let timeline = model.timeline
                Task {
                    await store.load()
                    await timeline.store?.refreshLatest()
                }
                // People to Tidy as other devices left it.
                model.tidy.scheduleReload()
                // APNs registration again on every return (Apple's advice; a failed or stale
                // registration heals without a relaunch — owner-testing round 4).
                if Bundle.main.bundleURL.pathExtension == "app" { UIApplication.shared.registerForRemoteNotifications() }
                push.reregister()
            default: break
            }
        }
    }

    private func startCompose() {
        compose = ComposeStore(backend: backend, outbox: model.outbox)
    }

    private func openNotificationSettings() {
        notificationSettings = NotificationSettingsStore(backend: backend)
    }

    /// The sheet picked or started a conversation: close it and show the conversation.
    private func openComposed(_ id: String) {
        compose = nil
        if sizeClass == .regular { selection = id } else { path = [id] }
        Task { await model.store.load() }
    }

    /// Unread messages in every other conversation (Messages' back-button count).
    private var unreadElsewhere: Int {
        let store = model.store
        let open = path.last
        return (store.pinned + store.threads).reduce(0) { $0 + ($1.id == open ? 0 : max(0, $1.unread.count)) }
    }

    private func transcript(_ id: String) -> some View {
        let store = model.store
        return PhoneTranscriptScreen(
            backend: backend, threadID: id, thread: (store.pinned + store.threads).first { $0.id == id },
            slot: model.timeline, outbox: model.outbox, accessory: detailsAccessory?(id))
            .id(id)
    }
}

/// One conversation; its store lives as long as the screen.
private struct PhoneTranscriptScreen: View {
    let slot: OpenTimeline
    let accessory: AnyView?
    @State private var store: TimelineStore

    init(backend: any ChatBackend, threadID: String, thread: CommsThread?, slot: OpenTimeline, outbox: Outbox, accessory: AnyView?) {
        self.slot = slot
        self.accessory = accessory
        _store = State(initialValue: TimelineStore(backend: backend, threadID: threadID, thread: thread, gapMinutes: Tokens.transcript.timeHeaderGapMinutes, outbox: outbox))
    }

    var body: some View {
        PhoneTranscriptView(store: store, detailsAccessory: accessory)
            .onAppear { slot.store = store }
            .onDisappear { if slot.store === store { slot.store = nil } }
    }
}

/// The conversation list screen: Messages' chrome — inline title with pins (large without),
/// Edit on the left, the Filter circle on the right, a floating Search capsule + Compose
/// circle at the bottom (the New Message sheet).
struct PhoneThreadList: View {
    @Bindable var store: ThreadListStore
    var search: MessageSearchStore? = nil
    var tidy: TidyStore? = nil
    @Binding var query: String
    @Binding var selection: String?
    let showsSelection: Bool
    let backCount: Int
    let onSignOut: (() -> Void)?
    let onCompose: () -> Void
    var onNotificationSettings: (() -> Void)? = nil

    @State private var tokens: [SearchToken] = []
    @State private var showsTidy = false
    @Environment(\.omniStore) private var omni

    /// Pending Omni proposals for the menu; nil = no Omni on this server (no Needs You).
    private var needsYouCount: Int? { omni.flatMap { $0.isAvailable ? $0.needsYou.count : nil } }

    var body: some View {
        Sidebar(store: store, selection: $selection, searchText: query, messageSearch: search, tokens: $tokens, tidy: tidy,
                onOpenTidy: { showsTidy = true })
            .refreshable { await store.loadFolders(); await store.load(); await tidy?.load() }
            // The title is the page: "Comms" (all), a folder's name, or "Needs You". Pages are
            // chosen from the top-left menu only — no strip, no paging swipes (polish r2, owner).
            .navigationTitle(store.pageTitle)
            .navigationBarTitleDisplayMode(store.pinned.isEmpty || store.showsNeedsYou ? .large : .inline)
            .searchable(text: $query, tokens: $tokens, prompt: "Search") { token in
                Label(token.label, systemImage: token.systemImage)
            }
            .onChange(of: search?.text ?? "") { _, t in if query != t { query = t } }
            .sheet(isPresented: $showsTidy) {
                if let tidy {
                    NavigationStack {
                        PeopleToTidyView(store: tidy) { id in showsTidy = false; selection = id }
                            .navigationTitle("People to Tidy")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsTidy = false } } }
                    }
                }
            }
            .searchDictationBehavior(.inline(activation: .onSelect))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // The list's one menu: the pages (Comms · each folder · Needs You), folder
                    // management, then Notifications and Sign Out.
                    Menu {
                        ListPageMenuItems(store: store, needsYouCount: needsYouCount, tidyCount: tidy?.total ?? 0, onTidy: { showsTidy = true })
                        if store.canUseFolders, !store.showsNeedsYou {
                            Button("Select Conversations", systemImage: "checkmark.circle") { withAnimation(.snappy) { store.isSelecting = true } }
                                .accessibilityIdentifier("select-conversations")
                        }
                        Divider()
                        if let onNotificationSettings {
                            Button("Notifications", systemImage: "bell.badge", action: onNotificationSettings)
                                .accessibilityIdentifier("notification-settings")
                        }
                        if let onSignOut {
                            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: onSignOut)
                                .accessibilityIdentifier("sign-out")
                        }
                    } label: {
                        Label("Folders", systemImage: "folder")
                            .overlay(alignment: .topTrailing) {
                                if let n = needsYouCount, n > 0, !store.showsNeedsYou {
                                    // Something waits in Needs You.
                                    Circle().fill(OmniStyle.tint).frame(width: 7, height: 7).offset(x: 3, y: -2)
                                }
                            }
                    }
                    .accessibilityLabel("Folders")
                    .accessibilityValue(needsYouCount.map { $0 > 0 ? "\(store.pageTitle), \($0) need you" : store.pageTitle } ?? store.pageTitle)
                    .accessibilityIdentifier("list-edit")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    FilterMenu(filter: $store.filter)
                }
                if store.isSelecting {
                    // Multi-select: add the chosen conversations to a folder, or stop.
                    ToolbarItem(placement: .bottomBar) {
                        Menu {
                            FolderMenuItems(actions: selectionActions, threadIDs: store.selectedIDs.sorted(), isIn: { _ in false })
                        } label: {
                            Label("Add to Folder", systemImage: "folder.badge.plus")
                        }
                        .disabled(store.selectedIDs.isEmpty)
                        .accessibilityIdentifier("selection-add-to-folder")
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button("Done") { withAnimation(.snappy) { store.isSelecting = false } }
                            .accessibilityIdentifier("selection-done")
                    }
                } else {
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                    ToolbarSpacer(.fixed, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button(action: onCompose) { Label("Compose", systemImage: "square.and.pencil") }
                            .accessibilityLabel("New Message")
                            .accessibilityIdentifier("list-compose")
                    }
                }
            }
            .background { BackButtonCount(count: backCount).frame(width: 0, height: 0).accessibilityHidden(true) }
    }
}

extension PhoneThreadList {
    /// The selection toolbar's folder actions (add every selected conversation).
    var selectionActions: ConversationActions {
        let store = store
        return ConversationActions(
            support: [], toggleMute: { _ in }, setArchived: { _, _ in }, setStatus: { _, _ in },
            foldersEnabled: true, folders: store.folders,
            // One selected conversation shows the toggle form of the menu: it adds too.
            toggleFolder: { t, f in Task { await store.toggleMembership(t, f); withAnimation(.snappy) { store.isSelecting = false } } },
            addToFolder: { ids, f in Task { await store.add(ids, toFolder: f); withAnimation(.snappy) { store.isSelecting = false } } },
            newFolder: { ids in store.newFolderRequest = ids })
    }
}

/// Messages' back button: "‹ 3" in a glass capsule when other conversations have unread
/// messages, the bare chevron otherwise. SwiftUI has no API for the next screen's back title,
/// so this sets the list screen's `navigationItem.backButtonTitle` (the system button keeps
/// its swipe-back and long-press menu).
private struct BackButtonCount: UIViewControllerRepresentable {
    let count: Int

    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ probe: Probe, context: Context) {
        probe.count = count
        probe.applyCount()
    }

    final class Probe: UIViewController {
        var count = 0

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyCount()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyCount()
        }

        /// The screen's controller: the ancestor whose parent is the navigation controller.
        private var screen: UIViewController? {
            var vc: UIViewController? = self
            while let v = vc {
                if v.parent is UINavigationController { return v }
                vc = v.parent
            }
            return nil
        }

        func applyCount() {
            guard let item = screen?.navigationItem else { return }
            let title = count > 0 ? (count > 999 ? "999+" : "\(count)") : ""
            if item.backButtonTitle != title { item.backButtonTitle = title }
            let mode: UINavigationItem.BackButtonDisplayMode = count > 0 ? .default : .minimal
            if item.backButtonDisplayMode != mode { item.backButtonDisplayMode = mode }
        }
    }
}
#endif
