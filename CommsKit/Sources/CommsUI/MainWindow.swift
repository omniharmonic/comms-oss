// The Mac window (the transcript is the AppKit table): macOS-only.
#if os(macOS)
import CommsClient
import CommsCore
import AppKit
import CoreGraphics
import SwiftUI
import UserNotifications

/// The signed-in window: the conversation list plus the live event stream that keeps it current.
/// The stream lives as long as this view (signing out tears it down, which cancels it).
/// (The Mac app's DEBUG demo mode shows the same window over the fixture backend.)
///
/// Everything the window needs is built in `init`, so its body is never empty: SwiftUI does
/// not call `onAppear`/`task` on a view that renders nothing, and an earlier version that
/// created the list store in `onAppear` of an empty `Group` launched to a blank window.
public struct MainWindow: View {
    private let backend: any ChatBackend
    /// Told the selected conversation (demo mode aims its simulated events at it).
    private let onSelectionChange: (String?) -> Void
    @State private var model: MainWindowModel
    @State private var selection: String?
    /// The New Message column while it is up (Messages shows it in the detail pane).
    @State private var compose: ComposeStore?
    @Environment(\.controlActiveState) private var controlActive
    private let push = CommsPushCenter.shared

    /// Sidebar (240) + a usable transcript column; tall enough for header, rows and composer.
    public static let minSize = CGSize(width: 760, height: 520)

    public init(backend: any ChatBackend, presence: any OwnerPresence = DeviceOwnerPresence(), onSelectionChange: @escaping (String?) -> Void = { _ in }) {
        self.backend = backend
        self.onSelectionChange = onSelectionChange
        _model = State(initialValue: MainWindowModel(backend: backend, presence: presence))
    }

    public var body: some View {
        let store = model.store
        let timeline = model.timeline
        ThreadListSplitView(store: store, selection: $selection, messageSearch: model.search, tidy: model.tidy, onCompose: {
            selection = nil
            compose = ComposeStore(backend: backend, outbox: model.outbox)
        }) { selected in
            if let compose, selected == nil {
                ComposeView(store: compose) { id in
                    self.compose = nil
                    selection = id
                    Task { await store.load() }
                }
                .navigationTitle("New Message")
                .onExitCommand { self.compose = nil }
            } else if let selected {
                TranscriptScreen(backend: backend, threadID: selected, thread: (store.pinned + store.threads).first { $0.id == selected }, slot: timeline, outbox: model.outbox)
                    .id(selected)
            } else {
                ContentUnavailableView("No Conversation Selected", systemImage: "message")
            }
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .environment(\.avatarLoader, model.avatars)
        .environment(\.omniStore, model.omni)
        .environment(\.mediaLoader, model.media)
        .environment(\.mediaFetcher, MediaFetcher(backend: backend))
        .environment(\.peopleDirectory, PeopleDirectory { [backend] id in try await backend.person(id: id) })
        .environment(\.openConversation, OpenConversationAction { [$selection] id in $selection.wrappedValue = id })
        .environment(\.tidyStore, model.tidy)
        .task(id: ObjectIdentifier(store)) {
            // Each event goes to the list and the open timeline. Reconnects back off
            // 1 s → 30 s and resume with Last-Event-ID.
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
        // Sprint Task 1: push registration, notification taps, the Dock badge, presence.
        .task { push.setBackend(backend) }
        .onDisappear { push.setBackend(nil) }
        .onChange(of: push.pendingThreadID, initial: true) { _, id in
            guard let id else { return }
            push.pendingThreadID = nil
            compose = nil
            selection = id
        }
        .onChange(of: store.attentionUnread) { _, n in
            // Only inside the app bundle (a hosted test window has none: the center would throw).
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            UNUserNotificationCenter.current().setBadgeCount(n)
        }
        // "Being read" (review I3): frontmost app + key window + recent input, re-checked every
        // 10 s and at once when the app or window changes state. Otherwise no viewing lease is
        // held, so the owner's other devices are notified and arrivals stay unread.
        .task(id: controlActive) {
            while !Task.isCancelled {
                updatePresence()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in store.appActive = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updatePresence()
            // People to Tidy as other devices left it (owner-testing round 4).
            model.tidy.scheduleReload()
        }
        .onChange(of: selection, initial: true) { _, id in
            // The open conversation reads as read, including messages arriving while open.
            store.openThreadID = id
            if id != nil { compose = nil }
            onSelectionChange(id)
        }
    }
}

extension MainWindow {
    @MainActor fileprivate func updatePresence() {
        // Seconds since the last key press / click / pointer move anywhere (no permission needed).
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let reading = ReadingPresence.isReading(appActive: NSApp.isActive, windowKey: controlActive == .key, idleSeconds: idle)
        if model.store.appActive != reading { model.store.appActive = reading }
    }
}

/// The transcript of one conversation; its store lives as long as the selection.
private struct TranscriptScreen: View {
    let slot: OpenTimeline
    @State private var store: TimelineStore

    init(backend: any ChatBackend, threadID: String, thread: CommsThread?, slot: OpenTimeline, outbox: Outbox) {
        self.slot = slot
        _store = State(initialValue: TimelineStore(backend: backend, threadID: threadID, thread: thread, gapMinutes: Tokens.transcript.timeHeaderGapMinutes, outbox: outbox))
    }

    var body: some View {
        TranscriptView(store: store)
            .onAppear { slot.store = store }
            .onDisappear { if slot.store === store { slot.store = nil } }
    }
}

#endif
