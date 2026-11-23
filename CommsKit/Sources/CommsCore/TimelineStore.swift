import CommsClient
import Foundation
import Observation
import PrismTransport

/// One open conversation: its messages (oldest first) laid out as transcript rows, paging
/// back through history, kept current by live events. Titles, avatars and message content
/// come from the server; the store only orders, merges and groups.
@MainActor @Observable
public final class TimelineStore {
    public let threadID: String
    /// The thread (from the list when the transcript opens, then from `thread(id:)`).
    public private(set) var thread: CommsThread?
    public private(set) var members: [CommsMember] = []
    /// How to reach the other person of a DM (from the thread detail; nil for groups or an
    /// older server). Drives the call menus.
    public private(set) var contact: CommsContact?
    public private(set) var rows: [TranscriptRow] = []
    /// More history exists before the oldest loaded message.
    public private(set) var hasMore = false
    public private(set) var isLoading = false
    /// "Can't reach WhatsApp right now" while the source network cannot answer (503).
    public private(set) var sourceError: String?
    /// Any other failure to load ("Couldn't load messages.").
    public private(set) var loadError: String?

    public var isGroup: Bool { thread?.kind == .group }
    /// History exists, but the last load followed `maxEmptyPages` pages that held nothing new
    /// (all folded away or already shown) and stopped. Automatic prefetch pauses; the UI offers
    /// "Load Earlier Messages", which calls `loadOlder()` again.
    public private(set) var isStalled = false
    /// Bumped whenever a `loadOlder()` request finishes, whatever it found (or failed with):
    /// the transcript re-arms its prefetch on it, so a load that adds nothing never dead-ends.
    public private(set) var olderLoadCount = 0

    /// The owner's sender ids seen in this thread (VoiceOver says "you" for them).
    public private(set) var selfSenderIDs: Set<String> = []

    /// The owner's messages on their way out, sent but not yet echoed, and failed — this
    /// thread's entries in the window's ``Outbox`` (they outlive this store). Each is drawn
    /// as an outgoing bubble until the server's echo (same event id or clientId) replaces it.
    public var pendingSends: [PendingSend] { outbox.pending(threadID: threadID) }
    /// Where this thread's sends live (shared by every transcript of the window).
    public let outbox: Outbox
    /// The thread detail's channel capabilities (nil until `thread(id:)` answers).
    public private(set) var capabilities: CommsChannelCapabilities?
    /// Email threads: the account and what a reply would be (To/Cc/Subject), from the detail.
    public private(set) var emailDetail: CommsEmailDetail?
    /// "View Full Email" asked for this message (the transcript presents the sheet).
    public var emailOriginalRequest: EmailOriginalRequest?
    /// This is an email conversation.
    public var isEmail: Bool { sendNetwork == .email }
    /// The owner chose Reply All (Mail's default is Reply: the sender only).
    public private(set) var emailReplyAll = false
    /// Reply All is offered (it adds someone, within the server's cap).
    public var canReplyAll: Bool { isEmail && emailDetail?.replyAll != nil }
    /// The composer's To/Cc/Subject header: exactly the recipient set Send echoes (and the server binds).
    public var emailReply: CommsEmailDetail.Reply? {
        guard isEmail else { return nil }
        return emailReplyAll ? (emailDetail?.replyAll ?? emailDetail?.reply) : emailDetail?.reply
    }
    /// Reply ↔ Reply All.
    public func setEmailReplyAll(_ on: Bool) { emailReplyAll = on && canReplyAll }
    /// The server's attachment cap (`capabilities.send.maxAttachmentBytes`); nil = unknown.
    public var maxAttachmentBytes: Int? {
        get { outbox.maxAttachmentBytes }
        set { outbox.maxAttachmentBytesOverride = newValue }
    }

    /// The owner can send here: the server declares `send` on this thread's channel (which it
    /// does only when sending is enabled and the network is supported).
    public var canSend: Bool {
        let declared = channelChoices.isEmpty
            ? (capabilities?.send ?? thread?.channels.first?.capabilities?.send ?? false)
            : (outgoingChannel?.capabilities?.send ?? false)
        // Email: only with a reply header to show (and send) — never a reply to unknown recipients.
        // A forum: only with a concrete topic to post in.
        return declared && (!isEmail || emailReply != nil) && (!isForum || sendTopic != nil)
    }
    /// The network this thread sends on (in a merged conversation: the picked channel's).
    public var sendNetwork: CommsNetwork? { outgoingChannel?.network ?? thread?.networks.first }

    /// A merged conversation (one person on several networks): the channels the composer's
    /// "WhatsApp ⌄" placeholder offers. Empty when the thread has one channel.
    public var channelChoices: [CommsChannelRef] {
        guard let channels = thread?.channels, channels.count > 1 else { return [] }
        return channels
    }
    /// The channel the owner picked (nil = the default).
    public var pickedChannel: CommsChannelRef? {
        didSet { if let p = pickedChannel, !channelChoices.contains(p) { pickedChannel = nil } }
    }
    /// The channel of the newest message from someone else, when it is one of the thread's.
    public private(set) var latestInboundChannel: CommsChannelRef?
    /// Where the next message goes: the owner's pick, else the channel of the most recent
    /// inbound message (Messages' rule for merged conversations), else the thread's first.
    public var outgoingChannel: CommsChannelRef? {
        let choices = channelChoices
        if choices.isEmpty { return thread?.channels.first }
        if let p = pickedChannel, choices.contains(p) { return p }
        if let l = latestInboundChannel, let match = Self.match(l, in: choices) { return match }
        return choices.first
    }
    /// The pick sent with each message (only in a merged conversation, so the server can refuse
    /// a channel the thread can't send through).
    var outgoingChannelPick: CommsChannelRef? {
        channelChoices.isEmpty ? nil : outgoingChannel.map { CommsChannelRef(network: $0.network, accountLabel: $0.accountLabel) }
    }
    static func match(_ c: CommsChannelRef, in choices: [CommsChannelRef]) -> CommsChannelRef? {
        choices.first { $0.network == c.network && $0.accountLabel == c.accountLabel } ?? choices.first { $0.network == c.network }
    }
    /// The capabilities the composer follows: the outgoing channel's in a merged conversation.
    private var outgoingCapabilities: CommsChannelCapabilities? {
        channelChoices.isEmpty ? (capabilities ?? thread?.channels.first?.capabilities) : outgoingChannel?.capabilities
    }
    /// `@Name` mentions are offered: a group whose channel declares `mentions` and can send.
    public var canMention: Bool { isGroup && canSend && (outgoingCapabilities?.mentions ?? false) }
    /// The `@` suggestions for `query` (members, never the owner).
    public func mentionCandidates(_ query: String) -> [CommsMember] {
        guard canMention else { return [] }
        return MentionText.candidates(members, query: query, excluding: selfSenderIDs)
    }
    /// A reply affordance may be offered: the channel declares `reply` and the network accepts
    /// sent replies (never iMessage / SMS — BlueBubbles refuses `replyTo` with 422).
    public var canReply: Bool {
        guard canSend, sendNetwork?.supportsSentReplies ?? false else { return false }
        return outgoingCapabilities?.reply ?? false
    }
    /// How voice notes are encoded for this thread.
    public var voiceNoteFormat: VoiceNoteFormat { .for(sendNetwork) }

    /// The room is end-to-end encrypted (the server never declares `send` for it).
    public var isEncrypted: Bool {
        outgoingCapabilities?.encrypted ?? false
    }
    /// Attachments may be sent here (send, and the channel does not refuse attachments
    /// outright when it says anything about them).
    public var canSendAttachments: Bool { canSend }

    // MARK: Telegram forums

    /// A Telegram forum (one thread, topics as sub-conversations).
    public var isForum: Bool { thread?.forum != nil || !topics.isEmpty }
    /// The forum's topics, newest activity first (from the thread detail).
    public private(set) var topics: [CommsTopic] = []
    /// The topic shown; nil = All Topics (every topic merged, each message labelled).
    public private(set) var selectedTopicID: String?
    /// The selected topic (nil in All Topics).
    public var selectedTopic: CommsTopic? { selectedTopicID.flatMap { id in topics.first { $0.id == id } } }
    /// What the messages request names: the selected topic, or nil (All Topics / not a forum).
    var viewTopic: String? { isForum ? selectedTopicID : nil }
    /// The topic picked in All Topics with the composer's "To #…" chip (nil = none picked).
    public private(set) var pickedTopicID: String?
    /// The All Topics target FROZEN when the owner started composing (fix round 1, C-1): live
    /// messages from other topics never move it; only the chip or a reply does.
    public private(set) var frozenTopicID: String?
    /// The composer holds text or attachments.
    public private(set) var isComposing = false

    private func ref(_ id: String) -> CommsTopicRef {
        topics.first { $0.id == id }?.ref ?? messages.last { $0.topic?.id == id }?.topic ?? CommsTopicRef(id: id, title: id)
    }
    /// A reply answers its message in THAT message's topic (I-2).
    private var replyTopicID: String? { replyTarget.flatMap { topicID(ofMessage: $0.id) } }
    /// All Topics' default target while nothing is being composed: the newest message's topic,
    /// else the most recently active topic.
    private var defaultTopicID: String? {
        messages.last(where: { $0.topic != nil && $0.system == nil })?.topic?.id ?? topics.first?.id
    }

    /// What the composer shows it will post to (the chip, the placeholder): the topic on screen; in
    /// All Topics the replied-to message's topic, else the target frozen when composing began,
    /// else the picked or default one. Never "All". Nil outside forums.
    public var composeTopic: CommsTopicRef? {
        guard isForum else { return nil }
        if let id = selectedTopicID { return ref(id) }
        if let r = replyTopicID { return ref(r) }
        if isComposing, let f = frozenTopicID { return ref(f) }
        return (pickedTopicID ?? defaultTopicID).map(ref)
    }
    /// Where Send posts: as `composeTopic`, but never re-derived at Send from live arrivals — the
    /// target frozen when composing began wins over the default (C-1).
    public var sendTopic: CommsTopicRef? {
        guard isForum else { return nil }
        if let id = selectedTopicID { return ref(id) }
        if let r = replyTopicID { return ref(r) }
        return (frozenTopicID ?? pickedTopicID ?? defaultTopicID).map(ref)
    }
    /// The composer became non-empty (freeze the All Topics target) or empty again.
    public func composingChanged(_ composing: Bool) {
        guard composing != isComposing else { return }
        if composing { frozenTopicID = pickedTopicID ?? defaultTopicID }
        isComposing = composing
    }
    /// The "To #…" chip: post the draft to this topic (All Topics only).
    public func pickComposeTopic(_ id: String) {
        guard isForum, selectedTopicID == nil, topics.contains(where: { $0.id == id }) else { return }
        pickedTopicID = id
        frozenTopicID = id
    }

    /// The forum's read point for the open view (fix round 1, I-4): the topic on screen (nil = All
    /// Topics) and the newest message shown. Nothing loaded yet reads nothing.
    public var forumReadPoint: ForumReadPoint? {
        guard isForum else { return nil }
        return ForumReadPoint(topic: selectedTopicID, upTo: messages.last { $0.system == nil }?.sentAt ?? .distantPast)
    }
    /// Told when `forumReadPoint` moves (the list store reads the forum up to it).
    @ObservationIgnored public var onReadPointChange: (@MainActor () -> Void)?
    @ObservationIgnored private var lastReadPoint: ForumReadPoint?
    /// The composer's placeholder in a forum: "Reply in #General" (nil elsewhere).
    public var composerPlaceholder: String? {
        composeTopic.map { "Reply in #\($0.title)" }
    }
    /// Show one topic (`id`) or All Topics (nil): reloads the transcript for that view.
    public func selectTopic(_ id: String?) {
        guard id != selectedTopicID else { return }
        selectedTopicID = id
        pickedTopicID = nil
        frozenTopicID = nil
        messages = []
        before = nil
        hasMore = false
        relayout()
        pendingWork = Task { await loadLatest() }
    }
    /// The topic a loaded message belongs to (reactions name it), else the topic on screen.
    func topicID(ofMessage id: String) -> String? {
        guard isForum else { return nil }
        return messages.first { $0.id == id }?.topic?.id ?? selectedTopicID
    }

    /// The last reaction that failed (a gentle notice; nothing is retried on its own).
    public internal(set) var reactionNotice: ReactionNotice?
    /// The message the composer is replying to (Reply in the message menu); nil = none.
    public private(set) var replyTarget: CommsMessage?
    /// The owner's reaction requests not yet shown by the server, by message id (oldest first).
    @ObservationIgnored var reactionOps: [String: [ReactionOp]] = [:]
    /// The task sending each message's queue, one at a time.
    @ObservationIgnored var reactionRunners: [String: Task<Void, Never>] = [:]
    @ObservationIgnored let reactionNow: @MainActor () -> Date
    var reactionBackend: any ChatBackend { backend }

    @ObservationIgnored private let backend: any ChatBackend
    @ObservationIgnored private let gapMinutes: Int
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var messages: [CommsMessage] = []
    @ObservationIgnored private var before: String?
    /// Bumped by every `loadLatest()`: older-page answers from a previous generation are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isLoadingOlder = false
    /// What failed last, so `retry()` repeats it.
    @ObservationIgnored private var failedOlder = false
    /// The reload a `reset` / `thread.updated` event started (tests await it).
    @ObservationIgnored public private(set) var pendingWork: Task<Void, Never>?
    /// `thread.updated` header refetches, coalesced (a burst costs one request).
    @ObservationIgnored private var headerRefetch: RefetchCoalescer!
    /// Sends run one after another, in the order they were made (attachments, then text).
    @ObservationIgnored private var isRelayouting = false
    /// Server messages that stand for one of this device's sends (echo matched by event id,
    /// clientId or content), message id → clientId. Their rows keep the pending bubble's
    /// identity (`TranscriptRow.diffID`), so the swap is an in-place update on screen.
    @ObservationIgnored private var echoClientIDs: [String: String] = [:]
    /// When this store first saw each of the owner's messages that carry no clientId (a content
    /// echo must have arrived after Send was pressed).
    @ObservationIgnored private var arrivals: [String: Date] = [:]
    /// Tests: every layout the transcript would draw, in order (each is one frame's rows).
    @ObservationIgnored var rowsObserver: (([TranscriptRow]) -> Void)?

    /// A page that comes back empty but with `hasMore` is followed at most this many times
    /// per call (the server folds relations away; an endless run of empties is a server bug).
    static let maxEmptyPages = 20

    /// `gapMinutes`: pass `Tokens.transcript.timeHeaderGapMinutes` (CommsUI); the default is its value.
    public init(
        backend: any ChatBackend,
        threadID: String,
        thread: CommsThread? = nil,
        gapMinutes: Int = 60,
        calendar: Calendar = .autoupdatingCurrent,
        pageSize: Int = 50,
        refetchDelay: Duration = .milliseconds(300),
        outbox: Outbox? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.outbox = outbox ?? Outbox(backend: backend, now: now)
        self.reactionNow = now
        self.backend = backend
        self.threadID = threadID
        self.thread = thread
        self.gapMinutes = gapMinutes
        self.calendar = calendar
        self.pageSize = pageSize
        headerRefetch = RefetchCoalescer(delay: refetchDelay, maxConcurrent: 1, fetch: { [weak self] id in
            guard let self, let d = try? await self.backend.thread(id: id) else { return }
            self.applyDetail(d)
        })
        self.outbox.register(self)
        // Entries from before this store (the owner came back to the conversation) show at once.
        if !self.outbox.pending(threadID: threadID).isEmpty { relayout() }
    }

    // MARK: Loading

    /// Fetch the newest page (and the thread detail), replacing what is shown.
    public func loadLatest() async {
        generation += 1
        let gen = generation
        isLoading = true
        // A fresh newest page supersedes any stalled older paging.
        isStalled = false
        defer { if gen == generation { isLoading = false } }

        async let detail = try? backend.thread(id: threadID)
        do {
            var page = try await backend.messages(threadID: threadID, before: nil, limit: pageSize, topic: viewTopic)
            var loaded = page.messages
            var empties = 0
            // "messages: [] with hasMore" means keep paging, not stop.
            while loaded.isEmpty, page.hasMore, let cursor = page.before, empties < Self.maxEmptyPages {
                empties += 1
                page = try await backend.messages(threadID: threadID, before: cursor, limit: pageSize, topic: viewTopic)
                loaded = page.messages
            }
            let d = await detail
            guard gen == generation else { return }
            if let d { applyDetail(d) }
            // Live messages that arrived while this page was in flight stay.
            let ids = Set(loaded.map(\.id))
            let newest = loaded.last?.sentAt ?? .distantPast
            let live = messages.filter { !ids.contains($0.id) && $0.sentAt > newest }
            messages = loaded + live
            before = page.before
            hasMore = page.hasMore && page.before != nil
            isStalled = loaded.isEmpty && hasMore
            clearErrors()
            relayout()
        } catch {
            let d = await detail
            guard gen == generation, !(error is CancellationError) else { return }
            if let d { applyDetail(d) }
            failedOlder = false
            record(error)
        }
    }

    /// Catch up after a gap (the app back from the background, a reconnect): fetch the newest
    /// page and MERGE it into what is loaded, keeping the older pages the reader scrolled
    /// through. Messages in the page replace loaded ones with the same id (edits, reactions,
    /// receipts); newer ones are added. Only when the page does not overlap what is loaded
    /// (more than a page arrived meanwhile) is the history reset to the newest page, as
    /// `loadLatest()` does. With nothing loaded yet it is `loadLatest()`.
    public func refreshLatest() async {
        guard !messages.isEmpty, !isLoading else { return await loadLatest() }
        let gen = generation
        async let detail = try? backend.thread(id: threadID)
        do {
            let page = try await backend.messages(threadID: threadID, before: nil, limit: pageSize, topic: viewTopic)
            let d = await detail
            guard gen == generation else { return }
            if let d { applyDetail(d) }
            let loadedIDs = Set(messages.map(\.id))
            let overlaps = page.messages.contains { loadedIDs.contains($0.id) }
            guard overlaps || page.messages.isEmpty else {
                // A gap bigger than a page: the loaded history no longer joins up.
                return await loadLatest()
            }
            let fresh = Dictionary(page.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            for i in messages.indices { if let f = fresh[messages[i].id] { messages[i] = f } }
            let newest = messages.last?.sentAt ?? .distantPast
            let added = page.messages.filter { !loadedIDs.contains($0.id) }
            for m in added {
                if m.sentAt >= newest { messages.append(m) } else {
                    let i = messages.lastIndex(where: { $0.sentAt <= m.sentAt }).map { $0 + 1 } ?? 0
                    messages.insert(m, at: i)
                }
            }
            messages.sort { $0.sentAt < $1.sentAt }
            clearErrors()
            relayout()
        } catch {
            let d = await detail
            guard gen == generation, !(error is CancellationError) else { return }
            if let d { applyDetail(d) }
            record(error)
        }
    }

    /// Fetch the page before the oldest loaded message and prepend what is not shown yet.
    /// Pages that add nothing new (empty with `hasMore`, or only messages already shown) are
    /// followed up to `maxEmptyPages` times; past that the store is `isStalled`. Concurrent
    /// calls collapse into one request. Every request bumps `olderLoadCount` when it ends.
    public func loadOlder() async {
        guard hasMore, let cursor = before, !isLoadingOlder, !isLoading else { return }
        let gen = generation
        isLoadingOlder = true
        isStalled = false
        defer {
            isLoadingOlder = false
            olderLoadCount += 1
        }
        do {
            var next = cursor
            var empties = 0
            var added: [CommsMessage] = []
            while true {
                let page = try await backend.messages(threadID: threadID, before: next, limit: pageSize, topic: viewTopic)
                guard gen == generation else { return }
                let shown = Set(messages.map(\.id))
                added = page.messages.filter { !shown.contains($0.id) }
                before = page.before
                hasMore = page.hasMore && page.before != nil
                guard added.isEmpty, hasMore, let cursor = before else { break }
                empties += 1
                if empties > Self.maxEmptyPages { break }
                next = cursor
            }
            messages.insert(contentsOf: added, at: 0)
            isStalled = added.isEmpty && hasMore
            clearErrors()
            relayout()
        } catch {
            guard gen == generation, !(error is CancellationError) else { return }
            failedOlder = true
            record(error)
        }
    }

    /// Repeat what failed (the banner's Retry): the older page, or the newest page.
    public func retry() async {
        if failedOlder, !messages.isEmpty { await loadOlder() } else { await loadLatest() }
    }

    // MARK: Live events

    /// Apply one live event for this thread. `message.created` appends (by send time),
    /// `message.updated` / `reaction.changed` replace by id, `message.deleted` marks the
    /// message unsent; `thread.updated` refetches the header (coalesced), `reset` reloads.
    public func apply(_ event: CommsEvent) {
        switch event.kind {
        case .reset:
            pendingWork = Task { await loadLatest() }
            return
        default:
            break
        }
        guard event.threadID == threadID else { return }
        // A forum showing one topic: another topic's messages are not part of this view.
        if let t = selectedTopicID, let m = Self.message(in: event), let mt = m.topic?.id, mt != t, event.kind != .threadUpdated { return }
        switch event.kind {
        case .messageCreated:
            guard let m = Self.message(in: event) else { return }
            // A live message means the conversation moved on: drop a stale "Load Earlier" pill.
            isStalled = false
            upsert(m)
        case .messageUpdated, .reactionChanged:
            guard var m = Self.message(in: event), let i = messages.firstIndex(where: { $0.id == m.id }) else { return }
            Self.keepReadState(&m, from: messages[i])
            messages[i] = m
            relayout()
        case .messageDeleted:
            let id = Self.message(in: event)?.id ?? event.payload["messageId"]?.stringValue
            guard let id, let i = messages.firstIndex(where: { $0.id == id }) else { return }
            if let m = Self.message(in: event), m.redacted { messages[i] = m } else { messages[i].redacted = true }
            relayout()
        case .threadUpdated:
            if messages.isEmpty, loadError != nil || sourceError != nil, !isLoading {
                // The first load failed — e.g. a conversation just started from New Message that
                // the server had not projected yet (404): it exists now, load it.
                pendingWork = Task { await loadLatest() }
                return
            }
            headerRefetch.request(threadID)
            pendingWork = Task { [headerRefetch] in await headerRefetch?.idle() }
        default:
            break
        }
    }

    /// Delivery only moves forward (sprint Task 8): an update that arrives out of order — a
    /// BlueBubbles "delivered" webhook after the "read" one, a late plain bridge status —
    /// never takes a delivered / read message back. A failure is shown as it comes.
    static func keepReadState(_ m: inout CommsMessage, from old: CommsMessage) {
        func rank(_ d: CommsDelivery?) -> Int {
            switch d { case .sent?: 1; case .delivered?: 2; case .read?: 3; default: 0 }
        }
        guard m.sender.isSelf, m.delivery != .failed, rank(old.delivery) > rank(m.delivery), rank(m.delivery) > 0 else { return }
        m.delivery = old.delivery
        if m.readAt == nil { m.readAt = old.readAt }
        if m.readBy == nil { m.readBy = old.readBy }
    }

    // MARK: Sending

    /// Send what the composer holds: each attachment as its own message (each with its own
    /// clientId), then the text. They show at once as pending bubbles ("Sending…") and go out
    /// one after another; returns when this batch has been answered. A failure leaves its
    /// bubble "Not Delivered" — nothing is ever retried without the owner's Try Again.
    public func send(text: String, attachments: [OutgoingAttachment] = [], replyTo: CommsMessage? = nil, mentions: [ComposerMention] = []) async {
        // `@Omni …` is a private instruction (D9): it never goes to the chat, whatever the caller.
        guard canSend, !OmniStore.addressesOmni(text) else {
            // The composer cleared its draft; nothing must vanish silently.
            for a in attachments { a.deleteFile() }
            return
        }
        // A refused-for-sure attachment never leaves (Ogg voice to iMessage/SMS → 415): the
        // composer records AAC there, this only guards other callers.
        let network = sendNetwork
        let (accepted, refused) = attachments.reduce(into: ([OutgoingAttachment](), [OutgoingAttachment]())) { acc, a in
            if a.kind == .voice, !VoiceNoteFormat.accepts(network, mime: a.mime) { acc.1.append(a) } else { acc.0.append(a) }
        }
        for a in refused { a.deleteFile() }
        // No reply where the network refuses them (iMessage / SMS): sent as a plain message.
        let replyTo = canReply ? replyTo : nil
        let reply = replyTo.map { m in
            CommsMessage.Reply(messageId: m.id, snippet: m.body?.plain ?? "", senderName: m.sender.isSelf ? "You" : m.sender.isOmni ? "Omni" : m.sender.name)
        }
        if isEmail {
            // Email: text only, with the header the composer showed. An attachment is never dropped
            // silently: it stays in the transcript as "Not Delivered" with the reason.
            if !accepted.isEmpty {
                outbox.refuse(threadID: threadID, attachments: accepted,
                              failure: CommsSendFailure(reason: .unsupportedNetwork, message: "Attachments can't be sent by email from Comms yet."))
            }
            guard let header = emailReply else { return }
            await outbox.send(threadID: threadID, text: text, attachments: [], replyTo: nil, email: header)
            return
        }
        // Mentions only where they are sent as mentions (else they stay plain names).
        await outbox.send(threadID: threadID, text: text, attachments: accepted, replyTo: reply,
                          mentions: canMention ? mentions : [], channel: outgoingChannelPick, topic: sendTopic)
    }

    /// The failed bubble's Try Again: resend with the SAME clientId.
    public func retrySend(clientID: String) async { await outbox.retry(clientID: clientID) }

    /// "Send Again as New Message" (past the server's safe-retry window).
    public func resendAsNew(clientID: String) async { await outbox.resendAsNew(clientID: clientID) }

    /// Remove a failed message from the transcript.
    public func discardSend(clientID: String) { outbox.discard(clientID: clientID) }

    /// Reply is offered for this message: the channel can send and declares replies, and it is
    /// a real (echoed), live, non-system message.
    public func canReply(to m: CommsMessage) -> Bool {
        // `canReply`: send + reply declared, and a network that accepts sent replies.
        canReply && PendingSend.clientID(ofMessageID: m.id) == nil && !m.redacted && m.system == nil
    }

    /// iMessage / SMS (BlueBubbles, no Private API) cannot send threaded replies, but Reply is
    /// still offered there (owner ruling 2026-11-22): the composer quotes the message and the
    /// text goes out as an ordinary message, WITHOUT `replyTo` (`canReply` stays false).
    public func canQuoteReply(to m: CommsMessage) -> Bool {
        guard canSend, !canReply, let network = sendNetwork, !network.supportsSentReplies else { return false }
        return PendingSend.clientID(ofMessageID: m.id) == nil && !m.redacted && m.system == nil
    }

    /// The menu offers Reply: a threaded reply, or a quote where the network has none.
    public func offersReply(to m: CommsMessage) -> Bool { canReply(to: m) || canQuoteReply(to: m) }

    /// Shown under the quoted message while replying where replies can't be threaded.
    public var replyNote: String? {
        guard replyTarget != nil, !canReply else { return nil }
        let name = sendNetwork == .sms ? "SMS" : (sendNetwork?.displayName ?? "This network")
        return "Sent as a normal message — \(name) threaded replies aren't available"
    }

    /// Start a reply to `m` (the composer shows it above the field).
    public func beginReply(to m: CommsMessage) {
        guard offersReply(to: m) else { return }
        replyTarget = m
    }

    public func cancelReply() { replyTarget = nil }

    /// What the composer's Send does: the draft goes out as a reply when one was started.
    public func sendComposed(text: String, attachments: [OutgoingAttachment] = [], mentions: [ComposerMention] = []) async {
        let reply = replyTarget
        replyTarget = nil
        await send(text: text, attachments: attachments, replyTo: reply, mentions: mentions)
    }

    /// The pending send a transcript message stands for (nil for server messages).
    public func pendingSend(for message: CommsMessage) -> PendingSend? {
        guard let id = PendingSend.clientID(ofMessageID: message.id) else { return nil }
        return outbox.pendingSend(clientID: id)
    }

    /// The outbox changed this thread's entries.
    func outboxChanged(reconciling: Bool) {
        guard !isRelayouting else { return }
        relayout()
        // Email: the server said the recipients changed — fetch the header again (what Send sends).
        let stale = pendingSends.contains { $0.failure?.reason == .other("target_changed") && !refreshedFor.contains($0.clientID) }
        if stale {
            for p in pendingSends where p.failure?.reason == .other("target_changed") { refreshedFor.insert(p.clientID) }
            headerRefetch.request(threadID)
        }
    }
    @ObservationIgnored private var refreshedFor: Set<String> = []

    static func sendFailure(_ error: any Error) -> CommsSendFailure {
        switch error {
        case CommsError.sendFailed(let f): return f
        case PrismError.notSignedIn, PrismError.signedOut, PrismError.unauthorized:
            return CommsSendFailure(reason: .deviceRequired)
        case CommsError.clientScope:
            return CommsSendFailure(reason: .other("client_scope"), message: "This sign-in can't send.")
        default:
            // Unknown: it may have gone out, so never resend it on our own.
            return CommsSendFailure(reason: .outcomeUnknown, maybeSent: true)
        }
    }

    /// Sender id for the owner's pending bubbles before any of their messages is loaded.
    static let localSelfID = "comms:self"

    private func pendingMessage(_ p: PendingSend) -> CommsMessage {
        let channel = p.channel ?? thread?.channels.first ?? CommsChannelRef(network: thread?.networks.first ?? .unknown(""))
        let sender = CommsMessage.Sender(id: selfSenderIDs.sorted().first ?? Self.localSelfID, name: "Me", isSelf: true)
        let delivery: CommsDelivery
        var error: String?
        switch p.state {
        case .sending: delivery = .pending
        case .sent: delivery = .sent
        case .failed(let f):
            delivery = .failed
            error = f.displayText
        }
        var body: CommsRichText?
        var attachments: [CommsAttachment] = []
        var reply: CommsMessage.Reply?
        switch p.content {
        case .text(let text, let r, let mentions):
            body = mentions.isEmpty
                ? CommsRichText(spans: [.text(text)], plain: text, jumboEmoji: p.email == nil && Self.isJumboEmoji(text))
                : MentionText.richText(text, mentions: mentions)
            reply = r
        case .attachment(let a):
            let picture = a.kind == .image
            attachments = [CommsAttachment(kind: a.attachmentKind, mime: a.mime, size: a.data.count, w: a.pixelWidth, h: a.pixelHeight,
                                           durationMs: a.durationMs, name: a.filename,
                                           mediaToken: a.localToken, thumbToken: picture ? a.localToken : nil)]
        }
        let id = PendingSend.messageID(for: p.clientID)
        return CommsMessage(id: id, threadId: threadID, channel: channel,
                            source: .init(network: channel.network, eventId: p.eventID ?? id, ref: ""),
                            sender: sender, sentAt: p.createdAt, body: body,
                            email: p.email.map { CommsMessage.Email(subject: $0.subject, from: "", to: $0.to, cc: $0.cc) },
                            attachments: attachments, replyTo: reply,
                            delivery: delivery, deliveryError: error, topic: p.topic)
    }

    /// One to three emoji and nothing else: Messages draws them large with no bubble.
    static func isJumboEmoji(_ text: String) -> Bool {
        let chars = text.filter { !$0.isWhitespace }
        guard (1...3).contains(chars.count) else { return false }
        return chars.allSatisfy { c in
            guard let first = c.unicodeScalars.first else { return false }
            return first.properties.isEmojiPresentation || (c.unicodeScalars.count > 1 && first.properties.isEmoji)
        }
    }

    // MARK: Internals

    private func upsert(_ m: CommsMessage) {
        if let i = messages.firstIndex(where: { $0.id == m.id }) {
            messages[i] = m
        } else if let last = messages.last, m.sentAt < last.sentAt {
            // Out of order (a bridge backfill): place it by send time.
            let i = messages.lastIndex(where: { $0.sentAt <= m.sentAt }).map { $0 + 1 } ?? 0
            // Older than everything loaded while more history exists: it belongs to an older page.
            if i == 0, hasMore { return }
            messages.insert(m, at: i)
        } else {
            messages.append(m)
        }
        relayout()
    }

    private func applyDetail(_ d: CommsThreadDetail) {
        let wasGroup = isGroup
        thread = d.thread
        members = d.members
        if contact != d.contact { contact = d.contact }
        capabilities = d.capabilities
        if emailDetail != d.email {
            emailDetail = d.email
            if d.email?.replyAll == nil { emailReplyAll = false }
        }
        let newTopics = d.topics ?? []
        if topics != newTopics { topics = newTopics }
        if let t = selectedTopicID, !newTopics.isEmpty, !newTopics.contains(where: { $0.id == t }) {
            // The topic is gone (closed / left): back to All Topics.
            selectTopic(nil)
        }
        if isGroup != wasGroup { relayout() }
    }

    private func relayout() {
        let ids = Set(messages.lazy.filter(\.sender.isSelf).map(\.sender.id))
        if ids != selfSenderIDs { selfSenderIDs = ids }
        let t = reactionNow()
        for m in messages where m.sender.isSelf && (m.clientId ?? "").isEmpty && arrivals[m.id] == nil { arrivals[m.id] = t }
        if arrivals.count + echoClientIDs.count > 2 * messages.count + 64 {
            // Forget messages no longer loaded (a reload replaced the history).
            let loaded = Set(messages.lazy.map(\.id))
            arrivals = arrivals.filter { loaded.contains($0.key) }
            echoClientIDs = echoClientIDs.filter { loaded.contains($0.key) }
        }
        isRelayouting = true
        let adopted = outbox.reconcile(threadID: threadID, messages: messages, arrivedAt: { [arrivals] in arrivals[$0] })
        isRelayouting = false
        for (mid, cid) in adopted where echoClientIDs[mid] != cid {
            // One row identity per clientId: a newer match moves it.
            for (other, c) in echoClientIDs where c == cid { echoClientIDs[other] = nil }
            echoClientIDs[mid] = cid
        }
        var shown = withReactions(merged())
        // One topic on screen: its label would only repeat the header (labels show in All Topics).
        if selectedTopicID != nil { for i in shown.indices { shown[i].topic = nil } }
        rows = TranscriptLayout.rows(for: shown, isGroup: isGroup, gapMinutes: gapMinutes, calendar: calendar)
        let inbound = messages.last { !$0.sender.isSelf && $0.system == nil && !$0.redacted }?.channel
        if inbound != latestInboundChannel { latestInboundChannel = inbound }
        rowsObserver?(rows)
        if let p = forumReadPoint, p != lastReadPoint {
            lastReadPoint = p
            onReadPointChange?()
        }
    }

    /// A reaction change started, finished or was undone.
    func reactionsChanged() { relayout() }

    /// The message as drawn (the owner's pending reactions included).
    func displayedMessage(id: String) -> CommsMessage? {
        guard let m = messages.first(where: { $0.id == id }) else { return nil }
        return withReactions([m]).first
    }

    private var reactionSelfID: String { selfSenderIDs.sorted().first ?? Self.localSelfID }

    /// Drop the changes the server now shows (or that waited too long), then draw the rest.
    private func withReactions(_ all: [CommsMessage]) -> [CommsMessage] {
        guard !reactionOps.isEmpty else { return all }
        let now = reactionNow()
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, ops) in reactionOps {
            guard let m = byID[id] else { continue }
            let keep = ReactionOverlay.prune(ops, against: m.reactions, now: now)
            reactionOps[id] = keep.isEmpty ? nil : keep
        }
        return all.map { m in
            guard let ops = reactionOps[m.id] else { return m }
            var m = m
            m.reactions = ReactionOverlay.apply(ReactionOverlay.effective(ops), to: m.reactions, selfID: reactionSelfID, selfIDs: selfSenderIDs)
            return m
        }
    }


    /// The loaded messages with the pending ones placed by time (normally all at the end).
    private func merged() -> [CommsMessage] {
        let pending = outbox.visible(threadID: threadID)
        var all = messages
        if !echoClientIDs.isEmpty {
            // The echo takes over its pending bubble's row identity — unless that bubble is on
            // screen again (a content match the server's answer later contradicted).
            let shown = Set(pending.map(\.clientID))
            var used = Set<String>()
            for i in all.indices where (all[i].clientId ?? "").isEmpty {
                guard let cid = echoClientIDs[all[i].id], !shown.contains(cid), used.insert(cid).inserted else { continue }
                all[i].clientId = cid
            }
        }
        guard !pending.isEmpty else { return all }
        for p in pending {
            let m = pendingMessage(p)
            if let last = all.last, m.sentAt < last.sentAt {
                let i = all.lastIndex(where: { $0.sentAt <= m.sentAt }).map { $0 + 1 } ?? 0
                all.insert(m, at: i)
            } else {
                all.append(m)
            }
        }
        return all
    }

    private func clearErrors() {
        sourceError = nil
        loadError = nil
        failedOlder = false
    }

    private func record(_ error: any Error) {
        if case .sourceUnavailable(let network)? = error as? CommsError {
            sourceError = "Can't reach \(network.displayName) right now"
            loadError = nil
        } else {
            sourceError = nil
            loadError = "Couldn't load messages."
        }
    }

    static func message(in event: CommsEvent) -> CommsMessage? {
        guard let raw = event.payload["message"], raw != .null,
              let data = try? PrismJSON.encoder().encode(raw) else { return nil }
        return try? PrismJSON.decoder().decode(CommsMessage.self, from: data)
    }
}

extension CommsNetwork {
    /// Signal (Prism wire `"signal"`, mautrix-signal). PrismKit's `CommsNetwork` has no case for
    /// it, so it decodes as `.unknown("signal")`; this constant is that value, so `case .signal`
    /// matches it (and keeps matching if PrismKit later adds a real case and drops this one).
    public static let signal = CommsNetwork.unknown("signal")
    /// Slack (Prism wire `"slack"`, mautrix-slack). The workspace is the thread's
    /// `channels[0].accountLabel`; channels are groups titled in kebab-case.
    public static let slack = CommsNetwork.unknown("slack")

    /// Networks the server sends that PrismKit's enum has no case for, written the way the
    /// network writes itself (`String.capitalized` would give "Linkedin").
    public static let knownTitles: [String: String] = ["signal": "Signal", "slack": "Slack", "instagram": "Instagram", "linkedin": "LinkedIn"]

    /// The network's name as people say it ("WhatsApp", "iMessage").
    public var displayName: String {
        switch self {
        case .imessage: "iMessage"
        case .sms: "SMS"
        case .whatsapp: "WhatsApp"
        case .telegram: "Telegram"
        case .messenger: "Messenger"
        case .x: "X"
        case .discord: "Discord"
        case .email: "Email"
        case .matrix: "Matrix"
        case .instagram: "Instagram"
        case .linkedin: "LinkedIn"
        case .unknown(let s): Self.knownTitles[s.lowercased()] ?? s.capitalized
        }
    }
}

extension CommsThread {
    /// The account the thread lives in when the server names one: the Slack workspace, or a
    /// second account on a network ("Work WhatsApp"). Nil for the only account on a network.
    public var accountLabel: String? {
        channels.lazy.compactMap { $0.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}

/// One message the owner sent from this device, until the server's echo replaces it.
public struct PendingSend: Identifiable, Sendable, Equatable {
    /// The conversation it was sent to.
    public let threadID: String
    public enum Content: Sendable, Equatable {
        case text(String, replyTo: CommsMessage.Reply?, mentions: [CommsMention] = [])
        case attachment(OutgoingAttachment)
    }
    public enum State: Sendable, Equatable {
        /// On its way ("Sending…").
        case sending
        /// The server accepted it (event id known); waiting for the echo.
        case sent(eventID: String)
        /// "Not Delivered": shown with a red ! until Try Again or Delete.
        case failed(CommsSendFailure)
    }

    /// The `clientId` the server sees (a UUID; reused by Try Again).
    public let clientID: String
    /// Email threads: the To/Cc/Subject the composer showed (sent with the text; nil elsewhere).
    public var email: CommsEmailDetail.Reply?
    /// Mutable: after an upload the attachment's bytes are released.
    public var content: Content
    public let createdAt: Date
    /// The channel picked in the composer (a merged conversation); nil = the thread's own.
    public var channel: CommsChannelRef? = nil
    /// A Telegram forum: the topic it goes to (never "All"); nil elsewhere.
    public var topic: CommsTopicRef? = nil
    public var state: State = .sending

    public var id: String { clientID }
    public var eventID: String? { if case .sent(let e) = state { e } else { nil } }
    public var failure: CommsSendFailure? { if case .failed(let f) = state { f } else { nil } }

    static let messagePrefix = "pending-"
    /// The transcript message id of a pending send.
    public static func messageID(for clientID: String) -> String { messagePrefix + clientID }
    /// The clientId behind a pending transcript message id (nil for server messages).
    public static func clientID(ofMessageID id: String) -> String? {
        id.hasPrefix(messagePrefix) ? String(id.dropFirst(messagePrefix.count)) : nil
    }
}

extension TimelineStore {
    /// "View Full Email" for one of this thread's messages.
    public func emailOriginal(messageID: String) async throws -> CommsEmailOriginal {
        try await backend.emailOriginal(threadID: threadID, messageID: messageID)
    }
}

/// Where an open forum has been read to: its topic on screen (nil = All Topics) and the newest
/// message shown.
public struct ForumReadPoint: Sendable, Equatable {
    public var topic: String?
    public var upTo: Date?
    public init(topic: String?, upTo: Date?) {
        self.topic = topic
        self.upTo = upTo
    }
}

/// A "View Full Email" request (sheet item).
public struct EmailOriginalRequest: Identifiable, Hashable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}
