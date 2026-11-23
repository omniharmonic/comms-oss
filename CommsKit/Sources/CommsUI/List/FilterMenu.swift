import CommsClient
import CommsCore
import SwiftUI

/// The sidebar's Filter button and menu (UX spec §4, Mac §9): the folders (single-select,
/// ⌃⌘1–5), then "Filter By" › Unread, Status › and Network › (both multi-select, with
/// "Any Status" / "All Networks" first). The glyph turns accent-blue while any
/// Filter By toggle is on. In a toolbar the system draws the glass button and morphs the menu
/// out of it.
public struct FilterMenu: View {
    @Binding var filter: FilterState
    /// People to Tidy (iOS: a Filter folder, PRD §5.11a); nil or 0 hides it.
    var tidyCount: Int = 0
    var onTidy: (() -> Void)?

    public init(filter: Binding<FilterState>, tidyCount: Int = 0, onTidy: (() -> Void)? = nil) {
        _filter = filter
        self.tidyCount = tidyCount
        self.onTidy = onTidy
    }

    /// Networks offered under Filter By › Network.
    static let networks: [CommsNetwork] = [.imessage, .sms, .whatsapp, .telegram, .messenger, .instagram, .signal, .slack, .linkedin, .discord, .x, .email, .matrix]

    public var body: some View {
        Menu {
            Section {
                ForEach(Array(FilterState.folders.enumerated()), id: \.offset) { _, folder in
                    Toggle(isOn: Binding(get: { filter.folder == folder && filter.chatFolder == nil }, set: { if $0 { filter.folder = folder; filter.chatFolder = nil } })) {
                        Label(folder.title, systemImage: folder.symbol)
                    }
                    // ⌃⌘1–5 are registered once, by `FolderShortcuts` (registering them here
                    // too gave two key equivalents for one action).
                }
                if let onTidy, tidyCount > 0 {
                    Button(action: onTidy) {
                        Label("People to Tidy (\(tidyCount))", systemImage: "person.crop.circle.badge.questionmark")
                    }
                    .accessibilityIdentifier("filter-people-to-tidy")
                }
            }
            Section("Filter By") {
                Toggle(isOn: $filter.unread) { Label("Unread", systemImage: "message.badge") }
                    .keepsMenuOpen()
                Menu {
                    // Multi-select: every status chosen is shown (OR). "Any Status" clears them.
                    Toggle(isOn: Binding(get: { filter.statuses.isEmpty }, set: { if $0 { filter.statuses = [] } })) {
                        Label("Any Status", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .keepsMenuOpen()
                    .accessibilityIdentifier("filter-status-any")
                    Divider()
                    ForEach(TriageFilter.menu, id: \.self) { option in
                        Toggle(isOn: triageBinding(option)) { Label(option.label, systemImage: option.symbol) }
                            .keepsMenuOpen()
                        if option == .needsAttention { Divider() }
                    }
                } label: {
                    Label("Status", systemImage: "flag")
                }
                .accessibilityIdentifier("filter-status")
                Menu {
                    // Multi-select: every network chosen is shown (OR). "All Networks" first.
                    Toggle(isOn: Binding(get: { filter.networks.isEmpty }, set: { if $0 { filter.networks = [] } })) {
                        Label("All Networks", systemImage: "square.grid.2x2")
                    }
                    .keepsMenuOpen()
                    .accessibilityIdentifier("filter-network-all")
                    Divider()
                    ForEach(Self.networks, id: \.wire) { network in
                        Toggle(isOn: networkBinding(network)) { Label(network.title, systemImage: network.symbol) }
                            .keepsMenuOpen()
                    }
                } label: {
                    Label("Network", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .accessibilityIdentifier("filter-network")
            }
        } label: {
            FilterMenuLabel(isFiltering: filter.isFiltering)
        }
        .menuIndicator(.hidden)
        .help("Filter")
        .accessibilityLabel(filter.isFiltering ? "Filter, on" : "Filter")
        .accessibilityIdentifier("filter-button")
    }

    private func triageBinding(_ option: TriageFilter) -> Binding<Bool> {
        Binding(get: { filter.isOn(option) }, set: { filter.set(option, $0) })
    }

    private func networkBinding(_ network: CommsNetwork) -> Binding<Bool> {
        Binding(get: { filter.networks.contains(network) }, set: { filter.set(network, $0) })
    }
}

extension View {
    /// iOS: a Filter By toggle leaves the menu open, so several can be chosen in one go (as
    /// Mail's filter menu does). macOS menus always close on a choice.
    @ViewBuilder func keepsMenuOpen() -> some View {
        #if os(iOS)
        menuActionDismissBehavior(.disabled)
        #else
        self
        #endif
    }
}

/// The Filter glyph (`line.3.horizontal.decrease`), accent-blue while filtering.
public struct FilterMenuLabel: View {
    let isFiltering: Bool
    public init(isFiltering: Bool) { self.isFiltering = isFiltering }

    public var body: some View {
        Image(systemName: "line.3.horizontal.decrease")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isFiltering ? AnyShapeStyle(ListMetrics.accent) : AnyShapeStyle(.primary))
    }
}

/// ⌃⌘1–5 select the folders while the sidebar is on screen: the only registration of these
/// shortcuts (the menu items carry none). Invisible; place it in a background.
struct FolderShortcuts: View {
    @Binding var filter: FilterState

    static func key(_ index: Int) -> KeyEquivalent { KeyEquivalent(Character("\(index + 1)")) }

    var body: some View {
        ZStack {
            ForEach(Array(FilterState.folders.enumerated()), id: \.offset) { i, folder in
                Button(folder.title) { filter.folder = folder; filter.chatFolder = nil }
                    .keyboardShortcut(Self.key(i), modifiers: [.control, .command])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

extension CommsFolder {
    var title: String {
        switch self {
        // Brand consistency (owner, Task 9): the home page is "Comms".
        case .inbox: "Comms"
        case .strangers: "Unknown Senders"
        case .low: "Low Priority"
        case .spam: "Spam"
        case .archived: "Archived"
        case .unknown(let s): s.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "bubble.left.and.bubble.right"
        case .strangers: "person.crop.circle.badge.questionmark"
        case .low: "arrow.down.circle"
        case .spam: "xmark.bin"
        case .archived: "archivebox"
        case .unknown: "folder"
        }
    }
}

extension TriageFilter {
    /// SF Symbol for the menu row.
    var symbol: String {
        switch self {
        case .needsAttention: "exclamationmark.bubble"
        case .status(let s):
            switch s {
            case .urgent: "exclamationmark.triangle"
            case .actionRequired: "checklist"
            case .unclassified: "tray"
            case .triageFailed: "questionmark.circle"
            case .informational: "info.circle"
            case .low: "arrow.down.circle"
            case .social: "person.2"
            case .triaged: "eye"
            case .handled: "checkmark.circle"
            case .unknown: "flag"
            }
        }
    }
}

/// "Filtered by: Urgent, Unread" above the list while any Filter By choice is on (Mail's
/// filter caption, which Messages' list lacks a place for): the choices in the accent colour,
/// and a clear button that keeps the folder.
public struct FilterSummaryBar: View {
    @Binding var filter: FilterState
    /// People to Tidy (iOS: a Filter folder, PRD §5.11a); nil or 0 hides it.
    var tidyCount: Int = 0
    var onTidy: (() -> Void)?

    public init(filter: Binding<FilterState>, tidyCount: Int = 0, onTidy: (() -> Void)? = nil) {
        _filter = filter
        self.tidyCount = tidyCount
        self.onTidy = onTidy
    }

    public var body: some View {
        if let summary = filter.summary(networkName: \.displayName) {
            HStack(spacing: 6) {
                (Text("Filtered by: ").foregroundStyle(.secondary) + Text(summary).foregroundStyle(ListMetrics.accent))
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button {
                    withAnimation(.snappy) { filter.clearFilters() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Filters")
                .accessibilityIdentifier("filter-clear")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("filter-summary")
        }
    }
}
