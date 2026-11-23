import CommsClient
import CommsCore
import SwiftUI

// Messages-style search results (PRD §5.6): token suggestions ("Messages with Ann",
// "Messages in Trail Crew"), the matching conversations as a row of avatars, the matching
// messages as real bubbles with the searched words highlighted, and Links / Photos with
// "See All". Search runs on Prism over every message (D12); Photos and Links cover ~90 days.

/// An action that opens a conversation from search (the Mac selection, the iOS push).
public struct SearchOpenAction: Sendable {
    let action: @MainActor @Sendable (String) -> Void
    public init(_ action: @escaping @MainActor @Sendable (String) -> Void) { self.action = action }
    @MainActor func callAsFunction(_ id: String) { action(id) }
}

struct SearchResultsView: View {
    @Bindable var search: MessageSearchStore
    /// The list's own matches (titles and last messages): the "Conversations" row.
    let conversations: [CommsThread]
    let now: Date
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(search.suggestedTokens) { token in
                Button { search.add(token) } label: {
                    Label(token.suggestion, systemImage: token.systemImage)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, SearchMetrics.inset)
                .accessibilityIdentifier("search-token-suggestion")
            }
            if search.scope == .all {
                if !conversations.isEmpty {
                    SearchSectionHeader(title: "Conversations")
                    ConversationStrip(threads: Array(conversations.prefix(12)), open: open)
                }
                messages
                if !search.links.isEmpty {
                    SearchSectionHeader(title: "Links", seeAll: search.links.count > 3 ? { search.scope = .links } : nil)
                    SearchLinkRows(items: Array(search.links.prefix(3)), threads: search.threads, open: open)
                }
                if !search.photos.isEmpty {
                    SearchSectionHeader(title: "Photos", seeAll: search.photos.count > 6 ? { search.scope = .photos } : nil)
                    SearchPhotoGrid(items: Array(search.photos.prefix(6)))
                }
            } else {
                HStack {
                    Button { search.scope = .all } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("search-scope-back")
                    Spacer()
                }
                .padding(.horizontal, SearchMetrics.inset)
                .padding(.vertical, 6)
                SearchSectionHeader(title: search.scope.rawValue)
                if search.scope == .links {
                    if search.links.isEmpty { emptyLine("No Links") }
                    SearchLinkRows(items: search.links, threads: search.threads, open: open)
                } else {
                    if search.photos.isEmpty { emptyLine("No Photos") }
                    SearchPhotoGrid(items: search.photos)
                }
            }
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-results")
    }

    @ViewBuilder private var messages: some View {
        if !search.hits.isEmpty {
            SearchSectionHeader(title: "Messages")
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(search.hits.enumerated()), id: \.element.id) { i, hit in
                    SearchHitRow(hit: hit, thread: search.threads[hit.threadId], now: now)
                        .contentShape(.rect)
                        .onTapGesture { open(hit.threadId) }
                        .accessibilityAction { open(hit.threadId) }
                        .accessibilityIdentifier("search-hit-\(i)")
                        .onAppear { if i == search.hits.count - 1 { Task { await search.loadMore() } } }
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if search.isSearching {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16).accessibilityLabel("Searching")
        } else if let error = search.error {
            emptyLine(error)
        } else if search.scope == .all, !search.term.isEmpty, search.hits.isEmpty, conversations.isEmpty, search.links.isEmpty {
            Text("No Results").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
                .accessibilityIdentifier("search-no-results")
        }
        if search.isPartial, !search.hits.isEmpty {
            Text("Showing the most recent matches. Add a word to narrow the search.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                .padding(.horizontal, SearchMetrics.inset).padding(.vertical, 8)
        }
        if search.historyPending > 0, !search.term.isEmpty {
            Text("Older messages are still being added to search.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                .padding(.horizontal, SearchMetrics.inset).padding(.vertical, 12)
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(16)
    }
}

enum SearchMetrics {
    #if os(iOS)
    static let inset: CGFloat = 20
    static let avatar: CGFloat = 40
    static let stripAvatar: CGFloat = 56
    #else
    static let inset: CGFloat = 12
    static let avatar: CGFloat = 32
    static let stripAvatar: CGFloat = 44
    #endif
}

struct SearchSectionHeader: View {
    let title: String
    var seeAll: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                #if os(iOS)
                .font(.title3.weight(.bold))
                #else
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                #endif
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let seeAll {
                Button("See All", action: seeAll)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("search-see-all-\(title.lowercased())")
            }
        }
        .padding(.horizontal, SearchMetrics.inset)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

/// Messages' "Conversations" row: avatars with the name under each.
struct ConversationStrip: View {
    let threads: [CommsThread]
    let open: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(threads) { t in
                    Button { open(t.id) } label: {
                        VStack(spacing: 5) {
                            AvatarView(t.avatar, kind: t.kind, size: SearchMetrics.stripAvatar, badge: t.networks.first, name: t.title)
                            Text(t.title).font(.caption).lineLimit(1).frame(width: SearchMetrics.stripAvatar + 16)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    // As a list row reads ("<title>, …"), so VoiceOver and the UI tests find it the same way.
                    .accessibilityLabel("\(t.title), conversation")
                    .accessibilityIdentifier("search-conversation-\(t.id)")
                }
            }
            .padding(.horizontal, SearchMetrics.inset)
        }
    }
}

/// One matching message: the conversation's avatar, name and date, then the message as a real
/// bubble (grey incoming, the network's blue outgoing) with the searched words in bold.
struct SearchHitRow: View {
    let hit: CommsSearchHit
    let thread: CommsThread?
    let now: Date

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(thread?.avatar, kind: thread?.kind ?? .dm, size: SearchMetrics.avatar, badge: thread?.networks.first, name: thread?.title)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread?.title ?? "Conversation").font(.headline).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(RelativeStamp.text(hit.sentAt, now: now)).font(.subheadline).foregroundStyle(.secondary)
                }
                if thread?.kind == .group || hit.sender.isSelf {
                    Text(hit.sender.isSelf ? "You" : hit.sender.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                SearchHitBubble(text: hit.text, highlights: hit.highlights, outgoing: hit.sender.isSelf,
                                network: thread?.networks.first ?? .unknown(""))
            }
        }
        .padding(.horizontal, SearchMetrics.inset)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(thread?.title ?? "Conversation"), \(hit.sender.isSelf ? "You" : hit.sender.name): \(hit.text)")
        .accessibilityValue(RelativeStamp.text(hit.sentAt, now: now))
        .accessibilityHint("Opens the conversation")
        .accessibilityAddTraits(.isButton)
    }
}

/// The hit's text in a Messages bubble (with its tail), highlighted words bold.
struct SearchHitBubble: View {
    let text: String
    let highlights: [CommsTextRange]
    let outgoing: Bool
    let network: CommsNetwork

    @Environment(\.bubbleMetrics) private var metrics
    @Environment(\.colorScheme) private var scheme

    static func attributed(_ text: String, highlights: [CommsTextRange]) -> AttributedString {
        var out = AttributedString(text)
        let ns = text as NSString
        for h in highlights where h.start >= 0 && h.length > 0 && h.start + h.length <= ns.length {
            guard let r = Range(NSRange(location: h.start, length: h.length), in: text),
                  let a = AttributedString.Index(r.lowerBound, within: out),
                  let b = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[a..<b].inlinePresentationIntent = .stronglyEmphasized
        }
        return out
    }

    var body: some View {
        let fill: BubbleFill = outgoing ? .outgoing(Tokens.color.outgoingByNetwork.shade(for: network)) : .incoming
        let shape = BubbleShape(tail: true, outgoing: outgoing, radius: metrics.radius)
        Text(Self.attributed(text, highlights: highlights))
            .font(.system(size: metrics.bodySize))
            .foregroundStyle(BubblePalette(scheme: scheme).text(outgoing: outgoing))
            .lineLimit(4)
            .padding(.horizontal, metrics.padH)
            .padding(.vertical, metrics.padV)
            .background { BubbleFillView(shape: shape, fill: fill) }
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }
}

struct SearchLinkRows: View {
    let items: [CommsMediaItem]
    let threads: [String: CommsThread]
    let open: (String) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if let link = item.link {
                    Button {
                        if let url = URL(string: link.url), ["http", "https"].contains(url.scheme?.lowercased()) { openURL(url) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "link")
                                .frame(width: SearchMetrics.avatar, height: SearchMetrics.avatar)
                                .background(.quaternary, in: .rect(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(link.title ?? link.siteName ?? link.url).font(.callout.weight(.medium)).lineLimit(1)
                                Text(URL(string: link.url)?.host() ?? link.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, SearchMetrics.inset)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Show in Conversation") { open(item.threadId) } }
                    .accessibilityLabel(link.title ?? link.siteName ?? link.url)
                    .accessibilityValue(link.url)
                    .accessibilityHint("Opens the link in your browser")
                }
            }
        }
    }
}

struct SearchPhotoGrid: View {
    let items: [CommsMediaItem]

    var body: some View {
        PhotosGrid(items: items.compactMap(\.attachment))
            .padding(.horizontal, SearchMetrics.inset)
    }
}

/// "9:41 AM" today, "Yesterday", the weekday this week, else the short date (Messages' list rule).
enum RelativeStamp {
    static func text(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
