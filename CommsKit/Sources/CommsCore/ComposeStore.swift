import CommsClient
import Foundation
import Observation

/// The New Message sheet / window, Messages-style: a "To:" field that suggests people (each
/// with their phone numbers and email addresses) and existing conversations on any network,
/// and a message field.
///
/// - Picking an existing conversation, or an address that already has an iMessage/SMS
///   conversation, opens it.
/// - Picking an address without one and pressing Send starts an iMessage (or SMS) conversation
///   through `POST /conversations`, then opens it. When the server finds a conversation after
///   all (`existing`), nothing was sent there: the message goes out through the window's
///   outbox like any other send, and the conversation opens.
/// - New conversations on other networks (WhatsApp, Telegram, …) cannot be started yet: their
///   existing chats are suggested, and the sheet says so quietly.
///
/// Lookups are debounced (`lookupDelay`), the one in flight is cancelled by the next keystroke,
/// and a late answer for older text is dropped. Nothing is ever sent without Send; a failed
/// start keeps the text and Try Again reuses the same clientId.
@MainActor @Observable
public final class ComposeStore {
    /// What the To: field holds while no recipient is chosen.
    public var toText = "" {
        didSet { if toText != oldValue { lookUp() } }
    }
    /// The message being written.
    public var messageText = "" {
        didSet { if messageText != oldValue, failure != nil, !isSending { failure = nil } }
    }
    /// The server's suggestions for the current text (nil = nothing asked yet / empty field).
    public private(set) var results: CommsRecipients?
    /// The To: text `results` answer (they stay on screen while a newer lookup runs).
    @ObservationIgnored public private(set) var resultsText: String?
    /// A lookup for the current text is pending or in flight.
    public private(set) var isLooking = false
    /// The chosen address (a chip in the To: field).
    public private(set) var recipient: Recipient?
    /// iMessage, SMS for a phone number, or Email for an email address (D11).
    public var network: CommsClient.NewConversationNetwork = .imessage {
        didSet { if network != oldValue, failure != nil, !isSending { failure = nil } }
    }
    /// The new email's subject (shown when sending as Email).
    public var subject = ""
    /// The recipient is an email address and the owner chose Email (plain text, a subject).
    public var isEmail: Bool { network == .email && recipient?.kind == .email }
    public private(set) var isSending = false
    /// The last start failed (shown under the field; the text stays).
    public private(set) var failure: CommsSendFailure?
    /// Lookups that reached the backend (tests / measurements).
    @ObservationIgnored public private(set) var lookups: [String] = []
    @ObservationIgnored public var lookupDelay: Duration
    /// How often / how long a just-started conversation is looked for before it is opened anyway.
    @ObservationIgnored public var pendingPoll: (interval: Duration, tries: Int) = (.milliseconds(800), 15)

    @ObservationIgnored private let backend: any ChatBackend
    @ObservationIgnored private let outbox: Outbox
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// The clientId of the start in progress / to retry (kept while recipient + text stay).
    @ObservationIgnored private var attempt: (clientID: String, key: String)?
    /// The lookup task (tests await it).
    @ObservationIgnored public private(set) var lookupWork: Task<Void, Never>?

    /// A chosen recipient: one address of one person (or a typed address).
    public struct Recipient: Hashable, Sendable {
        public var name: String?
        public var value: String
        public var kind: CommsRecipientHandle.Kind
        public var avatar: CommsAvatar?
        public var threadID: String?

        public init(name: String?, value: String, kind: CommsRecipientHandle.Kind, avatar: CommsAvatar? = nil, threadID: String? = nil) {
            self.name = name
            self.value = value
            self.kind = kind
            self.avatar = avatar
            self.threadID = threadID
        }

        /// What the chip reads: the name, else the address.
        public var title: String { name?.isEmpty == false ? name! : value }
    }

    /// What picking a suggestion or sending leads to.
    public enum Outcome: Equatable, Sendable {
        /// Open this conversation (the sheet closes).
        case open(threadID: String)
        /// A recipient was chosen; write the message.
        case chosen
    }

    public init(backend: any ChatBackend, outbox: Outbox, lookupDelay: Duration = .milliseconds(150)) {
        self.backend = backend
        self.outbox = outbox
        self.lookupDelay = lookupDelay
    }

    // MARK: Suggestions

    /// One row of the people section: a person's address (Messages lists each number / email).
    public struct AddressSuggestion: Identifiable, Hashable, Sendable {
        public var id: String { "\(personID):\(value)" }
        public var personID: String
        public var name: String
        public var avatar: CommsAvatar?
        public var value: String
        public var kind: CommsRecipientHandle.Kind
        /// The existing iMessage/SMS conversation with this address.
        public var threadID: String?
    }

    /// People's addresses, in the server's order (a person without any is left out: only
    /// their existing chats can be offered).
    public var addressSuggestions: [AddressSuggestion] {
        guard let results else { return [] }
        var out: [AddressSuggestion] = []
        for p in results.people {
            for a in p.phones { out.append(AddressSuggestion(personID: p.id, name: p.name, avatar: p.avatar, value: a.value, kind: .phone, threadID: a.threadId)) }
            for a in p.emails { out.append(AddressSuggestion(personID: p.id, name: p.name, avatar: p.avatar, value: a.value, kind: .email, threadID: a.threadId)) }
        }
        return out
    }

    /// Existing conversations on any network.
    public var conversationSuggestions: [CommsThread] { results?.threads ?? [] }

    /// The typed text as an address the server can start a conversation with (nil when it is
    /// not one). Not shown as a suggestion: it is taken only when the owner commits the text
    /// (Return or a comma, `commitTo()`).
    public var typedAddress: CommsRecipientHandle? { results?.handle }

    /// What the failure line says. A 409 `in_progress` from New Message also means "a
    /// conversation with this address was just started".
    public var failureText: String? {
        guard let f = failure else { return nil }
        if f.reason == .inProgress { return "A conversation with this address was just started. Try again in a moment." }
        return f.displayText
    }

    /// A quiet line under the suggestions: why a person cannot be messaged anew here, or how
    /// to type a number.
    public var hint: String? {
        guard let results, !isLooking else { return nil }
        let unreachable = results.people.filter { $0.phones.isEmpty && $0.emails.isEmpty }
        if let first = unreachable.first {
            return "New conversations can be started with iMessage or SMS. \(first.name)’s other chats are listed here."
        }
        let digits = toText.filter(\.isNumber)
        if results.handle == nil, digits.count >= 7, !toText.contains("@"), !toText.trimmingCharacters(in: .whitespaces).hasPrefix("+") {
            return "Include the country code, like +1 555 123 4567."
        }
        return nil
    }

    private func lookUp() {
        task?.cancel()
        generation += 1
        let query = toText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, recipient == nil else {
            results = nil
            isLooking = false
            lookupWork = nil
            return
        }
        isLooking = true
        let gen = generation
        let q = String(query.prefix(100))
        let t = Task { [weak self, lookupDelay] in
            try? await Task.sleep(for: lookupDelay)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.lookups.append(q)
            let answer = try? await self.backend.recipients(query: q, limit: 8)
            guard !Task.isCancelled, gen == self.generation else { return }
            self.isLooking = false
            // Offline / refused: keep what was shown (nothing to suggest is not an error).
            if let answer {
                self.results = answer
                self.resultsText = q
            }
        }
        task = t
        lookupWork = t
    }

    // MARK: Choosing

    /// The owner picked an existing conversation.
    public func choose(thread: CommsThread) -> Outcome { .open(threadID: thread.id) }

    /// The owner picked a person's address (or the typed address): its existing iMessage/SMS
    /// conversation opens; otherwise it becomes the recipient.
    public func choose(_ s: AddressSuggestion) -> Outcome {
        if let id = s.threadID { return .open(threadID: id) }
        setRecipient(Recipient(name: s.name, value: s.value, kind: s.kind, avatar: s.avatar))
        return .chosen
    }

    public func choose(typed h: CommsRecipientHandle) -> Outcome {
        if let id = h.threadId { return .open(threadID: id) }
        setRecipient(Recipient(name: nil, value: h.value, kind: h.kind))
        return .chosen
    }

    /// Return (or a comma) in the To: field COMMITS what was typed: the typed address itself
    /// when the server reads it as one ("Send to <handle>" is never a live suggestion), else
    /// the first suggestion. A lookup still running is awaited, so the answer is always for
    /// the text typed now — never a stale list (review I4). Nil = nothing to take.
    public func commitTo() async -> Outcome? {
        let now = String(toText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard recipient == nil, !now.isEmpty else { return nil }
        if isLooking || resultsText != now {
            if !isLooking { lookUp() }
            await lookupWork?.value
        }
        let current = String(toText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard current == now, !isLooking, recipient == nil, let results, resultsText == now else { return nil }
        if let h = results.handle { return choose(typed: h) }
        if let a = addressSuggestions.first { return choose(a) }
        if let t = conversationSuggestions.first { return choose(thread: t) }
        return nil
    }

    /// Remove the chip (Delete in an empty To: field, or the chip's ⓧ).
    public func clearRecipient() {
        recipient = nil
        failure = nil
        network = .imessage
        lookUp()
    }

    private func setRecipient(_ r: Recipient) {
        task?.cancel()
        recipient = r
        network = .imessage
        failure = nil
        results = nil
        isLooking = false
    }

    // MARK: Sending

    /// Send is offered: a recipient, some text, nothing in flight.
    public var canSend: Bool {
        recipient != nil && !isSending && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isEmail || !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            // `@Omni …` is a private instruction (D9), never a first message to someone.
            && !OmniStore.addressesOmni(messageText)
    }

    /// Start the conversation with the message (or, if the server already has one with this
    /// address, send it there). Returns what to open; nil when it failed (see `failure`).
    public func send() async -> Outcome? {
        guard canSend, let r = recipient else { return nil }
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let net: CommsClient.NewConversationNetwork = r.kind == .email ? (network == .email ? .email : .imessage) : (network == .email ? .imessage : network)
        let subj = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try Again (same recipient, network and text) reuses the clientId: never sent twice.
        let key = "\(r.value)\n\(net.rawValue)\n\(net == .email ? subj : "")\n\(text)"
        let clientID = attempt?.key == key ? attempt!.clientID : UUID().uuidString.lowercased()
        attempt = (clientID, key)
        isSending = true
        failure = nil
        defer { isSending = false }
        do {
            let answer = net == .email
                ? try await backend.startEmail(clientID: clientID, to: r.value, subject: subj, text: text)
                : try await backend.startConversation(clientID: clientID, handle: r.value, network: net, text: text)
            attempt = nil
            if answer.existing {
                // Nothing was sent: send it there, through the outbox like any message.
                let thread = answer.threadId
                Task { [outbox] in await outbox.send(threadID: thread, text: text, attachments: [], replyTo: nil) }
            } else if answer.pending {
                await waitForThread(answer.threadId)
            }
            messageText = ""
            subject = ""
            return .open(threadID: answer.threadId)
        } catch {
            // The clientId stays for Try Again (the server never sends one twice).
            failure = TimelineStore.sendFailure(error)
            return nil
        }
    }

    /// A conversation the server has not projected yet: look for it a few times (it appears
    /// once BlueBubbles reports the chat), then open it anyway.
    private func waitForThread(_ id: String) async {
        for _ in 0..<pendingPoll.tries {
            if Task.isCancelled { return }
            if (try? await backend.thread(id: id)) != nil { return }
            do { try await Task.sleep(for: pendingPoll.interval) } catch { return }
        }
    }
}
