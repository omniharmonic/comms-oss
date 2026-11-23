#if os(iOS)
import CommsClient
import CommsCore
import SwiftUI

/// Details on iPhone and iPad (a sheet on iPhone, the inspector column on iPad), laid out
/// like Messages' contact card (design/fidelity/apple-ios/details-light.png): a large
/// avatar, the title, the grey action circles (call and video open menus of every way to
/// reach the person; mail opens Mail), then grouped cards: phones and emails, a group's
/// members (a member Prism knows opens their card, pushed), the networks, and
/// "Conversations" — every other chat shared with the person.
/// Info / Photos / Links come from the thread and the messages already loaded.
public struct PhoneDetailsView: View {
    let thread: CommsThread?
    let members: [CommsMember]
    let messages: [CommsMessage]
    let contact: CommsContact?
    let accessory: AnyView?
    let close: () -> Void
    /// Preloaded person (snapshots); nil = loaded through `\.peopleDirectory`.
    let preloadedPerson: CommsPerson?

    @State private var tab: Tab = .info
    @State private var person: CommsPerson?

    enum Tab: String, CaseIterable, Identifiable {
        case info = "Info", photos = "Photos", links = "Links"
        var id: String { rawValue }
    }

    public init(thread: CommsThread?, members: [CommsMember], messages: [CommsMessage], contact: CommsContact? = nil,
                accessory: AnyView? = nil, preloadedPerson: CommsPerson? = nil, close: @escaping () -> Void) {
        self.thread = thread
        self.members = members
        self.messages = messages
        self.contact = contact
        self.accessory = accessory
        self.preloadedPerson = preloadedPerson
        self.close = close
    }

    private var currentPerson: CommsPerson? { preloadedPerson ?? person }
    private var effectiveContact: CommsContact? { InspectorView.contact(thread: contact, person: currentPerson) }
    private var shared: [CommsThread] { (currentPerson?.threads ?? []).filter { $0.id != thread?.id } }

    public var body: some View {
        DetailsStack(threadID: thread?.id) { card }
        .modifier(ThreadPersonLoader(personID: preloadedPerson == nil && thread?.kind == .dm ? thread?.personId : nil, person: $person))
    }

    private var card: some View {
        ScrollView {
            VStack(spacing: 0) {
                AvatarView(thread?.avatar, kind: thread?.kind ?? .dm, size: 80, badge: thread?.networks.first, name: thread?.title)
                    .padding(.top, 28)
                    .accessibilityHidden(true)
                Text(thread?.title ?? "")
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 10)
                    .padding(.horizontal, 24)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("details-title")
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 24).padding(.top, 2)
                }
                actions.padding(.top, 18)
                Divider().padding(.top, 22)
                Picker("Details", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .accessibilityIdentifier("details-tabs")
                Group {
                    switch tab {
                    case .info: info
                    case .photos: PhotosGrid(items: mediaItems(from: messages)).padding(.top, 4)
                    case .links: LinksList(items: linkItems(from: messages)).padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                if let accessory { accessory.padding(.top, 24) }
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("inspector")
        // Photos open in Quick Look over this sheet (the transcript's viewer sits under it).
        .mediaViewer()
        .overlay(alignment: .topLeading) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(.leading, 16)
            .padding(.top, 16)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("details-close")
        }
    }

    /// Messages' grey line under the name: the member count of a group, preceded by the
    /// account the thread lives in when the server names one (the Slack workspace, which
    /// tells two `#general` channels apart).
    var subtitle: String? {
        guard let thread else { return nil }
        var parts: [String] = []
        if let account = thread.accountLabel { parts.append(account) }
        if thread.kind == .group, !members.isEmpty {
            parts.append("\(members.count) \(members.count == 1 ? "Member" : "Members")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Messages' grey 56 pt circles (call, video, mail): menus of every way to reach the
    /// person; dimmed when there is none (and for groups).
    private var actions: some View {
        ContactActionRow(contact: thread?.kind == .group ? nil : effectiveContact, networks: thread?.networks ?? [])
    }

    @ViewBuilder private var info: some View {
        VStack(spacing: 16) {
            if let thread, thread.kind != .group { WhoIsThisCard(thread: thread) }
            if thread?.kind != .group, let contact = effectiveContact, !ContactPointRows.rows(contact).isEmpty {
                DetailsSection(id: "details-contact") { ContactPointRows(contact: contact) }
            }
            let rows = channelRows
            if !rows.isEmpty {
                DetailsCard {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.account == nil ? "network" : row.network.displayName.lowercased())
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(row.account ?? row.network.displayName).font(.body)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 11)
                        .accessibilityElement(children: .combine)
                        if i < rows.count - 1 { Divider() }
                    }
                }
            }
            if let thread, thread.kind == .group, !members.isEmpty {
                DetailsSection(title: "\(members.count) \(members.count == 1 ? "Member" : "Members")", id: "details-members") {
                    MemberRows(members: members)
                }
            }
            if !shared.isEmpty {
                DetailsSection(title: "Conversations", id: "details-conversations") { SharedConversationRows(threads: shared) }
            }
        }
    }

    private var channelRows: [ChannelRows.Row] {
        guard let thread else { return [] }
        if !thread.channels.isEmpty { return thread.channels.map { .init(network: $0.network, account: $0.accountLabel) } }
        return thread.networks.map { .init(network: $0, account: nil) }
    }
}

/// A grouped card: Messages' rounded grey panel, 26 pt corners, 16 pt insets.
struct DetailsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 16)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 26))
    }
}

#endif
