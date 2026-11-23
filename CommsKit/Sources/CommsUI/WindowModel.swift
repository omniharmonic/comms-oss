import CommsClient
import CommsCore
import SwiftUI

/// The window's long-lived state: the list store, the open timeline and the media caches.
/// Cheap to build (no I/O until the views' tasks run).
@MainActor
public final class MainWindowModel {
    public let store: ThreadListStore
    /// The open transcript, so live events reach it as well as the list.
    public let timeline = OpenTimeline()
    /// One media cache for the window (bubbles' pictures through the authenticated backend).
    public let media: MediaLoader
    /// Avatars through the same authenticated backend (`ChatBackend.media(token:)`).
    public let avatars: AvatarLoader
    /// The window's outgoing messages: they outlive each transcript (leaving a conversation
    /// before the echo, or with a "Not Delivered" bubble, keeps them).
    public let outbox: Outbox
    /// Full message search (Task 4).
    public let search: MessageSearchStore
    /// Contact tidy-up: People to tidy and "Who is this?" (Task 4).
    public let tidy: TidyStore
    /// Omni in Comms: drafts, Omni mode, Needs you (offered only when the server declares it).
    public let omni: OmniStore

    /// `presence`: the owner check before Approve & Send (Face ID / Touch ID; the DEBUG demo and
    /// tests pass a fixed answer).
    public init(backend: any ChatBackend, presence: any OwnerPresence = DeviceOwnerPresence()) {
        store = ThreadListStore(backend: backend)
        search = MessageSearchStore(backend: backend)
        tidy = TidyStore(backend: backend)
        outbox = Outbox(backend: backend)
        omni = OmniStore(backend: backend, presence: presence)
        media = MediaLoader(fetch: { token in try await backend.media(token: token).0 })
        avatars = AvatarLoader { token in try await backend.media(token: token).0 }
        // Telegram forums (fix round 1): the open transcript's read point and compose target.
        store.forumReadPoint = { [timeline] id in timeline.store?.threadID == id ? timeline.store?.forumReadPoint : nil }
        omni.topicFor = { [timeline] id in timeline.store?.threadID == id ? timeline.store?.composeTopic?.id : nil }
        timeline.onReadPoint = { [weak store] id in store?.forumReadPointChanged(id) }
    }
}

/// Holds the open timeline for the event pump (a reference, so the pump's closure sees changes).
@MainActor
public final class OpenTimeline {
    public weak var store: TimelineStore? {
        didSet {
            guard let store, let onReadPoint else { return }
            let id = store.threadID
            store.onReadPointChange = { onReadPoint(id) }
        }
    }
    /// A forum's read point moved in the open transcript (the list store reads it).
    public var onReadPoint: (@MainActor (String) -> Void)?
}
