import CommsClient
import CommsCore
import SwiftUI

/// What the list's Mute / Archive / Status / folder actions do (sprint Task 9). Nil on a list =
/// none of them (snapshots, the design gallery); `support` hides what the server does not offer.
struct ConversationActions {
    var support: RowActionSupport
    var toggleMute: (String) -> Void
    var setArchived: (String, Bool) -> Void
    var setStatus: (String, CommsThreadStatus) -> Void
    /// Folders (empty + `foldersEnabled` false = no "Add to Folder").
    var foldersEnabled: Bool = false
    var folders: [CommsChatFolder] = []
    var toggleFolder: (String, String) -> Void = { _, _ in }
    var addToFolder: ([String], String) -> Void = { _, _ in }
    /// "New Folder…": ask for a name, create it, add these conversations.
    var newFolder: ([String]) -> Void = { _ in }
    /// The folder page on screen ("Remove from “Work”"); nil on the home page.
    var currentFolder: CommsChatFolder?
    var removeFromFolder: (String, String) -> Void = { _, _ in }
    /// The conversations a folder action on this row applies to (the multi-selection, or itself).
    var targets: (String) -> [String] = { [$0] }
    /// The swipe's Status button: an action sheet of the statuses (and folders).
    var askStatus: (String) -> Void = { _ in }

    static func muteTitle(_ muted: Bool) -> String { muted ? "Unmute" : "Mute" }
    static func muteSymbol(_ muted: Bool) -> String { muted ? "bell" : "bell.slash" }
    static func archiveTitle(_ archived: Bool) -> String { archived ? "Unarchive" : "Archive" }
    static func archiveSymbol(_ archived: Bool) -> String { archived ? "tray.and.arrow.up" : "archivebox" }
}

/// Messages' actions on a conversation row (Tasks 1 + 8 merged at integration, Task 9 added the
/// rest), ONE context menu and ONE swipe per row:
/// - the context menu (right-click on the Mac, touch and hold on iPhone): Pin / Unpin, Mark as
///   Read / Unread, Mute / Unmute, Archive / Unarchive, Status ›, Add to Folder ›, and on a
///   folder page Remove from “Folder”;
/// - the swipe (iPhone, and a two-finger swipe on the Mac trackpad; `RowSwipe`): leading = the
///   blue Read / Unread at the outer edge (the full-swipe action) and the yellow Pin; trailing =
///   Archive at the outer edge (full swipe), Mute, and Status (a sheet of the triage statuses,
///   then the folders — `StatusSheet`);
/// - VoiceOver: each as a custom action.
struct RowActions: ViewModifier {
    let thread: CommsThread
    let onSetRead: ((String, Bool) -> Void)?
    let pins: PinActions?
    var actions: ConversationActions? = nil

    private var isUnread: Bool { thread.unread.count > 0 }
    private var readTitle: String { isUnread ? "Mark as Read" : "Mark as Unread" }
    private var readSymbol: String { isUnread ? "message" : "message.badge" }
    private var archived: Bool { thread.folder == .archived }
    private var support: RowActionSupport { actions?.support ?? [] }
    /// Status needs a vault note (iMessage / SMS threads from BlueBubbles have none).
    private var canSetStatus: Bool {
        support.contains(.status) && (thread.noteId != nil || !thread.networks.allSatisfy { $0 == .imessage || $0 == .sms })
    }
    private var hasFolders: Bool { actions?.foldersEnabled == true }

    func body(content: Content) -> some View {
        if onSetRead == nil && pins == nil && actions == nil {
            content
        } else {
            let id = thread.id
            let pinned = pins?.isPinned(id) ?? false
            content
                .modifier(RowSwipe(id: id, leading: leadingItems(pinned: pinned), trailing: trailingItems()))
                .contextMenu { menu(pinned: pinned) }
                .modifier(OptionalAccessibilityAction(title: pins.map { _ in PinActions.label(pinned: pinned) }) { pins?.toggle(id) })
                .modifier(OptionalAccessibilityAction(title: onSetRead.map { _ in readTitle }) { onSetRead?(id, isUnread) })
                .modifier(OptionalAccessibilityAction(title: support.contains(.mute) ? ConversationActions.muteTitle(thread.muted) : nil) { actions?.toggleMute(id) })
                .modifier(OptionalAccessibilityAction(title: support.contains(.archive) ? ConversationActions.archiveTitle(archived) : nil) { actions?.setArchived(id, !archived) })
        }
    }

    @ViewBuilder private func menu(pinned: Bool) -> some View {
        let id = thread.id
        if let pins {
            Button(PinActions.label(pinned: pinned), systemImage: PinActions.symbol(pinned: pinned)) { pins.toggle(id) }
                .accessibilityIdentifier("pin-menu-\(id)")
        }
        if let onSetRead {
            Button(readTitle, systemImage: readSymbol) { onSetRead(id, isUnread) }
                .accessibilityIdentifier(isUnread ? "row-mark-read" : "row-mark-unread")
        }
        if let actions {
            if support.contains(.mute) {
                Button(ConversationActions.muteTitle(thread.muted), systemImage: ConversationActions.muteSymbol(thread.muted)) { actions.toggleMute(id) }
                    .accessibilityIdentifier("row-mute")
            }
            if support.contains(.archive) {
                Button(ConversationActions.archiveTitle(archived), systemImage: ConversationActions.archiveSymbol(archived)) { actions.setArchived(id, !archived) }
                    .accessibilityIdentifier("row-archive")
            }
            if canSetStatus {
                Menu {
                    statusItems(actions)
                } label: {
                    Label("Status", systemImage: "flag")
                }
                .accessibilityIdentifier("row-status")
            }
            if hasFolders {
                let targets = actions.targets(id)
                Menu {
                    folderItems(actions, threadIDs: targets)
                } label: {
                    Label(targets.count > 1 ? "Add \(targets.count) Conversations to Folder" : "Add to Folder", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("row-add-to-folder")
                if let folder = actions.currentFolder {
                    Button("Remove from “\(folder.name)”", systemImage: "folder.badge.minus") { actions.removeFromFolder(id, folder.id) }
                        .accessibilityIdentifier("row-remove-from-folder")
                }
            }
        }
    }

    /// The triage statuses (Prism's settable ones), the current one checked.
    @ViewBuilder private func statusItems(_ actions: ConversationActions) -> some View {
        let id = thread.id
        ForEach(CommsThreadStatus.settable, id: \.wire) { s in
            Toggle(isOn: Binding(get: { thread.status == s }, set: { if $0 { actions.setStatus(id, s) } })) {
                Label(s.label, systemImage: TriageFilter.status(s).symbol)
            }
            .accessibilityIdentifier("status-\(s.wire)")
        }
    }

    @ViewBuilder private func folderItems(_ actions: ConversationActions, threadIDs: [String]) -> some View {
        FolderMenuItems(actions: actions, threadIDs: threadIDs, isIn: { thread.folderIds?.contains($0) == true })
    }

    private func leadingItems(pinned: Bool) -> [SwipeItem] {
        var items: [SwipeItem] = []
        let id = thread.id
        if let onSetRead {
            items.append(.init(title: isUnread ? "Read" : "Unread", systemImage: isUnread ? "message.fill" : "message.badge.fill",
                               color: .accentColor, identifier: "swipe-read-\(id)") { onSetRead(id, isUnread) })
        }
        if let pins {
            items.append(.init(title: PinActions.label(pinned: pinned), systemImage: pinned ? "pin.slash.fill" : "pin.fill",
                               color: .yellow, identifier: "swipe-pin-\(id)") { pins.toggle(id) })
        }
        return items
    }

    /// Outer first: Archive (the full-swipe one), Mute, Status ⌄.
    private func trailingItems() -> [SwipeItem] {
        guard let actions else { return [] }
        let id = thread.id
        var items: [SwipeItem] = []
        if support.contains(.archive) {
            items.append(.init(title: ConversationActions.archiveTitle(archived), systemImage: archived ? "tray.and.arrow.up.fill" : "archivebox.fill",
                               color: .purple, identifier: "swipe-archive-\(id)", removesRow: true) { actions.setArchived(id, !archived) })
        }
        if support.contains(.mute) {
            items.append(.init(title: ConversationActions.muteTitle(thread.muted), systemImage: thread.muted ? "bell.fill" : "bell.slash.fill",
                               color: .indigo, identifier: "swipe-mute-\(id)") { actions.toggleMute(id) })
        }
        if canSetStatus || hasFolders {
            // A sheet, not a menu (Mail's "More" swipe): a menu inside a swipe does not open.
            items.append(.init(title: canSetStatus ? "Status" : "Folder", systemImage: canSetStatus ? "flag.fill" : "folder.fill",
                               color: .gray, identifier: "swipe-status-\(id)") { actions.askStatus(id) })
        }
        return items
    }
}

/// "Add to Folder" contents: each folder (one conversation: checked when it is in it, choosing
/// toggles; several: choosing adds them all), then New Folder….
struct FolderMenuItems: View {
    let actions: ConversationActions
    let threadIDs: [String]
    let isIn: (String) -> Bool

    var body: some View {
        ForEach(actions.folders) { f in
            if threadIDs.count == 1, let id = threadIDs.first {
                // One conversation: checked when it is in the folder; choosing toggles.
                Toggle(isOn: Binding(get: { isIn(f.id) }, set: { _ in actions.toggleFolder(id, f.id) })) {
                    Label(f.name, systemImage: "folder")
                }
                .accessibilityIdentifier("folder-menu-\(f.name)")
            } else {
                // Several (multi-select): add them all.
                Button(f.name, systemImage: "folder") { actions.addToFolder(threadIDs, f.id) }
                    .accessibilityIdentifier("folder-menu-\(f.name)")
            }
        }
        if !actions.folders.isEmpty { Divider() }
        Button("New Folder…", systemImage: "folder.badge.plus") { actions.newFolder(threadIDs) }
            .accessibilityIdentifier("folder-menu-new")
    }
}

/// A named VoiceOver action only when `title` is non-nil.
struct OptionalAccessibilityAction: ViewModifier {
    let title: String?
    let action: () -> Void

    func body(content: Content) -> some View {
        if let title {
            content.accessibilityAction(named: Text(title), action)
        } else {
            content
        }
    }
}

/// The swipe's Status sheet (Mail's "More" sheet): the triage statuses, then the folders.
struct StatusSheet: ViewModifier {
    @Bindable var store: ThreadListStore
    let actions: ConversationActions?

    private var thread: CommsThread? {
        store.statusRequest.flatMap { id in (store.pinned + store.threads + (store.searchResults ?? [])).first { $0.id == id } }
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(thread.map { "“\($0.title)”" } ?? "", isPresented: Binding(get: { store.statusRequest != nil }, set: { if !$0 { store.statusRequest = nil } }),
                                   titleVisibility: .visible, presenting: thread) { t in
            if let actions {
                if actions.support.contains(.status), t.noteId != nil || !t.networks.allSatisfy({ $0 == .imessage || $0 == .sms }) {
                    ForEach(CommsThreadStatus.settable, id: \.wire) { s in
                        Button(t.status == s ? "\(s.label) ✓" : s.label) { actions.setStatus(t.id, s) }
                            .accessibilityIdentifier("status-\(s.wire)")
                    }
                }
                if actions.foldersEnabled {
                    ForEach(actions.folders) { f in
                        let isIn = t.folderIds?.contains(f.id) == true
                        Button(isIn ? "Remove from “\(f.name)”" : "Add to “\(f.name)”") { actions.toggleFolder(t.id, f.id) }
                            .accessibilityIdentifier("status-folder-\(f.name)")
                    }
                    Button("New Folder…") { actions.newFolder([t.id]) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
