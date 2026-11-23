import CommsClient
import CommsCore
import SwiftUI

// Contact tidy-up (D17, PRD §5.11a): the Details "Who is this?" card and the sidebar's
// "People to Tidy" list. Every change is the owner's tap, shown with Undo; the server writes
// the person note (never merges people — a same-name person becomes a "Same person?"
// suggestion in Prism).

extension EnvironmentValues {
    /// The window's tidy store (nil = no tidy-up: snapshots, older servers).
    @Entry public var tidyStore: TidyStore? = nil
}

/// What the owner is choosing for one counterpart; shared by the card and the list rows.
struct TidyChoices: ViewModifier {
    let store: TidyStore
    let item: CommsTidyItem
    @Binding var askingName: Bool
    @State private var name = ""
    @State private var similar: [CommsTidyItem.Suggestion] = []

    func body(content: Content) -> some View {
        content
            .alert("Create New Contact", isPresented: $askingName) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Create") { create(allowSimilar: false) }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("Adds \(item.handle?.value ?? item.name) to your people in Prism.")
            }
            .onChange(of: askingName) { _, asking in if asking { name = Self.suggestedName(item) } }
            .confirmationDialog(similarTitle, isPresented: Binding(get: { !similar.isEmpty }, set: { if !$0 { similar = [] } }), titleVisibility: .visible) {
                ForEach(similar) { p in
                    Button("Link to \(p.name)") { Task { _ = await store.link(threadID: item.threadId, personID: p.personId) } }
                }
                Button("Create \(name) Anyway") { create(allowSimilar: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Creating another may make a duplicate. Prism will ask you later if they're the same person.")
            }
    }

    private var similarTitle: String {
        similar.count == 1 ? "\(similar[0].name) is already in your people" : "People with this name are already in your people"
    }

    private func create(allowSimilar: Bool) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        Task {
            if await store.create(threadID: item.threadId, name: n, allowSimilar: allowSimilar) { return }
            if case .similarPeople(let people) = store.refusal {
                store.dismissRefusal()
                similar = people
            }
        }
    }

    /// The thread's title when it is a name (not a number or an address).
    static func suggestedName(_ item: CommsTidyItem) -> String {
        let t = item.name.trimmingCharacters(in: .whitespaces)
        let digits = t.filter(\.isNumber).count
        return t.contains("@") || digits * 2 > t.count ? "" : t
    }
}

/// Details: "Who is this?" for a DM whose sender is no person yet — link to a suggested
/// person, create a new one, or ignore; afterwards "Added to <name>" with Undo.
struct WhoIsThisCard: View {
    let thread: CommsThread
    @Environment(\.tidyStore) private var store
    @State private var askingName = false
    @State private var picking = false

    var body: some View {
        if let store {
            // Never an empty view: SwiftUI runs no `.task` on a view that renders nothing, and the
            // card has nothing to render until its prompt has loaded.
            VStack(spacing: 0) {
                Color.clear.frame(height: 0).accessibilityHidden(true)
                content(store)
            }
            .task(id: thread.id) { if thread.needsTidy == true { await store.loadPrompt(threadID: thread.id) } }
        }
    }

    @ViewBuilder private func content(_ store: TidyStore) -> some View {
        if let action = store.lastAction, action.threadId == thread.id {
            DetailsSection(id: "details-tidy-done") {
                HStack {
                    Text(Self.doneText(action)).font(.callout)
                    Spacer()
                    Button("Undo") { Task { _ = await store.undo() } }
                        .disabled(store.isWorking)
                        .accessibilityIdentifier("tidy-undo")
                }
                .padding(.vertical, 11)
                if let r = store.refusal { refusalLine(r) }
            }
        } else if thread.needsTidy == true, let item = store.prompts[thread.id] {
            DetailsSection(title: "Who is this?", id: "details-who-is-this") {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.explanation(item))
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                    ForEach(item.suggestions) { s in
                        Divider()
                        rowButton("Link to \(s.name)", subtitle: s.reasonText, systemImage: "person.crop.circle.badge.checkmark", id: "tidy-link-\(s.personId)") {
                            Task { _ = await store.link(threadID: item.threadId, personID: s.personId) }
                        }
                    }
                    Divider()
                    rowButton("Link to Existing Person…", systemImage: "person.crop.circle.badge.questionmark", id: "tidy-link-existing") { picking = true }
                    Divider()
                    rowButton("Create New Contact…", systemImage: "person.crop.circle.badge.plus", id: "tidy-create") { askingName = true }
                    Divider()
                    rowButton("Ignore", systemImage: "eye.slash", id: "tidy-ignore", role: .destructive) {
                        Task { _ = await store.ignore(threadID: item.threadId) }
                    }
                    if let r = store.refusal { refusalLine(r) }
                }
            }
            .disabled(store.isWorking)
            .modifier(TidyChoices(store: store, item: item, askingName: $askingName))
            .sheet(isPresented: $picking) { PersonPickerView(store: store, item: item) { picking = false } }
        }
    }

    private func rowButton(_ title: String, subtitle: String? = nil, systemImage: String, id: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
            } icon: { Image(systemName: systemImage) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 11)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
        .accessibilityIdentifier(id)
    }

    private func refusalLine(_ r: CommsTidyRefusal) -> some View {
        Text(TidyStore.message(r)).font(.footnote).foregroundStyle(.red).padding(.bottom, 10)
    }

    static func explanation(_ item: CommsTidyItem) -> String {
        let who = item.handle?.value ?? item.name
        return "\(who) isn't in your people yet. Adding them keeps names, pictures and conversations together."
    }

    static func doneText(_ a: CommsTidyAction) -> String {
        switch a.kind {
        case "link": "Linked to \(a.personName ?? "the person")."
        case "create": "Added \(a.personName ?? "them") to your people."
        default: "You won't be asked about this again."
        }
    }
}

/// The sidebar row that opens People to Tidy (shown while there is someone to tidy).
struct PeopleToTidyRow: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
                Text("People to Tidy").font(.body)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, ListMetrics.sidebarInset + 12)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("People to Tidy")
        .accessibilityValue("\(count)")
        .accessibilityIdentifier("people-to-tidy")
    }
}

/// People to Tidy: unlinked contacts, most talked-to first, each with its choices.
public struct PeopleToTidyView: View {
    @Bindable var store: TidyStore
    let open: (String) -> Void
    let now: Date

    public init(store: TidyStore, now: Date = .now, open: @escaping (String) -> Void) {
        self.store = store
        self.now = now
        self.open = open
    }

    public var body: some View {
        List {
            if let action = store.lastAction {
                HStack {
                    Text(WhoIsThisCard.doneText(action)).font(.callout)
                    Spacer()
                    Button("Undo") { Task { _ = await store.undo() } }.accessibilityIdentifier("tidy-undo")
                }
            }
            if let r = store.refusal { Text(TidyStore.message(r)).font(.footnote).foregroundStyle(.red) }
            Section {
                ForEach(store.people) { item in
                    TidyRow(store: store, item: item, now: now, open: open)
                        .onAppear { if item.id == store.people.last?.id { Task { await store.loadMore() } } }
                }
            } footer: {
                Text("People you talk with who aren't in your Prism people yet, most frequent first.")
            }
            if store.people.isEmpty, !store.isLoading {
                Text("Everyone you talk with is in your people.").foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("people-to-tidy-list")
    }
}

struct TidyRow: View {
    let store: TidyStore
    let item: CommsTidyItem
    let now: Date
    let open: (String) -> Void
    @State private var askingName = false
    @State private var picking = false

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(item.avatar, kind: .dm, size: 40, badge: item.network, name: item.name)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(item.suggestions) { s in
                    Button {
                        Task { _ = await store.link(threadID: item.threadId, personID: s.personId) }
                    } label: {
                        Label { Text("Link to \(s.name)"); if let r = s.reasonText { Text(r) } } icon: { Image(systemName: "person.crop.circle.badge.checkmark") }
                    }
                }
                Button("Link to Existing Person…", systemImage: "person.crop.circle.badge.questionmark") { picking = true }
                Button("Create New Contact…", systemImage: "person.crop.circle.badge.plus") { askingName = true }
                Button("Show Conversation", systemImage: "bubble.left") { open(item.threadId) }
                Divider()
                Button("Ignore", systemImage: "eye.slash", role: .destructive) { Task { _ = await store.ignore(threadID: item.threadId) } }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Choices for \(item.name)")
            .accessibilityIdentifier("tidy-menu-\(item.threadId)")
        }
        .modifier(TidyChoices(store: store, item: item, askingName: $askingName))
        .sheet(isPresented: $picking) { PersonPickerView(store: store, item: item) { picking = false } }
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let h = item.handle, h.value != item.name { parts.append(h.value) }
        parts.append(item.messageCount == 1 ? "1 message" : "\(item.messageCount) messages")
        parts.append(RelativeStamp.text(item.lastActivityAt, now: now))
        return parts.joined(separator: " · ")
    }
}

/// "Link to Existing Person…" (review I5): search the vault's people by name and pick one —
/// for the contact saved as "Mom" whose chat title is "Margaret", which no suggestion finds.
struct PersonPickerView: View {
    let store: TidyStore
    let item: CommsTidyItem
    let done: () -> Void
    @State private var query: String
    @State private var results: [CommsTidyItem.Suggestion]
    @State private var searched = false

    /// `query` / `results` preset the search (snapshots); the picker searches as the owner types.
    init(store: TidyStore, item: CommsTidyItem, query: String = "", results: [CommsTidyItem.Suggestion] = [], done: @escaping () -> Void) {
        self.store = store
        self.item = item
        self.done = done
        _query = State(initialValue: query)
        _results = State(initialValue: results)
    }

    var body: some View {
        NavigationStack {
            PersonPickerList(store: store, item: item, query: query, results: results, searched: searched, done: done)
                .searchable(text: $query, prompt: "Search People")
                .task(id: query) {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    results = await store.searchPeople(query)
                    searched = true
                }
                .navigationTitle("Link to Person")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) } }
                .disabled(store.isWorking)
        }
        .accessibilityIdentifier("tidy-person-picker")
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
    }
}

/// The picker's list (rendered on its own by snapshots).
struct PersonPickerList: View {
    let store: TidyStore
    let item: CommsTidyItem
    let query: String
    let results: [CommsTidyItem.Suggestion]
    let searched: Bool
    let done: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(results) { p in
                    Button {
                        Task {
                            if await store.link(threadID: item.threadId, personID: p.personId) { done() }
                        }
                    } label: {
                        Label(p.name, systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Links \(item.name) to this person")
                    .accessibilityIdentifier("tidy-pick-\(p.personId)")
                }
            } footer: {
                if let r = store.refusal {
                    Text(TidyStore.message(r)).foregroundStyle(.red)
                } else if searched, results.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("No people match “\(query)”.")
                } else {
                    Text("Links \(item.handle?.value ?? item.name) to the person you choose in Prism.")
                }
            }
        }
    }
}

extension CommsTidyItem.Suggestion {
    /// Why the server suggests this person (review M9: a same-name match is only a guess).
    var reasonText: String? {
        switch reason {
        case "same-handle": "Has this number or account"
        case "same-name": "Same name, different number"
        default: nil
        }
    }
}
