import CommsClient
import CommsCore
import CoreGraphics
import Foundation
import ImageIO
import os

/// A `ChatBackend` over the PrismKit server fixtures, with programmable event streams.
/// Nothing here touches the network.
public final class FixtureBackend: ChatBackend {
    public enum FixtureError: Error { case missing(String) }

    struct State {
        var capabilities: Result<CommsCapabilities, any Error>
        /// The conversation list `threads(_:)` answers (mutable: see `upsertThread`).
        var threads: [CommsThread]
        var threadsNext: String?
        /// Answer `threads(_:)` with only the threads the query's folder / Unread / Network admit.
        var filtersThreadQuery = false
        /// How long `threads(_:)` takes to answer (nil = at once).
        var threadsDelay: Duration?
        /// Every `threads(_:)` query, as made.
        var threadQueries: [CommsThreadQuery] = []
        var threadsError: (any Error)?
        var continuations: [UUID: AsyncThrowingStream<CommsEvent, any Error>.Continuation] = [:]
        var requestedEventIDs: [String?] = []
        var capabilityCalls = 0
        /// Programmed message pages by thread id, then by `before` cursor ("" = the newest page).
        var messagePages: [String: [String: CommsMessagePage]] = [:]
        var messagesError: (any Error)?
        var messageRequests: [MessageRequest] = []
        var threadDetails: [String: CommsThreadDetail] = [:]
        var threadCalls = 0
        /// Programmed people (their threads are derived from the list, see `person(id:)`).
        var people: [String: CommsPerson] = [:]
        var personCalls: [String] = []
        /// `recipients(query:limit:)` calls, as made.
        var recipientQueries: [String] = []
        var recipientsDelay: Duration?
        /// `startConversation` calls, as made.
        var conversationCalls: [ConversationCall] = []
        var conversationHandler: (@Sendable (ConversationCall) throws -> CommsNewConversation?)?
        var conversationCount = 0
        /// Bytes for media tokens (nil or no answer = the placeholder PNG).
        var mediaProvider: (@Sendable (String) -> Data?)?
        var playableAudio: (@Sendable (String) throws -> (Data, String))?
        var playableCalls: [String] = []
        /// Media tokens that answer 410 (`mediaExpired`), and what `refreshMedia` swaps them for.
        var expiredMedia: Set<String> = []
        var mediaRefreshes: [String: String] = [:]
        var refreshCalls: [[String]] = []
        /// What sends answer (nil = success with a fresh event id).
        var sendHandler: (@Sendable (SendCall) throws -> CommsSendResult)?
        var sendCalls: [SendCall] = []
        var emailOriginals: [String: CommsEmailOriginal] = [:]
        var emailCalls: [ConversationCall] = []
        var sendCount = 0
        var sendEcho: SendEcho = .immediate
        /// Whether the echo carries the send's clientId (false = a sync / webhook that beat the
        /// server's ledger, as BlueBubbles' webhook often does).
        var sendEchoCarriesClientID = true
        /// How long a send takes to answer (nil = at once).
        var sendDelay: Duration?
        /// Bytes "uploaded" by attachment sends, by the echoed media token.
        var uploads: [String: Data] = [:]
        /// What reaction calls answer (nil = success); throw to fail.
        var reactionHandler: (@Sendable (ReactionCall) throws -> Void)?
        var reactionCalls: [ReactionCall] = []
        /// Read-state calls, as made ("read:<id>:<viewing>" / "unread:<id>").
        var readCalls: [String] = []
        var notifySettings = CommsNotifySettings.defaults
        var notifyAvailability = CommsNotifyAvailability(push: true, readReceipts: false)
        var settingsUpdates: [CommsNotifySettingsPatch] = []
        var pushRegistrations: [(token: Data, environment: CommsPushEnvironment, platform: CommsPushPlatform)] = []
        var reactionEcho: SendEcho = .immediate
        var reactionDelay: Duration?
        /// Pins (sprint Task 8): offered (default yes), each call as made, and a failure to throw.
        var pinsSupported = true
        // Row actions + folders (sprint Task 9)
        var rowActions: RowActionSupport = .all
        var foldersSupported = true
        var folders: [CommsChatFolder] = []
        var folderSeq = 0
        var rowCalls: [String] = []
        var rowError: (any Error)?
        var statusUndo: [String: (threadID: String, status: CommsThreadStatus?, used: Bool)] = [:]
        var pinCalls: [String] = []
        var pinError: (any Error)?
    }

    /// One reaction add (`clientID` set) or remove, as made.
    public struct ReactionCall: Sendable, Equatable {
        public var threadID: String
        public var messageID: String
        public var key: String
        public var clientID: String?
        public var isAdd: Bool { clientID != nil }
        public init(threadID: String, messageID: String, key: String, clientID: String?) {
            self.threadID = threadID
            self.messageID = messageID
            self.key = key
            self.clientID = clientID
        }
    }

    /// One send, as made.
    public struct SendCall: Sendable, Equatable {
        public var threadID: String
        public var clientID: String
        public var text: String?
        public var replyTo: String?
        public var attachment: OutgoingAttachment?
        /// Email threads: the header the composer echoed with the reply.
        public var email: CommsEmailDetail.Reply?
        public var mentions: [CommsMention] = []
        public var channel: CommsChannelRef?
        /// A forum's topic the send names (nil elsewhere).
        public var topic: String? = nil
    }

    /// Whether (and when) a successful send comes back as a `message.created` echo.
    public enum SendEcho: Sendable {
        case none
        /// Before the send returns (the echo can beat the HTTP answer).
        case immediate
        case after(Duration)
    }

    /// One `messages` call, as made.
    public struct MessageRequest: Sendable, Equatable {
        public var threadID: String
        public var before: String?
        public var limit: Int
        /// A forum's topic view (nil = All Topics / not a forum).
        public var topic: String? = nil
    }

    private let messagePage: CommsMessagePage
    let state: OSAllocatedUnfairLock<State>
    /// Full search / tidy-up state (FixtureSearch.swift).
    let searchState = FixtureSearchState()

    /// What a correct Comms server declares. (The wire models have no public memberwise
    /// initialisers, so this decodes the server's JSON.)
    public static let validCapabilities = capabilities(integration: "comms", restricted: true)

    public static func capabilities(integration: String, restricted: Bool, schemaVersions: [Int] = [1]) -> CommsCapabilities {
        let json: [String: Any] = [
            "integration": integration, "clientId": "comms-native", "restricted": restricted,
            "schemaVersions": schemaVersions,
            "operations": ["threads:read", "messages:read", "media:read", "stream:read"],
            "networks": ["telegram", "whatsapp", "imessage"],
            "send": ["enabled": true, "maxAttachmentBytes": 25 * 1024 * 1024],
        ]
        // The inputs are literals: a decode failure here is a programmer error in the fixture.
        return try! PrismJSON.decoder().decode(CommsCapabilities.self, from: JSONSerialization.data(withJSONObject: json))
    }

    public convenience init(capabilities: Result<CommsCapabilities, any Error> = .success(FixtureBackend.validCapabilities)) throws {
        try self.init(threadPage: Self.load(CommsThreadPage.self, "comms-threads"), capabilities: capabilities)
    }

    init(threadPage: CommsThreadPage, capabilities: Result<CommsCapabilities, any Error>) throws {
        messagePage = try Self.load(CommsMessagePage.self, "comms-messages")
        state = OSAllocatedUnfairLock(initialState: State(capabilities: capabilities, threads: threadPage.threads, threadsNext: threadPage.next))
        let me = WeakBackend()
        omni = FixtureOmni { threadID, text in
            guard let backend = me.value else { throw CommsOmniError.unavailable }
            // An approved draft goes out through this backend's own send path (and echoes).
            _ = try await backend.sendText(threadID: threadID, clientID: UUID().uuidString.lowercased(), text: text, replyTo: nil)
        }
        me.value = self
    }

    /// Omni in Comms, programmable (off until `omni.setAvailable(true)`).
    public let omni: FixtureOmni

    /// The three seeded staging rooms ("bob", "Trail Crew", "Alice Example") exactly as the
    /// Comms server's normalizer produced them from the staging Synapse (staging/seed.ts),
    /// mxc references replaced by synthetic tokens: list, details and one page each.
    public static func staging() throws -> FixtureBackend {
        struct Dump: Decodable {
            struct Room: Decodable { var messages: [CommsMessage]; var members: [CommsMember] }
            var threads: [CommsThread]
            var rooms: [String: Room]
        }
        let dump = try load(Dump.self, "staging-rooms")
        let backend = try FixtureBackend(threadPage: FixtureMessages.threadPage(dump.threads), capabilities: .success(validCapabilities))
        for t in dump.threads {
            let room = dump.rooms[t.id]
            backend.setMessagePages([nil: FixtureMessages.page(room?.messages ?? [], before: nil, hasMore: false)], threadID: t.id)
            backend.setThreadDetail(FixtureMessages.detail(t, members: room?.members ?? []))
        }
        return backend
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return try PrismJSON.decoder().decode(T.self, from: Data(contentsOf: url))
    }

    // MARK: Programming

    public func setCapabilities(_ result: Result<CommsCapabilities, any Error>) {
        state.withLock { $0.capabilities = result }
    }

    /// Deliver an event to every open `events` stream.
    public func push(_ event: CommsEvent) {
        let all = state.withLock { Array($0.continuations.values) }
        for c in all { c.yield(event) }
    }

    /// End every open stream, optionally with an error.
    public func finishStreams(throwing error: (any Error)? = nil) {
        let all = state.withLock { s -> [AsyncThrowingStream<CommsEvent, any Error>.Continuation] in
            defer { s.continuations.removeAll() }
            return Array(s.continuations.values)
        }
        for c in all { if let error { c.finish(throwing: error) } else { c.finish() } }
    }

    /// Serve `pages` for `threadID`'s `messages` calls, keyed by the `before` cursor (nil = the
    /// newest page). Unprogrammed threads get the bundled fixture page.
    public func setMessagePages(_ pages: [String?: CommsMessagePage], threadID: String) {
        state.withLock { s in
            s.messagePages[threadID] = Dictionary(uniqueKeysWithValues: pages.map { ($0.key ?? "", $0.value) })
        }
    }

    /// Filter `threads(_:)` answers by the query (folder, Unread, Network), as the server does.
    /// Off by default: tests that program a page get exactly that page.
    /// Make `threads(_:)` take `delay` (a slow server; nil = at once).
    public func setThreadsDelay(_ delay: Duration?) {
        state.withLock { $0.threadsDelay = delay }
    }

    /// Every `threads(_:)` query made so far.
    public var threadQueries: [CommsThreadQuery] { state.withLock { $0.threadQueries } }

    /// Replace every thread `threads(_:)` answers with `threads` (details follow).
    public func setThreads(_ threads: [CommsThread]) {
        state.withLock { s in
            s.threads = threads
            s.threadsNext = nil
            for t in threads { s.threadDetails[t.id] = FixtureMessages.detail(t) }
        }
    }

    /// Make `threads(_:)` fail with `error` (nil = answer normally).
    public func setThreadsError(_ error: (any Error)?) {
        state.withLock { $0.threadsError = error }
    }

    public func setFiltersThreadQuery(_ on: Bool) {
        state.withLock { $0.filtersThreadQuery = on }
    }

    /// Replace (or add, at the top) a thread in the list `threads(_:)` answers, and in the
    /// detail `thread(id:)` answers (members and contact are kept).
    public func upsertThread(_ thread: CommsThread) {
        state.withLock { s in
            s.threads.removeAll { $0.id == thread.id }
            s.threads.insert(thread, at: 0)
            let old = s.threadDetails[thread.id]
            var detail = FixtureMessages.detail(thread, members: old?.members ?? [], contact: old?.contact)
            detail.email = old?.email // as the server: the email header survives a list update
            detail.topics = old?.topics // a forum keeps its topics
            s.threadDetails[thread.id] = detail
        }
    }

    /// Replace a listed thread where it stands (upsert moves it to the top); its detail follows
    /// (one helper for email's demo and search/tidy's fixture since the sprint integration).
    public func replaceThread(_ thread: CommsThread) {
        state.withLock { s in
            guard let i = s.threads.firstIndex(where: { $0.id == thread.id }) else { return }
            s.threads[i] = thread
            if var d = s.threadDetails[thread.id] { d.thread = thread; s.threadDetails[thread.id] = d }
        }
    }

    // MARK: Read state + notifications (Sprint Task 1)

    /// Read-state calls, as made: "read:<id>:<viewing|nil>[:explicit]" and "unread:<id>".
    public var readCalls: [String] { state.withLock { $0.readCalls } }
    public var settingsUpdates: [CommsNotifySettingsPatch] { state.withLock { $0.settingsUpdates } }
    /// What the "server" holds now (tests change it behind a store's back).
    public var notifySettings: CommsNotifySettings {
        get { state.withLock { $0.notifySettings } }
        set { state.withLock { $0.notifySettings = newValue } }
    }
    public var pushRegistrationCount: Int { state.withLock { $0.pushRegistrations.count } }
    public func setNotifyAvailability(_ a: CommsNotifyAvailability) { state.withLock { $0.notifyAvailability = a } }

    /// Forum reads as made: (thread, topic, upTo).
    public var forumReads: [(threadID: String, topic: String?, upTo: Date?)] { forumReadLog.withLock { $0 } }
    private let forumReadLog = OSAllocatedUnfairLock<[(threadID: String, topic: String?, upTo: Date?)]>(initialState: [])
    public func markRead(threadID: String, upTo: Date?, viewing: Bool?, explicit: Bool, topic: String?) async throws {
        forumReadLog.withLock { $0.append((threadID, topic, upTo)) }
        try await markRead(threadID: threadID, upTo: upTo, viewing: viewing, explicit: explicit)
    }

    public func markRead(threadID: String, upTo: Date?, viewing: Bool?, explicit: Bool) async throws {
        state.withLock { s in
            s.readCalls.append("read:\(threadID):\(viewing.map(String.init) ?? "nil")\(explicit ? ":explicit" : "")")
            Self.setUnread(&s, threadID) { $0 = 0 }
        }
    }
    public func markUnread(threadID: String) async throws {
        state.withLock { s in
            s.readCalls.append("unread:\(threadID)")
            Self.setUnread(&s, threadID) { $0 = max($0, 1) }
        }
    }
    private static func setUnread(_ s: inout State, _ id: String, _ change: (inout Int) -> Void) {
        if let i = s.threads.firstIndex(where: { $0.id == id }) { change(&s.threads[i].unread.count) }
        if var d = s.threadDetails[id] {
            change(&d.thread.unread.count)
            s.threadDetails[id] = d
        }
    }
    public func unreadSummary() async throws -> CommsStatusCounts.Unread? {
        state.withLock { s in
            let unread = s.threads.filter { $0.unread.count > 0 && !$0.muted && $0.folder == .inbox }
            let attention = unread.filter { $0.status == .urgent || $0.status == .actionRequired }
            return CommsStatusCounts.Unread(threads: unread.count, attention: attention.count)
        }
    }
    public func notificationSettings() async throws -> CommsNotifySettingsResponse {
        state.withLock { CommsNotifySettingsResponse(settings: $0.notifySettings, available: $0.notifyAvailability) }
    }
    public func updateNotificationSettings(_ patch: CommsNotifySettingsPatch) async throws -> CommsNotifySettingsResponse {
        state.withLock { s in
            s.settingsUpdates.append(patch)
            s.notifySettings = s.notifySettings.applying(patch)
            return CommsNotifySettingsResponse(settings: s.notifySettings, available: s.notifyAvailability)
        }
    }
    public func registerPush(deviceToken: Data, environment: CommsPushEnvironment, platform: CommsPushPlatform) async throws -> CommsPushRegistration {
        state.withLock { s in
            s.pushRegistrations.append((deviceToken, environment, platform))
            return CommsPushRegistration(ok: true, pushEnabled: s.notifyAvailability.push)
        }
    }

    /// The thread `threads(_:)` / `thread(id:)` currently answer for `id`.
    public func currentThread(id: String) -> CommsThread? {
        state.withLock { s in s.threadDetails[id]?.thread ?? s.threads.first { $0.id == id } }
    }

    /// The members `thread(id:)` currently answers for `id` (empty when none are programmed).
    public func currentMembers(id: String) -> [CommsMember] {
        state.withLock { $0.threadDetails[id]?.members ?? [] }
    }

    /// Add (or replace, by id) `message` in `threadID`'s newest programmed page, so a reopened
    /// transcript shows it. Returns false when the thread has no programmed newest page.
    @discardableResult
    public func upsertNewestMessage(_ message: CommsMessage, threadID: String) -> Bool {
        state.withLock { s in
            guard let page = s.messagePages[threadID]?[""] else { return false }
            var messages = page.messages
            if let i = messages.firstIndex(where: { $0.id == message.id }) { messages[i] = message } else { messages.append(message) }
            s.messagePages[threadID]?[""] = FixtureMessages.page(messages, before: page.before, hasMore: page.hasMore)
            return true
        }
    }

    /// The messages of `threadID`'s newest programmed page (empty when none is programmed).
    public func newestMessages(threadID: String) -> [CommsMessage] {
        state.withLock { $0.messagePages[threadID]?[""]?.messages ?? [] }
    }

    /// Answer `media(token:)` with `provider`'s PNG bytes where it has some.
    public func setMediaProvider(_ provider: (@Sendable (String) -> Data?)?) {
        state.withLock { $0.mediaProvider = provider }
    }

    /// Make `media(token:)` answer 410 for `tokens`, and `refreshMedia` swap them per `refreshes`.
    public func setExpiredMedia(_ tokens: Set<String>, refreshes: [String: String] = [:]) {
        state.withLock { $0.expiredMedia = tokens; $0.mediaRefreshes = refreshes }
    }

    /// `refreshMedia(tokens:)` calls, as made.
    public var mediaRefreshCalls: [[String]] { state.withLock { $0.refreshCalls } }

    /// Make every `messages` call throw `error` (nil = answer again).
    public func setMessagesError(_ error: (any Error)?) {
        state.withLock { $0.messagesError = error }
    }

    /// Answer `thread(id:)` with `detail` for its thread id.
    public func setThreadDetail(_ detail: CommsThreadDetail) {
        state.withLock { $0.threadDetails[detail.thread.id] = detail }
    }

    /// Answer `person(id:)` for `person.id`. Its `threads` are ignored: the answer lists the
    /// current threads whose `personId` is this person, or whose details name them as a member.
    public func setPerson(_ person: CommsPerson) {
        state.withLock { $0.people[person.id] = person }
    }

    /// One `startConversation` call, as made.
    public struct ConversationCall: Sendable, Equatable {
        public var clientID: String
        public var handle: String
        public var network: String
        public var text: String
    }

    public var recipientQueries: [String] { state.withLock { $0.recipientQueries } }
    public var conversationCalls: [ConversationCall] { state.withLock { $0.conversationCalls } }
    public func setRecipientsDelay(_ delay: Duration?) { state.withLock { $0.recipientsDelay = delay } }
    /// Answer `startConversation` from `handler` (throw = a failure; nil = the default:
    /// an existing iMessage/SMS DM with that address, else a new conversation with the message).
    public func setConversationHandler(_ handler: (@Sendable (ConversationCall) throws -> CommsNewConversation?)?) {
        state.withLock { $0.conversationHandler = handler }
    }

    /// The ids `person(id:)` was asked for, in order.
    public var personCalls: [String] { state.withLock { $0.personCalls } }

    /// Every `messages` call, in order.
    public var messageRequests: [MessageRequest] { state.withLock { $0.messageRequests } }

    /// The `lastEventID` of each `events` call, in order.
    public var requestedEventIDs: [String?] { state.withLock { $0.requestedEventIDs } }
    public var capabilityCalls: Int { state.withLock { $0.capabilityCalls } }
    /// How many `thread(id:)` calls were made.
    public var threadCalls: Int { state.withLock { $0.threadCalls } }

    /// Answer sends with `handler` (throw to fail; nil = succeed).
    public func setSendHandler(_ handler: (@Sendable (SendCall) throws -> CommsSendResult)?) {
        state.withLock { $0.sendHandler = handler }
    }

    /// Make every send take `delay` before it answers (nil = at once).
    public func setSendDelay(_ delay: Duration?) {
        state.withLock { $0.sendDelay = delay }
    }

    public func setSendEchoCarriesClientID(_ carries: Bool) {
        state.withLock { $0.sendEchoCarriesClientID = carries }
    }

    public func setSendEcho(_ echo: SendEcho) {
        state.withLock { $0.sendEcho = echo }
    }

    public var sendLimits: CommsSendCapabilities? {
        state.withLock { s in (try? s.capabilities.get())?.send }
    }

    /// Every send, in order (retries included).
    public var sendCalls: [SendCall] { state.withLock { $0.sendCalls } }

    /// Answer reaction calls with `handler` (throw to fail; nil = succeed).
    public func setReactionHandler(_ handler: (@Sendable (ReactionCall) throws -> Void)?) {
        state.withLock { $0.reactionHandler = handler }
    }
    /// Whether a successful reaction comes back as `reaction.changed` (default: at once).
    public func setReactionEcho(_ echo: SendEcho) { state.withLock { $0.reactionEcho = echo } }
    public func setReactionDelay(_ delay: Duration?) { state.withLock { $0.reactionDelay = delay } }
    /// Every reaction call, in order.
    public var reactionCalls: [ReactionCall] { state.withLock { $0.reactionCalls } }

    public func addReaction(threadID: String, messageID: String, clientID: String, key: String) async throws -> CommsSendResult {
        let n = try await handleReaction(ReactionCall(threadID: threadID, messageID: messageID, key: key, clientID: clientID))
        return CommsSendResult(clientId: clientID, eventId: "$fx_react_\(n)")
    }

    public func removeReaction(threadID: String, messageID: String, key: String) async throws {
        _ = try await handleReaction(ReactionCall(threadID: threadID, messageID: messageID, key: key, clientID: nil))
    }

    private func handleReaction(_ call: ReactionCall) async throws -> Int {
        let (handler, n, echo, delay) = state.withLock { s -> ((@Sendable (ReactionCall) throws -> Void)?, Int, SendEcho, Duration?) in
            s.reactionCalls.append(call)
            return (s.reactionHandler, s.reactionCalls.count, s.reactionEcho, s.reactionDelay)
        }
        if let delay { try? await Task.sleep(for: delay) }
        try handler?(call)
        switch echo {
        case .none: break
        case .immediate: echoReaction(call)
        case .after(let d):
            Task { [self] in
                try? await Task.sleep(for: d)
                echoReaction(call)
            }
        }
        return n
    }

    /// The server's projection of the owner's reaction: `mine` on the key, the account in
    /// `senders`, then `reaction.changed` for the message.
    private func echoReaction(_ call: ReactionCall) {
        guard var m = newestMessages(threadID: call.threadID).first(where: { $0.id == call.messageID }) else { return }
        var reactions = m.reactions
        let me = CommsReaction.Sender(id: FixtureMessages.selfID, name: "Me", eventId: "$fx_react")
        if call.isAdd {
            if let i = reactions.firstIndex(where: { $0.key == call.key }) {
                guard !reactions[i].mine else { return }
                reactions[i].mine = true
                reactions[i].count += 1
                reactions[i].senders.append(me)
            } else {
                reactions.append(CommsReaction(key: call.key, count: 1, mine: true, senders: [me]))
            }
        } else {
            guard let i = reactions.firstIndex(where: { $0.key == call.key && $0.mine }) else { return }
            reactions[i].mine = false
            reactions[i].count -= 1
            reactions[i].senders.removeAll { $0.id == FixtureMessages.selfID }
            if reactions[i].count <= 0 { reactions.remove(at: i) }
        }
        m.reactions = reactions
        upsertNewestMessage(m, threadID: call.threadID)
        push(FixtureMessages.event(.reactionChanged, m, id: "fx_reaction_\(UUID().uuidString)"))
    }

    // MARK: ChatBackend

    public func sendText(threadID: String, clientID: String, text: String, replyTo: String?) async throws -> CommsSendResult {
        try await handleSend(SendCall(threadID: threadID, clientID: clientID, text: text, replyTo: replyTo))
    }

    public func sendText(threadID: String, clientID: String, text: String, replyTo: String?, mentions: [CommsMention], channel: CommsChannelRef?) async throws -> CommsSendResult {
        try await handleSend(SendCall(threadID: threadID, clientID: clientID, text: text, replyTo: replyTo, mentions: mentions, channel: channel))
    }

    public func sendAttachment(threadID: String, clientID: String, attachment: OutgoingAttachment) async throws -> CommsSendResult {
        try await handleSend(SendCall(threadID: threadID, clientID: clientID, attachment: attachment))
    }

    public func sendEmailReply(threadID: String, clientID: String, text: String, email: CommsEmailDetail.Reply) async throws -> CommsSendResult {
        try await handleSend(SendCall(threadID: threadID, clientID: clientID, text: text, email: email))
    }

    /// "View full email" answers (by message id); unknown ids throw `threadUnavailable`.
    public func setEmailOriginal(_ o: CommsEmailOriginal, messageID: String) { state.withLock { $0.emailOriginals[messageID] = o } }
    public func emailOriginal(threadID: String, messageID: String) async throws -> CommsEmailOriginal {
        guard let o = state.withLock({ $0.emailOriginals[messageID] }) else { throw CommsError.threadUnavailable }
        return o
    }
    /// New emails started (`network` "email", `text` = body; the subject rides in `handle` after a newline).
    public var emailCalls: [ConversationCall] { state.withLock { $0.emailCalls } }
    public func startEmail(clientID: String, to: String, subject: String, text: String) async throws -> CommsNewConversation {
        let n = state.withLock { s -> Int in
            s.emailCalls.append(ConversationCall(clientID: clientID, handle: "\(to)\n\(subject)", network: "email", text: text))
            s.conversationCount += 1
            return s.conversationCount
        }
        let id = "th_email_\(n)"
        var thread = FixtureMessages.thread(id: id, title: to, network: "email")
        thread.channels[0].capabilities = CommsChannelCapabilities(reply: false, attachments: false, send: true)
        let now = Date()
        thread.lastActivityAt = now
        thread.lastMessage = FixtureMessages.preview(text: text, senderName: nil, isSelf: true, at: now)
        thread.lastMessage?.subject = subject
        var m = FixtureMessages.message(id: "fx_email_\(n)", threadID: id, network: "email", outgoing: true, at: now, text: text, delivery: "sent")
        m.email = CommsMessage.Email(subject: subject, from: "", to: [to])
        m.clientId = clientID
        upsertThread(thread)
        setMessagePages([nil: FixtureMessages.page([m], before: nil, hasMore: false)], threadID: id)
        push(CommsEvent(id: "fx_email_thread_\(n)", kind: .threadUpdated, payload: ["threadId": .string(id)]))
        return CommsNewConversation(existing: false, threadId: id, thread: thread, clientId: clientID, eventId: m.source.eventId, status: "sent")
    }

    public func sendAttachment(threadID: String, clientID: String, attachment: OutgoingAttachment, channel: CommsChannelRef?) async throws -> CommsSendResult {
        try await handleSend(SendCall(threadID: threadID, clientID: clientID, attachment: attachment, channel: channel))
    }

    // MARK: Telegram forums — as the server: a forum send names a topic (else 422 topic_required).

    public func sendText(threadID: String, clientID: String, text: String, replyTo: String?, mentions: [CommsMention], channel: CommsChannelRef?, topic: String?) async throws -> CommsSendResult {
        try requireTopic(threadID, topic)
        return try await handleSend(SendCall(threadID: threadID, clientID: clientID, text: text, replyTo: replyTo, mentions: mentions, channel: channel, topic: topic))
    }
    public func sendAttachment(threadID: String, clientID: String, attachment: OutgoingAttachment, channel: CommsChannelRef?, topic: String?) async throws -> CommsSendResult {
        try requireTopic(threadID, topic)
        return try await handleSend(SendCall(threadID: threadID, clientID: clientID, attachment: attachment, channel: channel, topic: topic))
    }
    private func requireTopic(_ threadID: String, _ topic: String?) throws {
        let topics = state.withLock { $0.threadDetails[threadID]?.topics } ?? []
        guard !topics.isEmpty else { return }
        guard let topic, topics.contains(where: { $0.id == topic }) else {
            state.withLock { $0.sendCalls.append(SendCall(threadID: threadID, clientID: "", topic: topic)) }
            throw CommsError.sendFailed(CommsSendFailure(reason: .topicRequired, message: "Choose the topic to send to.", status: 422))
        }
    }
    /// A forum topic's pages (`topic` = its id); the thread's own pages are All Topics.
    public func setMessagePages(_ pages: [String?: CommsMessagePage], threadID: String, topic: String) {
        setMessagePages(pages, threadID: "\(threadID)#topic:\(topic)")
    }
    public func messages(threadID: String, before: String?, limit: Int, topic: String?) async throws -> CommsMessagePage {
        guard let topic else { return try await messages(threadID: threadID, before: before, limit: limit) }
        let (error, pages) = state.withLock { s -> ((any Error)?, [String: CommsMessagePage]?) in
            s.messageRequests.append(MessageRequest(threadID: threadID, before: before, limit: limit, topic: topic))
            return (s.messagesError, s.messagePages["\(threadID)#topic:\(topic)"])
        }
        if let error { throw error }
        return pages?[before ?? ""] ?? FixtureMessages.page([], before: nil, hasMore: false)
    }

    private func handleSend(_ call: SendCall) async throws -> CommsSendResult {
        let (handler, n, echo, delay) = state.withLock { s -> ((@Sendable (SendCall) throws -> CommsSendResult)?, Int, SendEcho, Duration?) in
            s.sendCalls.append(call)
            s.sendCount += 1
            return (s.sendHandler, s.sendCount, s.sendEcho, s.sendDelay)
        }
        if let delay { try? await Task.sleep(for: delay) }
        let result = try handler?(call) ?? CommsSendResult(clientId: call.clientID, eventId: "$fx_sent_\(n)")
        let message = echoMessage(call, eventID: result.eventId, n: n)
        switch echo {
        case .none: break
        case .immediate: deliverEcho(message)
        case .after(let delay):
            Task { [self] in
                try? await Task.sleep(for: delay)
                deliverEcho(message)
            }
        }
        return result
    }

    /// The message the server would project from a send: from the owner, `source.eventId` =
    /// the send's event id.
    private func echoMessage(_ call: SendCall, eventID: String, n: Int) -> CommsMessage {
        let thread = currentThread(id: call.threadID)
        // The echo comes back on the channel it was sent through (a merged conversation's pick).
        let network = call.channel?.network.wire ?? thread?.channels.first?.network.wire ?? thread?.networks.first?.wire ?? "whatsapp"
        var attachments: [[String: Any]] = []
        if let a = call.attachment {
            let token = "fx_upload_\(n)"
            let bytes = a.fileURL.flatMap { try? Data(contentsOf: $0) } ?? a.data
            state.withLock { $0.uploads[token] = bytes }
            var json: [String: Any] = ["kind": a.attachmentKind.wire, "mime": a.mime, "size": bytes.count, "name": a.filename, "mediaToken": token]
            if let w = a.pixelWidth, let h = a.pixelHeight { json["w"] = w; json["h"] = h }
            if let d = a.durationMs { json["durationMs"] = d }
            if a.kind == .image { json["thumbToken"] = token }
            attachments = [json]
        }
        var m = FixtureMessages.message(id: "fx_sent_\(n)", threadID: call.threadID, network: network, outgoing: true, at: Date(),
                                        text: call.text, attachments: attachments, delivery: "sent")
        if call.text == nil { m.body = nil }
        if let e = call.email { m.email = CommsMessage.Email(subject: e.subject, from: "", to: e.to, cc: e.cc) }
        if let text = call.text, !call.mentions.isEmpty { m.body = MentionText.richText(text, mentions: call.mentions) }
        if let channel = call.channel { m.channel = channel }
        if let topic = call.topic {
            let title = state.withLock { $0.threadDetails[call.threadID]?.topics?.first { $0.id == topic }?.title } ?? topic
            m.topic = CommsTopicRef(id: topic, title: title)
        }
        m.source.eventId = eventID
        m.clientId = state.withLock { $0.sendEchoCarriesClientID } ? call.clientID : nil
        return m
    }

    private func deliverEcho(_ message: CommsMessage) {
        upsertNewestMessage(message, threadID: message.threadId)
        if var thread = currentThread(id: message.threadId) {
            thread.lastActivityAt = message.sentAt
            thread.lastMessage = FixtureMessages.preview(text: message.body?.plain ?? "Attachment", senderName: nil, isSelf: true, at: message.sentAt)
            thread.lastMessage?.subject = message.email?.subject
            upsertThread(thread)
        }
        push(FixtureMessages.event(.messageCreated, message, id: "fx_echo_\(message.id)"))
        push(CommsEvent(id: "fx_thread_\(message.id)", kind: .threadUpdated, payload: ["threadId": .string(message.threadId)]))
    }

    // MARK: Pins (sprint Task 8) — the server's rules: order 0…n-1, at most nine, idempotent.

    public var pinsSupported: Bool { state.withLock { $0.pinsSupported } }
    public func setPinsSupported(_ on: Bool) { state.withLock { $0.pinsSupported = on } }
    /// Make the next pin calls fail (nil = succeed).
    public func setPinError(_ error: (any Error)?) { state.withLock { $0.pinError = error } }
    /// "pin:<id>", "unpin:<id>", "order:<id,id>", as made.
    public var pinCalls: [String] { state.withLock { $0.pinCalls } }

    public func pin(threadID: String) async throws -> CommsThread {
        try state.withLock { s in
            s.pinCalls.append("pin:\(threadID)")
            if let e = s.pinError { throw e }
            guard let i = s.threads.firstIndex(where: { $0.id == threadID }) else { throw CommsError.threadUnavailable }
            if !s.threads[i].pinned {
                let count = s.threads.filter(\.pinned).count
                guard count < 9 else { throw CommsError.pinLimit }
                // As the server: the existing pins get a dense order (unordered ones last).
                let order = s.threads.enumerated().filter { $0.element.pinned }
                    .sorted { ($0.element.pinOrder ?? .max, $0.offset) < ($1.element.pinOrder ?? .max, $1.offset) }.map(\.offset)
                for (n, j) in order.enumerated() { s.threads[j].pinOrder = n; s.threadDetails[s.threads[j].id]?.thread = s.threads[j] }
                s.threads[i].pinned = true
                s.threads[i].pinOrder = count
                s.threadDetails[threadID]?.thread = s.threads[i]
            }
            return s.threads[i]
        }
    }

    public func unpin(threadID: String) async throws -> CommsThread {
        try state.withLock { s in
            s.pinCalls.append("unpin:\(threadID)")
            if let e = s.pinError { throw e }
            guard let i = s.threads.firstIndex(where: { $0.id == threadID }) else { throw CommsError.threadUnavailable }
            s.threads[i].pinned = false
            s.threads[i].pinOrder = nil
            s.threadDetails[threadID]?.thread = s.threads[i]
            let order = s.threads.filter(\.pinned).sorted { ($0.pinOrder ?? .max) < ($1.pinOrder ?? .max) }.map(\.id)
            for (n, id) in order.enumerated() { if let j = s.threads.firstIndex(where: { $0.id == id }) { s.threads[j].pinOrder = n } }
            return s.threads[i]
        }
    }

    public func reorderPins(_ threadIDs: [String]) async throws -> [CommsThread] {
        try state.withLock { s in
            s.pinCalls.append("order:" + threadIDs.joined(separator: ","))
            if let e = s.pinError { throw e }
            let pinned = Set(s.threads.filter(\.pinned).map(\.id))
            guard Set(threadIDs) == pinned, threadIDs.count == pinned.count else { throw CommsError.pinsChanged }
            for (n, id) in threadIDs.enumerated() { if let j = s.threads.firstIndex(where: { $0.id == id }) { s.threads[j].pinOrder = n } }
            return threadIDs.compactMap { id in s.threads.first { $0.id == id } }
        }
    }

    public func capabilities() async throws -> CommsCapabilities {
        let result = state.withLock { s -> Result<CommsCapabilities, any Error> in
            s.capabilityCalls += 1
            return s.capabilities
        }
        return try result.get()
    }

    public func threads(_ q: CommsThreadQuery) async throws -> CommsThreadPage {
        let delay = state.withLock { s -> Duration? in
            s.threadQueries.append(q)
            return s.threadsDelay
        }
        if let delay { try await Task.sleep(for: delay) }
        if let error = state.withLock({ $0.threadsError }) { throw error }
        let (threads, next, filters) = state.withLock { ($0.threads, $0.threadsNext, $0.filtersThreadQuery) }
        guard filters else { return FixtureMessages.threadPage(threads, next: next) }
        let members = state.withLock { s in s.threadDetails.mapValues { Set($0.members.compactMap(\.personId)) } }
        // As the server: `attention=true` is merged into the same status set (OR).
        let statuses = Set(q.statuses).union(q.attention ? CommsThreadStatus.needsAttention : [])
        // As the server (S4): `q` matches title OR preview, case- and diacritic-insensitive.
        let search = q.search.map { Self.fold($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0.isEmpty ? nil : $0 }
        let admitted = threads.filter { t in
            (q.inFolder.map { f in t.folderIds?.contains(f) == true && t.folder != .archived && t.folder != .spam } ?? true)
            && (q.anyFolder || t.folder == q.folder)
                && (!q.unreadOnly || t.unread.count > 0)
                && (q.networks.isEmpty || !Set(q.networks).isDisjoint(with: t.networks))
                && (statuses.isEmpty || t.status.map(statuses.contains) == true)
                && (search.map { term in Self.fold(t.title + "\n" + (t.lastMessage?.text ?? "")).contains(term) } ?? true)
                && (q.person.map { p in t.personId == p || members[t.id]?.contains(p) == true } ?? true)
        }
        // Pages of `limit` (cursor "o:<offset>") when a limit is asked for, like the server.
        guard let limit = q.limit, limit > 0 else { return FixtureMessages.threadPage(admitted, next: nil) }
        let ordered = admitted.sorted { $0.lastActivityAt > $1.lastActivityAt }
        let offset = q.cursor.flatMap { $0.hasPrefix("o:") ? Int($0.dropFirst(2)) : nil } ?? 0
        let end = min(ordered.count, offset + limit)
        let slice = offset < end ? Array(ordered[offset..<end]) : []
        return FixtureMessages.threadPage(slice, next: end < ordered.count ? "o:\(end)" : nil)
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    public func thread(id: String) async throws -> CommsThreadDetail {
        let (programmed, listed) = state.withLock { s -> (CommsThreadDetail?, CommsThread?) in
            s.threadCalls += 1
            return (s.threadDetails[id], s.threads.first { $0.id == id })
        }
        if let programmed { return programmed }
        guard let thread = listed else { throw CommsError.threadUnavailable }
        let encoded = try JSONSerialization.jsonObject(with: PrismJSON.encoder().encode(thread))
        let body = try JSONSerialization.data(withJSONObject: ["thread": encoded, "members": [Any]()] as [String: Any])
        return try PrismJSON.decoder().decode(CommsThreadDetail.self, from: body)
    }

    public func person(id: String) async throws -> CommsPerson {
        let (programmed, threads, members) = state.withLock { s in
            s.personCalls.append(id)
            return (s.people[id], s.threads, s.threadDetails.mapValues { Set($0.members.compactMap(\.personId)) })
        }
        guard var person = programmed else { throw CommsError.personUnavailable }
        person.threads = threads
            .filter { $0.personId == id || members[$0.id]?.contains(id) == true }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        return person
    }

    // MARK: Recipients / new conversations (as server-2b-report §1–2)

    public func recipients(query: String, limit: Int) async throws -> CommsRecipients {
        let delay = state.withLock { s -> Duration? in
            s.recipientQueries.append(query)
            return s.recipientsDelay
        }
        if let delay { try await Task.sleep(for: delay) }
        let (people, threads, details) = state.withLock { ($0.people, $0.threads, $0.threadDetails) }
        let q = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let words = q.split(separator: " ").map(String.init)
        let qDigits = q.filter(\.isNumber)
        func nameMatches(_ name: String) -> Bool {
            let n = Self.fold(name)
            let parts = n.split(separator: " ").map(String.init)
            return n.contains(q) || (!words.isEmpty && words.allSatisfy { w in parts.contains { $0.hasPrefix(w) } })
        }
        func dmThread(for value: String) -> String? {
            threads.first { t in
                t.kind == .dm && t.networks.contains { $0 == .imessage || $0 == .sms }
                    && ((details[t.id]?.contact?.phones.contains { $0.value == value } ?? false)
                        || (details[t.id]?.contact?.emails.contains { $0.value.lowercased() == value.lowercased() } ?? false))
            }?.id
        }
        let matched = people.values
            .filter { p in nameMatches(p.name) || (qDigits.count >= 3 && p.phones.contains { $0.value.filter(\.isNumber).contains(qDigits) })
                || (q.contains { $0.isLetter } && p.emails.contains { $0.value.lowercased().contains(q) }) }
            .sorted { $0.name < $1.name }
            .prefix(limit)
        let recips = matched.map { p in
            CommsRecipient(id: "p_\(p.id)", personId: p.id, name: p.name, avatar: p.avatar,
                           phones: p.phones.map { .init(value: $0.value, threadId: dmThread(for: $0.value)) },
                           emails: p.emails.map { .init(value: $0.value.lowercased(), threadId: dmThread(for: $0.value)) },
                           source: "person")
        }
        let ids = Set(matched.map(\.id))
        let found = threads.filter { t in
            Self.fold(t.title + "\n" + (t.lastMessage?.text ?? "")).contains(q) || (t.personId.map(ids.contains) ?? false)
        }.sorted { $0.lastActivityAt > $1.lastActivityAt }.prefix(limit)
        var handle: CommsRecipientHandle?
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("+"), qDigits.count >= 7, trimmed.allSatisfy({ $0.isNumber || " +-.()".contains($0) }) {
            let e164 = "+" + qDigits
            handle = CommsRecipientHandle(kind: .phone, value: e164, threadId: dmThread(for: e164))
        } else if trimmed.contains("@"), trimmed.split(separator: "@").last?.contains(".") == true, !trimmed.contains(" ") {
            handle = CommsRecipientHandle(kind: .email, value: trimmed.lowercased(), threadId: dmThread(for: trimmed.lowercased()))
        }
        return CommsRecipients(query: trimmed, handle: handle, people: Array(recips), threads: Array(found))
    }

    public func startConversation(clientID: String, handle: String, network: CommsClient.NewConversationNetwork, text: String) async throws -> CommsNewConversation {
        let call = ConversationCall(clientID: clientID, handle: handle, network: network.rawValue, text: text)
        let (handler, n) = state.withLock { s -> ((@Sendable (ConversationCall) throws -> CommsNewConversation?)?, Int) in
            s.conversationCalls.append(call)
            s.conversationCount += 1
            return (s.conversationHandler, s.conversationCount)
        }
        if let answer = try handler?(call) { return answer }
        let existing = try await recipients(query: handle, limit: 1).handle?.threadId
        if let existing {
            return CommsNewConversation(existing: true, threadId: existing, thread: currentThread(id: existing))
        }
        // A new one-to-one conversation holding the sent message (and the server's echo).
        let id = "th_new_\(n)"
        var thread = FixtureMessages.thread(id: id, title: handle, network: network.rawValue)
        thread.channels[0].capabilities = CommsChannelCapabilities(reply: false, attachments: true, send: true)
        let now = Date()
        thread.lastActivityAt = now
        thread.lastMessage = FixtureMessages.preview(text: text, senderName: nil, isSelf: true, at: now)
        var m = FixtureMessages.message(id: "fx_conv_\(n)", threadID: id, network: network.rawValue, outgoing: true, at: now, text: text, delivery: "sent")
        m.clientId = clientID
        upsertThread(thread)
        setMessagePages([nil: FixtureMessages.page([m], before: nil, hasMore: false)], threadID: id)
        push(CommsEvent(id: "fx_conv_thread_\(n)", kind: .threadUpdated, payload: ["threadId": .string(id)]))
        return CommsNewConversation(existing: false, threadId: id, thread: thread, clientId: clientID, eventId: m.source.eventId, status: "sent")
    }

    public func messages(threadID: String, before: String?, limit: Int) async throws -> CommsMessagePage {
        let (error, pages) = state.withLock { s -> ((any Error)?, [String: CommsMessagePage]?) in
            s.messageRequests.append(MessageRequest(threadID: threadID, before: before, limit: limit))
            return (s.messagesError, s.messagePages[threadID])
        }
        if let error { throw error }
        guard let pages else { return messagePage }
        // An unknown cursor answers an empty, final page (as the server's expired cursor would not).
        return pages[before ?? ""] ?? FixtureMessages.page([], before: nil, hasMore: false)
    }

    /// A synthetic picture (a small PNG) for any token: fixtures carry no real media.
    /// The type is sniffed from the bytes, like the server's media route (HEIC, PNG, JPEG).
    public func media(token: String) async throws -> (Data, String) {
        let (provider, upload, expired) = state.withLock { ($0.mediaProvider, $0.uploads[token], $0.expiredMedia.contains(token)) }
        if expired { throw CommsError.mediaExpired }
        if let upload { return (upload, "application/octet-stream") }
        let data = provider?(token) ?? FixtureMessages.placeholderPNG
        return (data, FixtureMessages.sniffedType(data))
    }

    /// Playable audio: what the server's `?format=m4a` would answer (tests set `playableAudioProvider`).
    public func playableAudio(token: String) async throws -> (Data, String) {
        let (provider, expired) = state.withLock { ($0.playableAudio, $0.expiredMedia.contains(token)) }
        state.withLock { $0.playableCalls.append(token) }
        if expired { throw CommsError.mediaExpired }
        if let provider { return try provider(token) }
        return try await media(token: token)
    }
    public func setPlayableAudio(_ f: (@Sendable (String) throws -> (Data, String))?) { state.withLock { $0.playableAudio = f } }
    public var playableCalls: [String] { state.withLock { $0.playableCalls } }

    public func refreshMedia(tokens: [String]) async throws -> [String: String] {
        state.withLock { s in
            s.refreshCalls.append(tokens)
            return s.mediaRefreshes.filter { tokens.contains($0.key) }
        }
    }

    public func mediaURL(token: String) -> URL { URL(string: "https://fixture.invalid/api/comms/media/\(token)")! }

    public func events(lastEventID: String?) -> AsyncThrowingStream<CommsEvent, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            state.withLock {
                $0.requestedEventIDs.append(lastEventID)
                $0.continuations[id] = continuation
            }
            continuation.onTermination = { [state] _ in
                state.withLock { _ = $0.continuations.removeValue(forKey: id) }
            }
        }
    }
}

// MARK: Synthetic messages

/// Builds synthetic `CommsMessage`s, pages and events (the wire models have no public
/// memberwise initialisers, so this assembles the server's JSON and decodes it).
/// Synthetic data only.
public enum FixtureMessages {
    public static let selfID = "@owner:example.test"

    public struct Reaction: Sendable {
        public var key: String
        public var count: Int
        public var mine: Bool
        /// The other reactors' names (synthetic "Sender N" when empty).
        public var names: [String]
        public init(_ key: String, count: Int = 1, mine: Bool = false, names: [String] = []) {
            self.key = key
            self.count = count
            self.mine = mine
            self.names = names
        }
    }

    public static func message(
        id: String,
        threadID: String = "th_test",
        network: String = "whatsapp",
        sender: String = "Alex",
        senderID: String? = nil,
        outgoing: Bool = false,
        avatarToken: String? = nil,
        at sentAt: Date,
        text: String? = "Hello",
        spans: [CommsSpan]? = nil,
        jumboEmoji: Bool = false,
        truncated: Bool = false,
        editedAt: Date? = nil,
        attachments: [[String: Any]] = [],
        linkPreviews: [[String: Any]] = [],
        reactions: [Reaction] = [],
        redacted: Bool = false,
        system: String? = nil,
        delivery: String? = nil
    ) -> CommsMessage {
        let iso = { (d: Date) in d.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
        var senderJSON: [String: Any] = [
            "id": outgoing ? selfID : (senderID ?? "@\(network)_\(sender.lowercased().filter(\.isLetter)):example.test"),
            "name": outgoing ? "Me" : sender,
            "isSelf": outgoing,
            "isOmni": false,
        ]
        if let avatarToken { senderJSON["avatar"] = ["token": avatarToken] }
        var json: [String: Any] = [
            "id": id,
            "threadId": threadID,
            "channel": ["network": network],
            "source": ["network": network, "eventId": id, "ref": id],
            "sender": senderJSON,
            "sentAt": iso(sentAt),
            "attachments": attachments,
            "linkPreviews": linkPreviews,
            "reactions": reactions.map { r -> [String: Any] in
                [
                    "key": r.key, "count": r.count, "mine": r.mine,
                    "senders": r.names.isEmpty
                        ? (0..<r.count).map { i in ["id": "@s\(i):example.test", "name": "Sender \(i)"] }
                        : (r.mine ? [["id": selfID, "name": "Me"]] : []) + r.names.map { n in
                            ["id": "@\(network)_\(n.lowercased().filter(\.isLetter)):example.test", "name": n]
                        },
                ]
            },
            "redacted": redacted,
        ]
        if let editedAt { json["editedAt"] = iso(editedAt) }
        if let delivery { json["delivery"] = delivery }
        if let system { json["system"] = ["kind": "member", "text": system] }
        if let spans {
            json["body"] = encodeJSON(CommsRichText(spans: spans, plain: plain(spans), jumboEmoji: jumboEmoji, truncated: truncated))
        } else if let text, system == nil {
            json["body"] = encodeJSON(CommsRichText(spans: [.text(text)], plain: text, jumboEmoji: jumboEmoji, truncated: truncated))
        }
        return decode(CommsMessage.self, json)
    }

    public static func image(token: String = "tok_photo", w: Int, h: Int) -> [String: Any] {
        ["kind": "image", "mime": "image/jpeg", "w": w, "h": h, "mediaToken": token, "thumbToken": token + "_thumb"]
    }

    public static func page(_ messages: [CommsMessage], before: String?, hasMore: Bool) -> CommsMessagePage {
        var body: [String: Any] = ["messages": messages.map(encodeJSON), "hasMore": hasMore]
        if let before { body["before"] = before }
        return decode(CommsMessagePage.self, body)
    }

    /// A message event as the stream sends it: `{threadId, message}`.
    public static func event(_ kind: CommsEventKind, _ message: CommsMessage, id: String = "e1") -> CommsEvent {
        let encoded = try! PrismJSON.decoder().decode(JSONValue.self, from: PrismJSON.encoder().encode(message))
        return CommsEvent(id: id, kind: kind, payload: ["threadId": .string(message.threadId), "message": encoded])
    }

    /// A `CommsThreadDetail` for `thread` (no members unless given).
    public static func detail(_ thread: CommsThread, members: [CommsMember] = [], contact: CommsContact? = nil) -> CommsThreadDetail {
        CommsThreadDetail(thread: thread, members: members, contact: contact)
    }

    public static func threadPage(_ threads: [CommsThread], next: String? = nil) -> CommsThreadPage {
        var body: [String: Any] = ["threads": threads.map(encodeJSON)]
        if let next { body["next"] = next }
        return decode(CommsThreadPage.self, body)
    }

    /// A `CommsThread` from the fields the transcript reads.
    public static func thread(id: String, title: String, kind: String = "dm", network: String = "whatsapp", avatar: [String: Any] = ["monogram": "A"]) -> CommsThread {
        decode(CommsThread.self, [
            "id": id, "title": title, "titleSource": "contact", "avatar": avatar, "kind": kind,
            "networks": [network], "lastActivityAt": "2026-11-21T09:30:00.000Z",
            "unread": ["count": 0, "trusted": false], "folder": "inbox", "pinned": false, "muted": false,
            "channels": [["network": network]],
        ])
    }

    /// The server media route's sniffed type for fixture bytes (the few kinds fixtures use).
    public static func sniffedType(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return "image/png" }
        if b.starts(with: [0xff, 0xd8, 0xff]) { return "image/jpeg" }
        if b.count >= 12, String(decoding: b[4..<8], as: UTF8.self) == "ftyp" {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if ["heic", "heix", "mif1", "msf1"].contains(brand) { return "image/heic" }
            if brand == "qt  " { return "video/quicktime" }
            return "video/mp4"
        }
        return "application/octet-stream"
    }

    /// A 4 × 3 PNG (sand-coloured): what fixture media answers.
    public static let placeholderPNG: Data = {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.86, green: 0.72, blue: 0.56, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }()

    static func encodeJSON<T: Encodable>(_ value: T) -> Any {
        try! JSONSerialization.jsonObject(with: PrismJSON.encoder().encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) -> T {
        // The inputs are built here: a decode failure is a programmer error in the fixture.
        try! PrismJSON.decoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func plain(_ spans: [CommsSpan]) -> String {
        spans.map { span -> String in
            switch span {
            case .text(let s), .pre(let s): return s
            case .bold(let c), .italic(let c), .strike(let c), .code(let c), .quote(let c), .listItem(let c): return plain(c)
            case .link(_, let c): return plain(c)
            case .mention(_, let name): return name
            case .br: return "\n"
            case .unknown: return ""
            }
        }.joined()
    }
}

private final class WeakBackend: @unchecked Sendable {
    weak var value: FixtureBackend?
}
