import CommsClient
import CommsCore
import SwiftUI

/// The Details inspector (UX spec §9), Messages 26's contact card: avatar and title, the
/// call / video / mail actions (DMs), the person's phones and emails, a group's members
/// (a member Prism knows opens their card, pushed), the networks the conversation runs on,
/// "Conversations" (every other chat shared with the person) and Photos / Links tabs built
/// from the messages already loaded. Toggled by the name pill or ⌥⌘I (see `TranscriptHeader`).
public struct InspectorView: View {
    /// The thread's own contact united with the person's (never fewer options than the toolbar).
    static func contact(thread: CommsContact?, person: CommsPerson?) -> CommsContact? {
        guard let person else { return thread }
        return (thread ?? CommsContact()).merged(with: person.contact)
    }

    let thread: CommsThread?
    let members: [CommsMember]
    let messages: [CommsMessage]
    let contact: CommsContact?

    @State private var person: CommsPerson?

    public init(thread: CommsThread?, members: [CommsMember], messages: [CommsMessage], contact: CommsContact? = nil) {
        self.thread = thread
        self.members = members
        self.messages = messages
        self.contact = contact
    }

    public var body: some View {
        DetailsStack(threadID: thread?.id) {
            ScrollView {
                InspectorContent(thread: thread, members: members, messages: messages,
                                 contact: Self.contact(thread: contact, person: person),
                                 shared: (person?.threads ?? []).filter { $0.id != thread?.id })
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .modifier(ThreadPersonLoader(personID: thread?.kind == .dm ? thread?.personId : nil, person: $person))
        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        .accessibilityIdentifier("inspector")
    }
}

/// The inspector's content without the scroll view (the design gallery and snapshots render
/// it as an image).
struct InspectorContent: View {
    let thread: CommsThread?
    let members: [CommsMember]
    let messages: [CommsMessage]
    var contact: CommsContact?
    /// Other conversations shared with the DM's person.
    var shared: [CommsThread] = []
    var initialTab: InspectorTab = .photos

    @State private var tab: InspectorTab?

    var body: some View {
        let tab = tab ?? initialTab
        let isGroup = thread?.kind == .group
        VStack(spacing: 10) {
            AvatarView(thread?.avatar, kind: thread?.kind ?? .dm, size: 72, badge: thread?.networks.first, name: thread?.title)
                .padding(.top, 20)
                .accessibilityHidden(true)
            Text(thread?.title ?? "")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("details-title")
            if thread != nil, !isGroup {
                ContactActionRow(contact: contact, networks: thread?.networks ?? [])
                    .padding(.top, 4)
            }
            if !isGroup, let thread {
                WhoIsThisCard(thread: thread).padding(.top, 8)
            }
            if !isGroup, let contact, !ContactPointRows.rows(contact).isEmpty {
                DetailsSection(id: "details-contact") { ContactPointRows(contact: contact) }
                    .padding(.top, 8)
            }
            if isGroup, !members.isEmpty {
                DetailsSection(title: "\(members.count) \(members.count == 1 ? "Member" : "Members")", id: "details-members") {
                    MemberRows(members: members)
                }
                .padding(.top, 8)
            }
            if !channelRows.isEmpty {
                ChannelRows(rows: channelRows)
                    .padding(.top, 8)
            }
            if !shared.isEmpty {
                DetailsSection(title: "Conversations", id: "details-conversations") { SharedConversationRows(threads: shared) }
                    .padding(.top, 8)
            }
            InspectorTabs(selection: Binding(get: { tab }, set: { self.tab = $0 }))
                .padding(.top, 12)
            switch tab {
            case .photos: PhotosGrid(items: mediaItems(from: messages))
            case .links: LinksList(items: linkItems(from: messages))
            }
        }
    }

    /// One row per channel (network, and the account when the server names one).
    private var channelRows: [ChannelRows.Row] {
        guard let thread else { return [] }
        if !thread.channels.isEmpty {
            return thread.channels.map { .init(network: $0.network, account: $0.accountLabel) }
        }
        return thread.networks.map { .init(network: $0, account: nil) }
    }
}

struct MembersGrid: View {
    let members: [CommsMember]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(members.count) \(members.count == 1 ? "Member" : "Members")")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: 8, alignment: .top)], spacing: 10) {
                ForEach(members) { member in
                    VStack(spacing: 4) {
                        AvatarView(member.avatar, size: 40, name: member.name)
                        Text(member.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChannelRows: View {
    struct Row: Identifiable {
        let network: CommsNetwork
        let account: String?
        var id: String { "\(network.wire)|\(account ?? "")" }
    }

    let rows: [Row]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack {
                    Text(row.network.displayName)
                    Spacer()
                    if let account = row.account {
                        Text(account).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.callout)
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                if row.id != rows.last?.id { Divider() }
            }
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

struct PhotosGrid: View {
    let items: [CommsAttachment]

    var body: some View {
        if items.isEmpty {
            EmptyTab(text: "No Photos")
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button { MediaViewer.shared.open(item) } label: {
                        MediaImageView(token: item.thumbToken ?? item.mediaToken, placeholder: .secondary.opacity(0.2))
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .overlay(alignment: .bottomTrailing) {
                                if item.kind == .video {
                                    Image(systemName: "play.fill").font(.caption2).foregroundStyle(.white).padding(4)
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.kind == .video ? "Video" : "Photo")
                    .accessibilityHint(MediaViewer.openHint)
                }
            }
        }
    }
}

struct LinksList: View {
    let items: [CommsLinkPreview]
    @Environment(\.openURL) private var openURL

    var body: some View {
        if items.isEmpty {
            EmptyTab(text: "No Links")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items, id: \.url) { link in
                    Button {
                        if let url = URL(string: link.url), ["http", "https"].contains(url.scheme?.lowercased()) { openURL(url) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(link.title ?? link.siteName ?? link.url).font(.callout.weight(.medium)).lineLimit(2)
                            Text(link.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(link.title ?? link.siteName ?? link.url)
                    .accessibilityValue(link.url)
                    .accessibilityHint("Opens the link in your browser")
                }
            }
        }
    }
}

struct EmptyTab: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.top, 16)
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case photos = "Photos", links = "Links"
    var id: String { rawValue }
}

/// Apple's Details tabs: plain labels, the selected one in a soft capsule.
struct InspectorTabs: View {
    @Binding var selection: InspectorTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(InspectorTab.allCases) { tab in
                Button { selection = tab } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(selection == tab ? Color.primary.opacity(0.08) : .clear))
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shared media")
        .accessibilityAddTraits(.isTabBar)
    }
}
