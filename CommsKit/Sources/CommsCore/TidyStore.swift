import CommsClient
import Foundation
import Observation

/// Contact tidy-up (D17, PRD §5.11a): "People to tidy" (DM counterparts the vault has no
/// person for, most talked-to first) and the "Who is this?" choices — link to a person,
/// create one, or ignore — each undoable. Every write is the owner's explicit tap; the server
/// refuses a handle someone else holds and never merges people.
@MainActor @Observable
public final class TidyStore {
    private let backend: any ChatBackend

    public private(set) var people: [CommsTidyItem] = []
    public private(set) var total = 0
    public private(set) var isLoading = false
    public private(set) var error: String?
    /// The "Who is this?" prompt per DM (loaded when Details opens).
    public private(set) var prompts: [String: CommsTidyItem] = [:]
    /// The last thing done (the Undo banner); nil after an undo.
    public private(set) var lastAction: CommsTidyAction?
    /// Why the last action was refused (people with that name exist, the number is someone
    /// else's, …), for the UI to offer the next step.
    public private(set) var refusal: CommsTidyRefusal?
    public private(set) var isWorking = false

    @ObservationIgnored private var next: String?

    public init(backend: any ChatBackend) { self.backend = backend }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await backend.tidyList(cursor: nil, limit: 30)
            people = page.people
            total = page.total
            next = page.next
            error = nil
        } catch {
            self.error = "People to tidy couldn't be loaded."
        }
    }

    public var hasMore: Bool { next != nil }

    public func loadMore() async {
        guard let cursor = next, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let page = try? await backend.tidyList(cursor: cursor, limit: 30) {
            let seen = Set(people.map(\.id))
            people += page.people.filter { !seen.contains($0.id) }
            next = page.next
        }
    }

    /// Loads the "Who is this?" prompt for a DM (nil = nothing to ask).
    @discardableResult
    public func loadPrompt(threadID: String) async -> CommsTidyItem? {
        askedPrompts.insert(threadID)
        let item = try? await backend.tidyItem(threadID: threadID)
        prompts[threadID] = item
        return item
    }

    public func link(threadID: String, personID: String) async -> Bool {
        await run(threadID: threadID) { try await self.backend.tidyLink(threadID: threadID, personID: personID) }
    }

    public func create(threadID: String, name: String, allowSimilar: Bool = false) async -> Bool {
        await run(threadID: threadID) { try await self.backend.tidyCreate(threadID: threadID, name: name, allowSimilar: allowSimilar) }
    }

    public func ignore(threadID: String) async -> Bool {
        await run(threadID: threadID) { try await self.backend.tidyIgnore(threadID: threadID) }
    }

    /// Undo the last action; the prompt comes back for that conversation.
    public func undo() async -> Bool {
        guard let action = lastAction else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await backend.tidyUndo(actionID: action.id)
            lastAction = nil
            refusal = nil
            await loadPrompt(threadID: action.threadId)
            await load()
            return true
        } catch let r as CommsTidyRefusal {
            refusal = r
            return false
        } catch {
            refusal = .other("failed")
            return false
        }
    }

    public func dismissRefusal() { refusal = nil }

    /// The live stream: a tidy decision made on ANY device (`thread.updated`, reason `tidy`) —
    /// that conversation leaves People to Tidy here too, its prompt is re-asked, and the list and
    /// count are refreshed (coalesced: one reload for a burst). Owner-testing round 4.
    @discardableResult
    public func apply(_ event: CommsEvent) -> Task<Void, Never>? {
        guard event.kind == .threadUpdated, event.payload["reason"]?.stringValue == "tidy" else { return nil }
        if let id = event.threadID, askedPrompts.contains(id) {
            Task { await self.loadPrompt(threadID: id) }
        }
        return scheduleReload()
    }

    /// Reload the list (and count) after `reloadDelay`, once for any number of calls meanwhile.
    /// The app also calls it when it comes back to the foreground.
    @discardableResult
    public func scheduleReload() -> Task<Void, Never> {
        if let pendingReload { return pendingReload }
        let delay = reloadDelay
        let t = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.pendingReload = nil
            await self.load()
        }
        pendingReload = t
        return t
    }
    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    /// Conversations whose "Who is this?" prompt was asked on this device.
    @ObservationIgnored private var askedPrompts: Set<String> = []
    /// How long tidy events are collected before one reload.
    @ObservationIgnored public var reloadDelay: Duration = .milliseconds(400)

    /// People to link to by name (review I5): the vault people matching `query` (the same
    /// directory the New Message To: field searches). Contacts-only entries are not people yet.
    public func searchPeople(_ query: String) async -> [CommsTidyItem.Suggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count <= 100, let r = try? await backend.recipients(query: q, limit: 20) else { return [] }
        var seen = Set<String>()
        return r.people.compactMap { p in
            guard let id = p.personId, seen.insert(id).inserted else { return nil }
            return CommsTidyItem.Suggestion(personId: id, name: p.name, reason: "search")
        }
    }

    private func run(threadID: String, _ op: @escaping () async throws -> CommsTidyResult) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        refusal = nil
        do {
            let r = try await op()
            lastAction = r.action
            prompts[threadID] = nil
            people.removeAll { $0.threadId == threadID }
            total = max(0, total - 1)
            return true
        } catch let r as CommsTidyRefusal {
            refusal = r
            return false
        } catch {
            refusal = .other("failed")
            return false
        }
    }

    /// The sentence for a refusal.
    public static func message(_ r: CommsTidyRefusal) -> String {
        switch r {
        case .similarPeople(let p): p.count == 1 ? "\(p[0].name) is already in your people. Is it the same person?" : "People with that name are already in your people."
        case .claimedByAnotherPerson(let p): "This number or account already belongs to \(p.name)."
        case .changedSince: "This person was changed since, so it can't be undone here. Edit them in Prism."
        case .alreadyDone: "That's already done."
        case .invalidName: "Enter a real name."
        case .disabled: "Contact tidy-up is turned off on the server."
        // The server's safety refusals (people cleanup): say why, not "try again".
        case .other("not_one_counterpart"): "This conversation has more than one other person in it, so it can't be linked to one contact. Link the people in Prism."
        case .other("owner_person"): "That's you. Your own number or account isn't linked as a contact."
        case .other("changed_since_plan"): "This person was changed since. Look again and try once more."
        case .other: "That didn't work. Try again."
        }
    }
}
