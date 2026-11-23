import CommsClient
import CommsCore
import SwiftUI

/// Messages' New Message screen (iOS sheet, Mac detail column): a "To:" row, the
/// suggestions under it while typing (people with each phone number / email, then existing
/// conversations on any network), and the message field at the bottom.
///
/// `open` is called with the conversation to show (an existing one picked from the list, or
/// the one just started); the host closes the compose screen and selects it.
public struct ComposeView: View {
    @Bindable var store: ComposeStore
    let open: (String) -> Void
    @FocusState private var focus: Field?
    @Environment(\.colorScheme) private var scheme

    enum Field: Hashable { case to, message }

    public init(store: ComposeStore, open: @escaping (String) -> Void) {
        self.store = store
        self.open = open
    }

    public var body: some View {
        VStack(spacing: 0) {
            toRow
            Divider()
            if store.recipient == nil {
                suggestions
            } else {
                Spacer(minLength: 0)
            }
            footer
        }
        .onAppear { focus = store.recipient == nil ? .to : .message }
    }

    // MARK: To:

    private var toRow: some View {
        HStack(spacing: 6) {
            Text("To:")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let r = store.recipient {
                RecipientChip(store: store, recipient: r)
                Spacer(minLength: 0)
            } else {
                TextField("", text: $store.toText, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .to)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.default)
                    #endif
                    .onSubmit(submitTo)
                    .onChange(of: store.toText) { _, text in
                        // A comma commits the address, as in Messages.
                        if text.hasSuffix(",") {
                            store.toText = String(text.dropLast())
                            submitTo()
                        }
                    }
                    .accessibilityLabel("To")
                    .accessibilityIdentifier("compose-to")
            }
        }
        .font(Self.fieldFont)
        .padding(.horizontal, Self.inset)
        .frame(minHeight: Self.toRowHeight)
    }

    /// Return in the To: field takes the first suggestion (as Messages does).
    private func submitTo() {
        // Commits what is typed NOW (awaits a running lookup; never a stale list).
        Task { if let outcome = await store.commitTo() { act(outcome) } }
    }

    private func act(_ outcome: ComposeStore.Outcome) {
        switch outcome {
        case .open(let id): open(id)
        case .chosen: focus = .message
        }
    }

    // MARK: Suggestions

    private var suggestions: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.addressSuggestions) { s in
                    SuggestionRow(avatar: s.avatar, name: s.name, detail: Self.detail(s), badge: nil) { act(store.choose(s)) }
                        .accessibilityIdentifier("compose-person-\(s.value)")
                }
                if !store.conversationSuggestions.isEmpty {
                    Text("Conversations")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, Self.inset)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(store.conversationSuggestions, id: \.id) { t in
                        SuggestionRow(avatar: t.avatar, kind: t.kind, name: t.title, detail: Self.detail(t), badge: t.networks.first) { act(store.choose(thread: t)) }
                            .accessibilityIdentifier("compose-thread-\(t.id)")
                    }
                }
                if let hint = store.hint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Self.inset)
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("compose-hint")
                }
                if store.isLooking, store.results == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    static func detail(_ s: ComposeStore.AddressSuggestion) -> String {
        let value = s.kind == .phone ? ContactPointRows.displayPhone(s.value) : s.value
        return s.threadID == nil ? value : "iMessage · \(value)"
    }

    static func detail(_ t: CommsThread) -> String {
        let net = t.networks.first?.displayName ?? ""
        return t.kind == .group ? "\(net) · Group" : net
    }

    // MARK: Message field

    @ViewBuilder private var footer: some View {
        VStack(spacing: 6) {
            if let f = store.failure {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(store.failureText ?? f.displayText).font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if !f.isFinal {
                        Button("Try Again") { Task { await sendNow() } }
                            .buttonStyle(.borderless)
                            .font(.footnote.weight(.semibold))
                            .accessibilityIdentifier("compose-retry")
                    }
                }
                .padding(.horizontal, Self.inset)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("compose-failure")
            }
            if store.isEmail {
                // A new email needs a subject (Mail's compact Subject: row above the body).
                HStack(spacing: 6) {
                    Text("Subject:").foregroundStyle(.secondary)
                    TextField("", text: $store.subject, prompt: Text(""))
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Subject")
                        .accessibilityIdentifier("compose-subject")
                }
                .font(Self.fieldFont)
                .padding(.horizontal, Self.inset)
                .padding(.vertical, 6)
                Divider().padding(.leading, Self.inset)
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField(placeholder, text: $store.messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focus, equals: .message)
                    .disabled(store.recipient == nil)
                    .padding(.vertical, 7)
                    .padding(.leading, 12)
                    .onSubmit { Task { await sendNow() } }
                    .accessibilityIdentifier("compose-message")
                Group {
                    if store.isSending {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Sending")
                    } else {
                        Button { Task { await sendNow() } } label: {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.bold))
                                .imageScale(.small)
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(store.canSend ? sendBlue : Color.gray.opacity(0.4), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.canSend)
                        .accessibilityLabel("Send")
                        .accessibilityHint(store.canSend ? "" : (store.recipient == nil ? "Choose a recipient first" : store.isEmail && store.subject.isEmpty ? "Add a subject first" : "Write a message first"))
                        .accessibilityIdentifier("compose-send")
                    }
                }
                .frame(width: 28, height: 28)
                .padding(.trailing, 4)
                .padding(.bottom, 4)
            }
            .font(Self.fieldFont)
            .background(Capsule().strokeBorder(.separator, lineWidth: 1))
            .padding(.horizontal, Self.inset - 4)
            .padding(.bottom, 8)
        }
        .padding(.top, 6)
    }

    private var placeholder: String {
        store.isEmail ? "Email" : store.network == .sms && store.recipient?.kind == .phone ? "Text Message · SMS" : "iMessage"
    }

    private var sendBlue: Color { scheme == .dark ? Color(red: 0, green: 0x91 / 255, blue: 1) : ListMetrics.accent }

    private func sendNow() async {
        guard let outcome = await store.send() else { return }
        act(outcome)
    }

    /// The text style of the To: and message fields (Dynamic Type: body on both platforms,
    /// 17 pt on iPhone and 13 pt on the Mac at the default size).
    static let fieldFont = Font.body
    #if os(iOS)
    static let inset: CGFloat = 16
    static let toRowHeight: CGFloat = 44
    #else
    static let inset: CGFloat = 14
    static let toRowHeight: CGFloat = 36
    #endif
}

/// The chosen recipient in the To: field: a blue capsule (Messages' recipient atom); its
/// menu picks iMessage or SMS for a phone number and removes it.
struct RecipientChip: View {
    @Bindable var store: ComposeStore
    let recipient: ComposeStore.Recipient

    var body: some View {
        Menu {
            if recipient.kind == .phone {
                Picker("Send As", selection: $store.network) {
                    Text("iMessage").tag(CommsClient.NewConversationNetwork.imessage)
                    Text("Text Message (SMS)").tag(CommsClient.NewConversationNetwork.sms)
                }
                Divider()
            } else if recipient.kind == .email {
                Picker("Send As", selection: $store.network) {
                    Text("iMessage").tag(CommsClient.NewConversationNetwork.imessage)
                    Text("Email").tag(CommsClient.NewConversationNetwork.email)
                }
                .accessibilityIdentifier("compose-send-as")
                Divider()
            }
            Text(recipient.kind == .phone ? ContactPointRows.displayPhone(recipient.value) : recipient.value)
            Button("Remove", systemImage: "xmark.circle", role: .destructive) { store.clearRecipient() }
                .accessibilityIdentifier("compose-remove-recipient")
        } label: {
            Text(recipient.title)
                .foregroundStyle(store.network == .sms && recipient.kind == .phone ? Color.green : ListMetrics.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill((store.network == .sms && recipient.kind == .phone ? Color.green : ListMetrics.accent).opacity(0.12)))
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("To \(recipient.title)")
        .accessibilityValue(recipient.kind == .phone && store.network == .sms ? "SMS" : store.isEmail ? "Email" : "iMessage")
        .accessibilityIdentifier("compose-recipient")
    }
}

/// One suggestion: avatar, name, and the address or network under it.
struct SuggestionRow: View {
    let avatar: CommsAvatar?
    var kind: CommsThreadKind = .dm
    let name: String
    let detail: String
    let badge: CommsNetwork?
    let action: () -> Void

    init(avatar: CommsAvatar?, kind: CommsThreadKind = .dm, name: String, detail: String, badge: CommsNetwork?, action: @escaping () -> Void) {
        self.avatar = avatar
        self.kind = kind
        self.name = name
        self.detail = detail
        self.badge = badge
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AvatarView(avatar, kind: kind, size: Self.avatarSize, badge: badge, name: name)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.body).foregroundStyle(.primary).lineLimit(1)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ComposeView.inset)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    #if os(iOS)
    static let avatarSize: CGFloat = 40
    #else
    static let avatarSize: CGFloat = 32
    #endif
}
