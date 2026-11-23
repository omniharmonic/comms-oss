import CommsClient
import CommsCore
import SwiftUI

// The pieces of Messages' contact card shared by the Mac inspector, iOS Details and a
// member's pushed card: the call / video / mail actions, the person's phones and emails,
// a group's members and "Conversations" (every chat shared with the person).

// MARK: Environment

/// Loads a vault person (`GET /people/:id`) for contact cards. `.none` = people unavailable.
public struct PeopleDirectory: Sendable {
    public var load: @Sendable (String) async throws -> CommsPerson

    public init(load: @escaping @Sendable (String) async throws -> CommsPerson) { self.load = load }

    public static let none = PeopleDirectory { _ in throw CommsError.personUnavailable }
}

/// Opens a conversation by id (the Mac window's selection; the iOS navigation).
public struct OpenConversationAction: Sendable {
    let action: @MainActor @Sendable (String) -> Void

    public init(_ action: @escaping @MainActor @Sendable (String) -> Void) { self.action = action }

    @MainActor public func callAsFunction(_ id: String) { action(id) }

    public static let none = OpenConversationAction { _ in }
}

extension EnvironmentValues {
    @Entry public var peopleDirectory: PeopleDirectory = .none
    @Entry public var openConversation: OpenConversationAction = .none
    /// Pushes a person's card inside Details (`DetailsStack`).
    @Entry var showPerson: ShowPersonAction = .none
    /// The conversation Details belongs to (left out of a member card's Conversations).
    @Entry var detailsThreadID: String? = nil
}

struct ShowPersonAction: Sendable {
    let action: @MainActor @Sendable (PersonRoute) -> Void
    @MainActor func callAsFunction(_ route: PersonRoute) { action(route) }
    static let none = ShowPersonAction { _ in }
}

/// Details' own little navigation: a member's card slides in over the conversation's card,
/// with a back circle where the close circle was. Deliberately not a `NavigationStack`: a
/// stack inside the transcript's inspector (itself inside the app's stack) stopped the app's
/// own pushes on iPhone.
struct DetailsStack<Root: View>: View {
    var threadID: String?
    @ViewBuilder let root: Root
    @State private var stack: [PersonRoute] = []

    var body: some View {
        ZStack {
            root
                .opacity(stack.isEmpty ? 1 : 0)
                .allowsHitTesting(stack.isEmpty)
                .accessibilityHidden(!stack.isEmpty)
            if let top = stack.last {
                PersonCardView(route: top)
                    .padding(.top, Self.cardTop)
                    .overlay(alignment: .topLeading) { back }
                    .background(Self.background)
                    .id(top)
                    .transition(.move(edge: .trailing))
            }
        }
        .environment(\.detailsThreadID, threadID)
        .environment(\.showPerson, ShowPersonAction { route in withAnimation(.snappy) { stack.append(route) } })
    }

    private var back: some View {
        Button { withAnimation(.snappy) { _ = stack.popLast() } } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: Self.glyph, weight: .medium))
                .frame(width: Self.size, height: Self.size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .padding(.leading, 16)
        .padding(.top, 16)
        .keyboardShortcut("[", modifiers: .command)
        .accessibilityLabel("Back")
        .accessibilityIdentifier("details-back")
    }

    #if os(iOS)
    static var size: CGFloat { 44 }
    static var glyph: CGFloat { 17 }
    static var cardTop: CGFloat { 24 }
    static var background: Color { Color(uiColor: .systemBackground) }
    #else
    static var size: CGFloat { 28 }
    static var glyph: CGFloat { 12 }
    static var cardTop: CGFloat { 20 }
    static var background: Color { Color(nsColor: .windowBackgroundColor) }
    #endif
}

/// A member's (or any person's) contact card, pushed inside Details.
struct PersonRoute: Hashable {
    var id: String
    var name: String
    var avatar: CommsAvatar?
}

// MARK: Call menus

/// The items of a call menu: calls first, then a divider and the apps.
struct CallMenuItems: View {
    let options: [CallOption]

    var body: some View {
        let calls = options.filter { $0.kind != .app }
        let apps = options.filter { $0.kind == .app }
        ForEach(calls) { item($0) }
        if !calls.isEmpty, !apps.isEmpty { Divider() }
        ForEach(apps) { item($0) }
    }

    private func item(_ o: CallOption) -> some View {
        Button {
            CallOpener.openIfAllowed(o.url)
        } label: {
            Label {
                Text(o.title)
                if let detail = o.detail { Text(detail) }
            } icon: {
                Image(systemName: o.systemImage)
            }
        }
        .accessibilityLabel(o.detail.map { "\(o.title), \($0)" } ?? o.title)
    }
}

// MARK: Actions row

/// Messages' row of action circles: call (audio menu), video (video menu), mail. A circle
/// with nothing to offer is dimmed and inert, as in Messages.
struct ContactActionRow: View {
    let contact: CommsContact?
    let networks: [CommsNetwork]

    var body: some View {
        let options = CallRoutes.options(contact: contact, networks: networks)
        HStack(spacing: Self.spacing) {
            ActionMenuCircle(systemImage: "phone.fill", label: "Call", id: "details-call", options: CallRoutes.audio(options))
            ActionMenuCircle(systemImage: "video.fill", label: "Video", id: "details-video", options: CallRoutes.video(options))
            MailCircle(url: CallRoutes.mail(contact: contact))
        }
    }

    #if os(iOS)
    static let spacing: CGFloat = 16
    #else
    static let spacing: CGFloat = 12
    #endif
}

#if os(iOS)
/// Messages' grey 56 pt action circle (iOS), the glyph in the accent colour when it acts.
struct ActionCircleLabel: View {
    let systemImage: String
    let enabled: Bool
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(enabled ? AnyShapeStyle(ListMetrics.accent) : AnyShapeStyle(.tertiary))
            .frame(width: 56, height: 56)
            .background(Color(uiColor: .secondarySystemBackground), in: .circle)
            .contentShape(.circle)
    }
}
#else
/// Mac Details: a 32 pt soft circle with a small caption under it.
struct ActionCircleLabel: View {
    let systemImage: String
    let enabled: Bool
    var caption: String = ""
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? AnyShapeStyle(ListMetrics.accent) : AnyShapeStyle(.tertiary))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.quaternary.opacity(0.6)))
            Text(caption.lowercased())
                .font(.caption2)
                .foregroundStyle(enabled ? AnyShapeStyle(ListMetrics.accent) : AnyShapeStyle(.tertiary))
        }
        .frame(minWidth: 48)
        .contentShape(.rect)
    }
}
#endif

struct ActionMenuCircle: View {
    let systemImage: String
    let label: String
    let id: String
    let options: [CallOption]

    var body: some View {
        if options.isEmpty {
            Button {} label: { circle(enabled: false) }
                .buttonStyle(.plain)
                .disabled(true)
                .accessibilityLabel(label)
                .accessibilityHint("No way to reach this person")
                .accessibilityIdentifier(id)
        } else {
            Menu {
                CallMenuItems(options: options)
            } label: {
                circle(enabled: true)
            }
            .menuIndicator(.hidden)
            #if os(macOS)
            .menuStyle(.button)
            #endif
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
        }
    }

    @ViewBuilder private func circle(enabled: Bool) -> some View {
        #if os(iOS)
        ActionCircleLabel(systemImage: systemImage, enabled: enabled)
        #else
        ActionCircleLabel(systemImage: systemImage, enabled: enabled, caption: label)
        #endif
    }
}

struct MailCircle: View {
    let url: URL?

    var body: some View {
        if let url {
            Button { CallOpener.openIfAllowed(url) } label: { circle(enabled: true) }
                .buttonStyle(.plain)
                .accessibilityLabel("Mail")
                .accessibilityIdentifier("details-mail")
        } else {
            Button {} label: { circle(enabled: false) }
                .buttonStyle(.plain)
                .disabled(true)
                .accessibilityLabel("Mail")
                .accessibilityHint("No email address")
                .accessibilityIdentifier("details-mail")
        }
    }

    @ViewBuilder private func circle(enabled: Bool) -> some View {
        #if os(iOS)
        ActionCircleLabel(systemImage: "envelope.fill", enabled: enabled)
        #else
        ActionCircleLabel(systemImage: "envelope.fill", enabled: enabled, caption: "Mail")
        #endif
    }
}

// MARK: Sections

/// A titled group of rows: Messages' rounded panel (iOS: 26 pt corners on the secondary
/// background; Mac: the inspector's soft quaternary panel, 10 pt corners).
struct DetailsSection<Content: View>: View {
    var title: String?
    var id: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.headline)
                    #if os(iOS)
                    .padding(.leading, 16)
                    #endif
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                #if os(iOS)
                .padding(.horizontal, 16)
                .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 26))
                #else
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
                #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id ?? "")
    }
}

/// Rows divided by hairlines (Messages' grouped rows).
struct DividedRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
            row(item)
            if i < items.count - 1 { Divider() }
        }
    }
}

/// The person's phones and emails: the label small and grey over the value (Messages' card).
struct ContactPointRows: View {
    let contact: CommsContact

    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { "\(label)|\(value)" }
    }

    static func rows(_ contact: CommsContact) -> [Row] {
        contact.phones.map { Row(label: ($0.label ?? "phone").lowercased(), value: displayPhone($0.value)) }
            + contact.emails.map { Row(label: ($0.label ?? "email").lowercased(), value: $0.value) }
    }

    var body: some View {
        DividedRows(items: Self.rows(contact)) { row in
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).font(Self.labelFont).foregroundStyle(.secondary)
                Text(row.value).font(Self.valueFont).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Self.rowPadding)
            .accessibilityElement(children: .combine)
        }
    }

    /// A North American number as Contacts writes it ("+1 (555) 010-2233"); others as stored.
    static func displayPhone(_ e164: String) -> String {
        let d = Array(e164.dropFirst(2))
        guard e164.hasPrefix("+1"), d.count == 10, d.allSatisfy({ $0.isASCII && $0.isNumber }) else { return e164 }
        return "+1 (\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6...]))"
    }

    #if os(iOS)
    static let labelFont = Font.subheadline
    static let valueFont = Font.body
    static let rowPadding: CGFloat = 11
    #else
    static let labelFont = Font.caption
    static let valueFont = Font.callout
    static let rowPadding: CGFloat = 6
    #endif
}

/// "Conversations": every chat shared with the person (DMs on other networks and groups),
/// newest first. Tapping one opens it.
struct SharedConversationRows: View {
    let threads: [CommsThread]
    @Environment(\.openConversation) private var openConversation

    var body: some View {
        DividedRows(items: threads) { t in
            Button { openConversation(t.id) } label: {
                HStack(spacing: 10) {
                    AvatarView(t.avatar, kind: t.kind, size: Self.avatarSize, badge: t.networks.first, name: t.title)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(ContactPointRows.valueFont).lineLimit(1)
                        Text(Self.subtitle(t)).font(ContactPointRows.labelFont).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, ContactPointRows.rowPadding - 2)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(t.title), \(Self.subtitle(t))")
            .accessibilityHint("Opens the conversation")
            .accessibilityIdentifier("shared-thread-\(t.id)")
        }
    }

    /// "WhatsApp" for a DM, "WhatsApp · Group" for a group (with the account when named).
    static func subtitle(_ t: CommsThread) -> String {
        var parts = [t.networks.map(\.displayName).joined(separator: ", ")]
        if let account = t.accountLabel { parts.append(account) }
        if t.kind == .group { parts.append("Group") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    #if os(iOS)
    static let avatarSize: CGFloat = 36
    #else
    static let avatarSize: CGFloat = 26
    #endif
}

/// A group's members as rows; a member Prism knows as a person opens their contact card.
struct MemberRows: View {
    let members: [CommsMember]
    @Environment(\.showPerson) private var showPerson

    var body: some View {
        DividedRows(items: members) { m in
            // Ids by position: a member id is a bridge ghost id and can carry a phone number.
            let index = members.firstIndex { $0.id == m.id } ?? 0
            if let personID = m.personId {
                Button { showPerson(PersonRoute(id: personID, name: m.name, avatar: m.avatar)) } label: {
                    row(m, chevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows their contact card")
                .accessibilityIdentifier("member-\(index)")
            } else {
                row(m, chevron: false)
                    .accessibilityIdentifier("member-\(index)")
            }
        }
    }

    private func row(_ m: CommsMember, chevron: Bool) -> some View {
        HStack(spacing: 10) {
            AvatarView(m.avatar, size: SharedConversationRows.avatarSize, name: m.name)
                .accessibilityHidden(true)
            Text(m.name).font(ContactPointRows.valueFont).lineLimit(1)
            Spacer(minLength: 4)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, ContactPointRows.rowPadding - 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

// MARK: A person's card

/// The contact card of a vault person (a group member, pushed inside Details): avatar, name,
/// actions, phones and emails, and every conversation shared with them.
struct PersonCardView: View {
    let route: PersonRoute
    /// Preloaded (gallery, snapshots); nil = loaded through `\.peopleDirectory`.
    var preloaded: CommsPerson?

    @Environment(\.peopleDirectory) private var directory
    @State private var store: PersonStore?

    var body: some View {
        ScrollView {
            PersonCardContent(route: route, person: preloaded ?? store?.person, isLoading: preloaded == nil && (store?.isLoading ?? true), error: store?.error)
                .padding(.horizontal, Self.inset)
                .padding(.bottom, 24)
        }
        .accessibilityIdentifier("person-card")
        .task(id: route.id) {
            guard preloaded == nil else { return }
            let s = PersonStore(personID: route.id, fetch: directory.load)
            store = s
            await s.load()
        }
    }

    #if os(iOS)
    static let inset: CGFloat = 20
    #else
    static let inset: CGFloat = 16
    #endif
}

/// The card's content without scrolling (snapshots render it directly).
struct PersonCardContent: View {
    let route: PersonRoute
    let person: CommsPerson?
    var isLoading = false
    var error: String?
    @Environment(\.detailsThreadID) private var openThreadID

    var body: some View {
        VStack(spacing: 0) {
            AvatarView(person?.avatar ?? route.avatar, size: DetailsHeaderMetrics.avatar, name: person?.name ?? route.name)
                .padding(.top, DetailsHeaderMetrics.top)
                .accessibilityHidden(true)
            Text(person?.name ?? route.name)
                .font(DetailsHeaderMetrics.titleFont)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("person-card-title")
            ContactActionRow(contact: person?.contact, networks: [])
                .padding(.top, 16)
            VStack(spacing: 16) {
                if let contact = person?.contact, !ContactPointRows.rows(contact).isEmpty {
                    DetailsSection(id: "person-info") { ContactPointRows(contact: contact) }
                }
                if let threads = person?.threads.filter({ $0.id != openThreadID }), !threads.isEmpty {
                    DetailsSection(title: "Conversations", id: "person-conversations") { SharedConversationRows(threads: threads) }
                } else if isLoading {
                    ProgressView().controlSize(.small).padding(.top, 8)
                } else if let error {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Header sizes of Details (iOS: avatar 80, Bold 28; Mac: avatar 72, Title 3 semibold).
enum DetailsHeaderMetrics {
    #if os(iOS)
    static let avatar: CGFloat = 80
    static let top: CGFloat = 28
    static let titleFont = Font.system(size: 28, weight: .bold)
    #else
    static let avatar: CGFloat = 72
    static let top: CGFloat = 20
    static let titleFont = Font.title3.weight(.semibold)
    #endif
}

/// Loads the open DM's person (for "Conversations") through `\.peopleDirectory`.
@MainActor
struct ThreadPersonLoader: ViewModifier {
    let personID: String?
    @Binding var person: CommsPerson?
    @Environment(\.peopleDirectory) private var directory

    func body(content: Content) -> some View {
        content.task(id: personID) {
            guard let personID else { person = nil; return }
            let s = PersonStore(personID: personID, fetch: directory.load)
            await s.load()
            if let p = s.person { person = p }
        }
    }
}
