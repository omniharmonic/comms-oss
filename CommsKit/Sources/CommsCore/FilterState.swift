import CommsClient
import Foundation

/// The conversation list's filter, Messages-style: one folder (mutually exclusive) plus the
/// stackable "Filter By" choices — Unread, any number of networks, any number of Prism triage
/// statuses ("Needs attention" is a preset for Urgent + Action required). Every choice in a
/// group widens it (networks OR, statuses OR); the groups narrow each other (AND). Maps 1:1
/// onto `GET /threads` parameters (repeated `network=` / `status=`).
public struct FilterState: Equatable, Sendable {
    public var folder: CommsFolder = .inbox
    public var unread = false
    /// Shown when the thread is on ANY of these networks (empty = all networks).
    public var networks: Set<CommsNetwork> = []
    /// Shown when the thread's triage status is ANY of these (empty = any status).
    public var statuses: Set<CommsThreadStatus> = []
    /// The owner folder this page shows (sprint Task 9); nil = the home page ("Comms": `folder`).
    /// A folder page lists the folder's conversations in every system folder but Archived and Spam.
    public var chatFolder: String?

    public init(folder: CommsFolder = .inbox, unread: Bool = false, networks: Set<CommsNetwork> = [],
                statuses: Set<CommsThreadStatus> = [], triage: TriageFilter? = nil) {
        self.folder = folder
        self.unread = unread
        self.networks = networks
        self.statuses = statuses.union(triage?.members ?? [])
    }

    /// Whether any "Filter By" choice is on (the Filter button tints blue). A folder alone is not filtering.
    public var isFiltering: Bool { unread || !networks.isEmpty || !statuses.isEmpty }

    /// The folders in menu order; ⌃⌘1–5 select them.
    public static let folders: [CommsFolder] = [.inbox, .strangers, .low, .spam, .archived]

    // MARK: Triage choices

    /// The menu's checkmark for `option`: a status when it is chosen; Needs attention when
    /// both its statuses are.
    public func isOn(_ option: TriageFilter) -> Bool {
        let m = option.members
        return !m.isEmpty && m.isSubset(of: statuses)
    }

    /// Turn a triage choice on or off (others stay: multi-select).
    public mutating func set(_ option: TriageFilter, _ on: Bool) {
        if on { statuses.formUnion(option.members) } else { statuses.subtract(option.members) }
    }

    /// Turn a network on or off (others stay: multi-select).
    public mutating func set(_ network: CommsNetwork, _ on: Bool) {
        if on { networks.insert(network) } else { networks.remove(network) }
    }

    /// Clear every Filter By choice; the folder stays.
    public mutating func clearFilters() {
        unread = false
        networks = []
        statuses = []
    }

    /// The server query for this filter. Networks and statuses are sorted so equal filters
    /// send equal queries; the Needs-attention pair goes as `attention=true` (the server
    /// merges it into the same set).
    public func query(cursor: String? = nil, limit: Int? = nil) -> CommsThreadQuery {
        let attention = isOn(.needsAttention)
        let rest = attention ? statuses.subtracting(CommsThreadStatus.needsAttention) : statuses
        return CommsThreadQuery(
            folder: folder,
            unreadOnly: unread,
            networks: networks.sorted { $0.wire < $1.wire },
            statuses: Self.ordered(rest),
            attention: attention,
            anyFolder: chatFolder != nil,
            cursor: cursor,
            limit: limit,
            inFolder: chatFolder
        )
    }

    /// Whether a thread belongs in the list under this filter (used for live upserts).
    public func admits(_ thread: CommsThread) -> Bool {
        if let chatFolder {
            guard thread.folderIds?.contains(chatFolder) == true, thread.folder != .archived, thread.folder != .spam else { return false }
        } else {
            guard thread.folder == folder else { return false }
        }
        if !networks.isEmpty, networks.isDisjoint(with: thread.networks) { return false }
        if !statuses.isEmpty {
            // A thread without a status (older server) or with one we don't know never passes.
            guard let s = thread.status, statuses.contains(s) else { return false }
        }
        return true
    }

    /// What the list is filtered by, in menu order ("Needs attention, Social, Unread,
    /// Telegram, WhatsApp"); nil when nothing is. `networkName` names a network (the UI passes
    /// its display names).
    public func summary(networkName: (CommsNetwork) -> String) -> String? {
        var parts: [String] = []
        var rest = statuses
        if isOn(.needsAttention) {
            parts.append(TriageFilter.needsAttention.label)
            rest.subtract(CommsThreadStatus.needsAttention)
        }
        parts += Self.ordered(rest).map(\.label)
        if unread { parts.append("Unread") }
        parts += networks.map(networkName).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Statuses in Prism's order (unknown ones last, by wire value).
    static func ordered(_ set: Set<CommsThreadStatus>) -> [CommsThreadStatus] {
        let order = Dictionary(CommsThreadStatus.ordered.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return set.sorted { a, b in
            let x = order[a] ?? Int.max, y = order[b] ?? Int.max
            return x != y ? x < y : a.wire < b.wire
        }
    }
}

/// One choice of the Filter menu's triage section: Prism's "Needs attention" set or a single
/// status (Prism's `triage.ts` labels).
public enum TriageFilter: Hashable, Sendable {
    case needsAttention
    case status(CommsThreadStatus)

    /// The menu, in Prism's order. "Couldn’t classify" and "Reviewed" are left out of the
    /// filter (owner's list, 2026-11-22); they still decode and admit as statuses.
    public static let menu: [TriageFilter] = [
        .needsAttention, .status(.urgent), .status(.actionRequired), .status(.unclassified),
        .status(.informational), .status(.low), .status(.social), .status(.handled),
    ]

    public var label: String {
        switch self {
        case .needsAttention: CommsThreadStatus.needsAttentionLabel
        case .status(let s): s.label
        }
    }

    /// The statuses this choice stands for (Needs attention = Urgent + Action required).
    public var members: Set<CommsThreadStatus> {
        switch self {
        case .needsAttention: Set(CommsThreadStatus.needsAttention)
        case .status(let s): [s]
        }
    }

    /// Whether a thread with this status passes (a thread without one never does).
    public func admits(_ status: CommsThreadStatus?) -> Bool {
        guard let status else { return false }
        switch self {
        case .needsAttention: return status.needsAttention
        case .status(let s): return s == status
        }
    }
}
