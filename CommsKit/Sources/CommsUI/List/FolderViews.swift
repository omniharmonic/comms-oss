import CommsClient
import CommsCore
import SwiftUI

// Owner folders on screen (sprint Task 9; polish r2 owner redirect): no paging gestures and no
// strip — "too easy to swipe away accidentally". The page is chosen from ONE menu: on iPhone the
// list's top-left button, on the Mac a title button at the top of the sidebar. It lists Comms
// (All), each owner folder, then Needs You (Omni's proposals, a list of its own), then New
// Folder… / Edit Folders…, and on a folder page that folder's Notifications ▸. ⌃⌘← / ⌃⌘→ still
// page on a keyboard.

extension ThreadListStore {
    /// The page's title: Needs You, the folder's name, or the system folder's ("Comms" for the inbox).
    var pageTitle: String { showsNeedsYou ? "Needs You" : currentFolder?.name ?? filter.folder.title }
}

/// The page choices and folder management, as menu items (the iPhone list's top-left menu and the
/// Mac sidebar's title menu). The current page is checked.
struct ListPageMenuItems: View {
    @Bindable var store: ThreadListStore
    /// Pending Omni proposals; nil = no Omni on this server (no Needs You).
    let needsYouCount: Int?
    /// People to Tidy (round 3: here instead of a row in the list / the Filter menu).
    var tidyCount: Int = 0
    var onTidy: (() -> Void)? = nil

    var body: some View {
        // Dividers, not Sections: menu items inside a Section lose their accessibility ids.
        ForEach(Array(store.pages.enumerated()), id: \.offset) { i, page in
            let title = page.flatMap { id in store.folders.first { $0.id == id }?.name } ?? "Comms"
            Toggle(isOn: Binding(get: { !store.showsNeedsYou && store.pageIndex == i },
                                 set: { if $0 { withAnimation(.snappy) { store.showPage(i) } } })) {
                Label(title, systemImage: page == nil ? "bubble.left.and.bubble.right" : "folder")
            }
            .accessibilityIdentifier("folder-page-\(title)")
        }
        if let n = needsYouCount {
            Toggle(isOn: Binding(get: { store.showsNeedsYou }, set: { if $0 { withAnimation(.snappy) { store.showNeedsYou() } } })) {
                Label(n > 0 ? "Needs You (\(n))" : "Needs You", systemImage: OmniStyle.sparkle)
            }
            .accessibilityIdentifier("folder-page-needs-you")
        }
        if let onTidy, tidyCount > 0 {
            Button(action: onTidy) {
                Label("People to Tidy (\(tidyCount))", systemImage: "person.crop.circle.badge.questionmark")
            }
            .accessibilityIdentifier("folder-menu-tidy")
        }
        if store.canUseFolders {
            Divider()
            Button("New Folder…", systemImage: "folder.badge.plus") { store.newFolderRequest = [] }
                .accessibilityIdentifier("new-folder")
            if !store.folders.isEmpty {
                Button("Edit Folders…", systemImage: "folder.badge.gearshape") { store.showsEditFolders = true }
                    .accessibilityIdentifier("edit-folders")
            }
            if !store.showsNeedsYou, let f = store.currentFolder {
                FolderNotifyMenu(store: store, folderID: f.id)
            }
        }
    }
}

/// Mac: the folder button in the sidebar's top glass group, beside Filter and Compose (round 3,
/// owner): a glass circle with a folder, its menu the same page menu as the iPhone's top-left
/// button. The page itself shows as the sidebar's title is hidden: the button's help and
/// VoiceOver value name it; a dot marks something waiting in Needs You.
struct FolderMenuButton: View {
    @Bindable var store: ThreadListStore
    let needsYouCount: Int?
    var tidyCount: Int = 0
    var onTidy: (() -> Void)? = nil

    var body: some View {
        Menu {
            ListPageMenuItems(store: store, needsYouCount: needsYouCount, tidyCount: tidyCount, onTidy: onTidy)
        } label: {
            Label("Folders", systemImage: store.currentFolder != nil || store.showsNeedsYou ? "folder.fill" : "folder")
                .overlay(alignment: .topTrailing) {
                    if let n = needsYouCount, n > 0, !store.showsNeedsYou {
                        // Something waits in Needs You.
                        Circle().fill(OmniStyle.tint).frame(width: 6, height: 6).offset(x: 3, y: -2).accessibilityHidden(true)
                    }
                }
        }
        .menuIndicator(.hidden)
        .help("Folders — \(store.pageTitle)")
        .accessibilityLabel("Folders")
        .accessibilityValue(store.pageTitle)
        .accessibilityIdentifier("folder-switcher")
    }
}

extension CommsFolderNotify {
    /// The choice as Settings and the folder menu show it.
    var title: String {
        switch self {
        case .default: "Default"
        case .all: "All Messages"
        case .off: "None"
        }
    }
}

/// A folder's "Notifications ▸ Default / All Messages / None" (a submenu with a checkmark on the
/// current choice, as Mail's per-mailbox notification menu).
struct FolderNotifyMenu: View {
    let store: ThreadListStore
    let folderID: String

    var body: some View {
        Menu {
            Picker("Notifications", selection: Binding(
                get: { store.notifyRule(forFolder: folderID) },
                set: { rule in Task { await store.setNotifyRule(rule, forFolder: folderID) } }
            )) {
                ForEach(CommsFolderNotify.allCases, id: \.self) { rule in
                    Text(rule.title).tag(rule)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Notifications", systemImage: store.notifyRule(forFolder: folderID) == .off ? "bell.slash" : "bell")
        }
        .accessibilityIdentifier("folder-notify-menu")
    }
}

/// ⌃⌘← / ⌃⌘→ page the list (Mac; harmless on iPad with a keyboard). Invisible.
struct FolderPageShortcuts: View {
    let store: ThreadListStore

    var body: some View {
        ZStack {
            Button("Previous Folder") { withAnimation(.snappy) { _ = store.page(by: -1) } }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
            Button("Next Folder") { withAnimation(.snappy) { _ = store.page(by: 1) } }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// Mail's "Undo" after Archive or a status change, at the bottom of the list (6 s).
struct UndoBanner: View {
    let store: ThreadListStore

    var body: some View {
        if let offer = store.undoOffer {
            UndoBannerContent(title: offer.title) { Task { await store.undo() } }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: offer.id) {
                    try? await Task.sleep(for: .seconds(6))
                    if store.undoOffer?.id == offer.id { store.dismissUndo() }
                }
        }
    }
}

/// The banner itself: what was done, and Undo.
struct UndoBannerContent: View {
    let title: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.callout).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
            Button("Undo", action: undo)
                .font(.callout.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(ListMetrics.accent)
                .accessibilityIdentifier("undo-button")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        #if os(iOS)
        .glassEffect(.regular, in: .capsule)
        #else
        // The Mac sidebar is already glass: a material capsule (also what snapshots can render).
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        #endif
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("undo-banner")
    }
}

/// Edit Folders: rename, reorder (drag), delete, add.
struct EditFoldersView: View {
    @Bindable var store: ThreadListStore
    @State private var names: [String: String] = [:]
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                ForEach(store.folders) { f in
                    TextField("Name", text: Binding(get: { names[f.id] ?? f.name }, set: { names[f.id] = $0 }))
                        .onSubmit { commit(f.id) }
                        .accessibilityIdentifier("edit-folder-\(f.name)")
                }
                .onMove { from, to in
                    guard let i = from.first else { return }
                    let id = store.folders[i].id
                    Task { await store.moveFolder(id, to: to > i ? to - 1 : to) }
                }
                .onDelete { set in
                    for i in set { let id = store.folders[i].id; Task { await store.deleteFolder(id) } }
                }
            } footer: {
                Text("Conversations stay in Comms when you delete a folder.")
            }
            Section {
                TextField("New Folder", text: $newName)
                    .onSubmit(addFolder)
                    .accessibilityIdentifier("edit-folders-new")
            }
        }
        .formStyle(.grouped)
        .onDisappear { for f in store.folders { commit(f.id) } }
    }

    private func commit(_ id: String) {
        guard let name = names[id] else { return }
        names[id] = nil
        Task { await store.renameFolder(id, to: name) }
    }

    private func addFolder() {
        let name = newName
        newName = ""
        Task { await store.createFolder(name: name) }
    }
}

/// The New Folder name prompt (an alert with a text field, as Notes' and Mail's).
struct NewFolderPrompt: ViewModifier {
    @Binding var threadIDs: [String]?
    let store: ThreadListStore
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert("New Folder", isPresented: Binding(get: { threadIDs != nil }, set: { if !$0 { threadIDs = nil } })) {
            TextField("Name", text: $name)
                .accessibilityIdentifier("new-folder-name")
            Button("Cancel", role: .cancel) { name = ""; threadIDs = nil }
            Button("Save") {
                let ids = threadIDs ?? []
                let n = name
                name = ""
                threadIDs = nil
                Task {
                    if let f = await store.createFolder(name: n), !ids.isEmpty { await store.add(ids, toFolder: f.id) }
                }
            }
            .accessibilityIdentifier("new-folder-save")
        } message: {
            Text("Enter a name for this folder.")
        }
    }
}
