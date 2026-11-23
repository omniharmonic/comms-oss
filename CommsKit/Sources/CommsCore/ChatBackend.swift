import CommsClient
import OmniClient
import PrismModels
import PrismTransport
import Foundation
import os

/// The seam between the app and the Prism server. The UI only ever sees this protocol, so
/// previews, tests and the live app share one code path. Types are PrismKit's `Comms*` wire models.
public protocol ChatBackend: Sendable {
    func capabilities() async throws -> CommsCapabilities
    func threads(_ q: CommsThreadQuery) async throws -> CommsThreadPage
    func thread(id: String) async throws -> CommsThreadDetail
    /// A vault person: how to reach them and every conversation shared with them.
    func person(id: String) async throws -> CommsPerson
    func messages(threadID: String, before: String?, limit: Int) async throws -> CommsMessagePage
    /// A Telegram forum: one topic's timeline (`topic`), or every topic merged (nil).
    func messages(threadID: String, before: String?, limit: Int, topic: String?) async throws -> CommsMessagePage
    func mediaURL(token: String) -> URL
    /// A media token's bytes and `Content-Type`, fetched with the session's credential (the
    /// server refuses plain URL loads). Throws `CommsError.mediaExpired` on 410.
    func media(token: String) async throws -> (Data, String)
    /// A voice / audio attachment in a form AVFoundation plays (`?format=m4a`: the server
    /// transcodes Ogg/Opus, AMR and WebM to AAC; anything playable comes back unchanged).
    func playableAudio(token: String) async throws -> (Data, String)
    /// Fresh tokens for expired ones (`POST /api/comms/media/refresh`); tokens the server
    /// would not refresh are absent. Backends that cannot refresh answer `[:]`.
    func refreshMedia(tokens: [String]) async throws -> [String: String]
    func events(lastEventID: String?) -> AsyncThrowingStream<CommsEvent, Error>
    /// Send the owner's text (`clientID` is a UUID; reuse it for a Try Again). Throws
    /// `CommsError.sendFailed` (with `maybeSent`).
    func sendText(threadID: String, clientID: String, text: String, replyTo: String?) async throws -> CommsSendResult
    /// The same with `@Name` mentions (UTF-16 ranges of `text`) and the composer's channel pick
    /// (the server refuses the send unless the thread sends through exactly that channel).
    func sendText(threadID: String, clientID: String, text: String, replyTo: String?, mentions: [CommsMention], channel: CommsChannelRef?) async throws -> CommsSendResult
    /// Upload one attachment as its own message (`clientID` = the attachment's id).
    func sendAttachment(threadID: String, clientID: String, attachment: OutgoingAttachment) async throws -> CommsSendResult
    func sendAttachment(threadID: String, clientID: String, attachment: OutgoingAttachment, channel: CommsChannelRef?) async throws -> CommsSendResult
    /// A Telegram forum: the same into one topic (required there; never "All").
    func sendText(threadID: String, clientID: String, text: String, replyTo: String?, mentions: [CommsMention], channel: CommsChannelRef?, topic: String?) async throws -> CommsSendResult
    func sendAttachment(threadID: String, clientID: String, attachment: OutgoingAttachment, channel: CommsChannelRef?, topic: String?) async throws -> CommsSendResult
    func addReaction(threadID: String, messageID: String, clientID: String, key: String, topic: String?) async throws -> CommsSendResult
    func removeReaction(threadID: String, messageID: String, key: String, topic: String?) async throws
    /// `capabilities.send` as last verified (nil before, or from a server that cannot send).
    var sendLimits: CommsSendCapabilities? { get }
    /// React to a message with `key` (`clientID` is a UUID; reuse it for a Try Again). Throws
    /// `CommsError.sendFailed` (`alreadyReacted`, `notFound`, the send gates).
    func addReaction(threadID: String, messageID: String, clientID: String, key: String) async throws -> CommsSendResult
    /// Remove the owner's own reaction `key` (404 `notFound` when there is none this account sent).
    func removeReaction(threadID: String, messageID: String, key: String) async throws
    /// The To: field's suggestions for `query` (people, existing conversations, the typed address).
    func recipients(query: String, limit: Int) async throws -> CommsRecipients
    /// Start an iMessage/SMS conversation with `handle`, sending `text` — or, when one already
    /// exists, send nothing and answer `existing` with its id.
    func startConversation(clientID: String, handle: String, network: CommsClient.NewConversationNetwork, text: String) async throws -> CommsNewConversation

    // Read state + notifications (Sprint Task 1)
    /// Mark read up to `upTo` (nil = everything); `viewing` = this device shows the thread now.
    /// `explicit` = the owner's own Mark as Read action: a network receipt where supported even with
    /// the receipts toggle off (D10 ruling). Opening / viewing sends one only with the toggle on.
    func markRead(threadID: String, upTo: Date?, viewing: Bool?, explicit: Bool) async throws
    /// A Telegram forum: `topic` = read that topic only (its own read point); nil = the forum up to `upTo`.
    func markRead(threadID: String, upTo: Date?, viewing: Bool?, explicit: Bool, topic: String?) async throws
    func markUnread(threadID: String) async throws
    /// Unread threads (and those Needing attention: the app badge); nil = the server cannot say.
    func unreadSummary() async throws -> CommsStatusCounts.Unread?
    func notificationSettings() async throws -> CommsNotifySettingsResponse
    /// Only the changed keys (the server merges): a stale screen never undoes another device's choice.
    func updateNotificationSettings(_ patch: CommsNotifySettingsPatch) async throws -> CommsNotifySettingsResponse
    func registerPush(deviceToken: Data, environment: CommsPushEnvironment, platform: CommsPushPlatform) async throws -> CommsPushRegistration
    /// This device stops receiving Comms notifications (sign-out; revoking the device also does it).
    func unregisterPush() async throws
    /// "Send Test Notification": a fixed alert to each Comms device; what APNs answered for each.
    func sendTestNotification() async throws -> CommsPushTestResult
    /// The server offers pins ("threads:pin" in the last verified capabilities).
    var pinsSupported: Bool { get }
    /// Pin a conversation at the end of the grid (`CommsError.pinLimit` past nine).
    func pin(threadID: String) async throws -> CommsThread
    /// Unpin a conversation.
    func unpin(threadID: String) async throws -> CommsThread
    /// The grid's new order (exactly the pinned set; `CommsError.pinsChanged` otherwise).
    func reorderPins(_ threadIDs: [String]) async throws -> [CommsThread]
    // Row actions + owner folders (sprint Task 9)
    /// Which row actions the server offers ("threads:mute|archive|status" in the capabilities).
    var rowActions: RowActionSupport { get }
    /// Mute (Hide Alerts) or unmute.
    func setMuted(threadID: String, _ muted: Bool) async throws -> CommsThread
    /// To / from the Archived folder.
    func setArchived(threadID: String, _ archived: Bool) async throws -> CommsThread
    /// The triage status (a tag write on the thread's vault note), with its undo.
    func setStatus(threadID: String, _ status: CommsThreadStatus) async throws -> CommsStatusChange
    func undoStatus(threadID: String, undoID: String) async throws -> CommsThread
    /// The server offers owner folders ("threads:folders").
    var foldersSupported: Bool { get }
    func folders() async throws -> [CommsChatFolder]
    func createFolder(name: String) async throws -> CommsChatFolder
    func renameFolder(id: String, name: String) async throws -> CommsChatFolder
    func deleteFolder(id: String) async throws
    func reorderFolders(_ ids: [String]) async throws -> [CommsChatFolder]
    func addToFolder(id: String, threadIDs: [String]) async throws -> CommsChatFolder
    func removeFromFolder(id: String, threadIDs: [String]) async throws -> CommsChatFolder
    /// Email (PRD §5.8): reply on an email thread. `email` = the To/Cc/Subject the composer SHOWED
    /// (the server refuses a reply whose header changed since: `target_changed`). Plain text only.
    func sendEmailReply(threadID: String, clientID: String, text: String, email: CommsEmailDetail.Reply) async throws -> CommsSendResult
    /// A new email (D11) to `to` with `subject`.
    func startEmail(clientID: String, to: String, subject: String, text: String) async throws -> CommsNewConversation
    /// "View full email": the whole stored message (sanitized HTML when there is one).
    func emailOriginal(threadID: String, messageID: String) async throws -> CommsEmailOriginal
    // Task 4: full search and contact tidy-up.
    /// Messages across all history (`GET /search`); throws `PrismError` 404 `search_disabled`
    /// from a server without full search.
    func search(query: String, filter: CommsSearchFilter, cursor: String?, limit: Int) async throws -> CommsSearchResults
    /// Photos or links of about the last 90 days.
    func searchMedia(kind: CommsMediaKind, query: String?, threadID: String?, cursor: String?) async throws -> CommsMediaPage
    func tidyList(cursor: String?, limit: Int) async throws -> CommsTidyPage
    func tidyItem(threadID: String) async throws -> CommsTidyItem?
    func tidyLink(threadID: String, personID: String) async throws -> CommsTidyResult
    func tidyCreate(threadID: String, name: String, allowSimilar: Bool) async throws -> CommsTidyResult
    func tidyIgnore(threadID: String) async throws -> CommsTidyResult
    func tidyUndo(actionID: String) async throws -> CommsTidyResult

    // MARK: Omni in Comms (Phase 4, D9: Omni proposes, the owner approves the exact text)

    /// The server declared `capabilities.omni.enabled` at the last check.
    var omniAvailable: Bool { get }
    /// One conversation's drafts, "drafting" and Omni's private answer.
    func omniState(threadID: String) async throws -> CommsOmniState
    /// `@Omni`: a private instruction. Omni may PROPOSE a draft; nothing is sent.
    func askOmni(threadID: String, instruction: String, messageIDs: [String], idempotencyKey: IdempotencyKey) async throws -> CommsOmniStart
    /// The same in a forum, naming the topic on screen (the draft is bound to it).
    func askOmni(threadID: String, instruction: String, messageIDs: [String], topic: String?, idempotencyKey: IdempotencyKey) async throws -> CommsOmniStart
    /// "Catch me up": a private summary.
    func catchUp(threadID: String, idempotencyKey: IdempotencyKey) async throws -> CommsOmniStart
    /// Decide on the draft THE OWNER SAW (its digest is sent): `send` = Approve & Send, `cancel` =
    /// Discard, `revise` + feedback = Refine. Call only from the owner's press, after the
    /// device-owner check. Same key again after an unclear outcome.
    func decide(draft: Approval, _ decision: ApprovalDecisionKind, feedback: String?, idempotencyKey: IdempotencyKey) async throws -> ApprovalDecision
    /// The owner's pending Omni proposals (every kind): Needs you.
    func pendingApprovals() async throws -> [Approval]
    /// The owner closed Omni's note for `turnID`: it stays closed on every device.
    func dismissOmniNote(threadID: String, turnID: String) async throws
}

/// The row actions a server offers (capabilities `threads:mute`, `threads:archive`, `threads:status`).
public struct RowActionSupport: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let mute = RowActionSupport(rawValue: 1)
    public static let archive = RowActionSupport(rawValue: 2)
    public static let status = RowActionSupport(rawValue: 4)
    public static let all: RowActionSupport = [.mute, .archive, .status]

    public init(operations: Set<String>) {
        var s: RowActionSupport = []
        if operations.contains("threads:mute") { s.insert(.mute) }
        if operations.contains("threads:archive") { s.insert(.archive) }
        if operations.contains("threads:status") { s.insert(.status) }
        self = s
    }
}

/// An older server / test double: no row actions, no folders (the UI hides them; calls fail closed).
extension ChatBackend {
    public var rowActions: RowActionSupport { [] }
    public func setMuted(threadID: String, _ muted: Bool) async throws -> CommsThread { throw CommsError.threadActionsDisabled }
    public func setArchived(threadID: String, _ archived: Bool) async throws -> CommsThread { throw CommsError.threadActionsDisabled }
    public func setStatus(threadID: String, _ status: CommsThreadStatus) async throws -> CommsStatusChange { throw CommsError.threadActionsDisabled }
    public func undoStatus(threadID: String, undoID: String) async throws -> CommsThread { throw CommsError.threadActionsDisabled }
    public var foldersSupported: Bool { false }
    public func folders() async throws -> [CommsChatFolder] { throw CommsError.foldersDisabled }
    public func createFolder(name: String) async throws -> CommsChatFolder { throw CommsError.foldersDisabled }
    public func renameFolder(id: String, name: String) async throws -> CommsChatFolder { throw CommsError.foldersDisabled }
    public func deleteFolder(id: String) async throws { throw CommsError.foldersDisabled }
    public func reorderFolders(_ ids: [String]) async throws -> [CommsChatFolder] { throw CommsError.foldersDisabled }
    public func addToFolder(id: String, threadIDs: [String]) async throws -> CommsChatFolder { throw CommsError.foldersDisabled }
    public func removeFromFolder(id: String, threadIDs: [String]) async throws -> CommsChatFolder { throw CommsError.foldersDisabled }
}

/// A backend without full search or tidy-up (test doubles, older servers).
public struct SearchUnavailable: Error, Equatable { public init() {} }

extension ChatBackend {
    public func search(query: String, filter: CommsSearchFilter, cursor: String?, limit: Int) async throws -> CommsSearchResults { throw SearchUnavailable() }
    public func searchMedia(kind: CommsMediaKind, query: String?, threadID: String?, cursor: String?) async throws -> CommsMediaPage { throw SearchUnavailable() }
    public func tidyList(cursor: String?, limit: Int) async throws -> CommsTidyPage { CommsTidyPage() }
    public func tidyItem(threadID: String) async throws -> CommsTidyItem? { nil }
    public func tidyLink(threadID: String, personID: String) async throws -> CommsTidyResult { throw CommsTidyRefusal.disabled }
    public func tidyCreate(threadID: String, name: String, allowSimilar: Bool) async throws -> CommsTidyResult { throw CommsTidyRefusal.disabled }
    public func tidyIgnore(threadID: String) async throws -> CommsTidyResult { throw CommsTidyRefusal.disabled }
    public func tidyUndo(actionID: String) async throws -> CommsTidyResult { throw CommsTidyRefusal.disabled }
}

extension ChatBackend {
    public var sendLimits: CommsSendCapabilities? { nil }
    public func refreshMedia(tokens: [String]) async throws -> [String: String] { [:] }

    /// A backend that cannot send refuses (fails closed): nothing pretends to go out.
    public func sendText(threadID: String, clientID: String, text: String, replyTo: String?) async throws -> CommsSendResult {
        throw CommsError.sendFailed(CommsSendFailure(reason: .sendDisabled))
    }
    public func sendAttachment(threadID: String, clientID: String, attachment: OutgoingAttachment) async throws -> CommsSendResult {
        throw CommsError.sendFailed(CommsSendFailure(reason: .sendDisabled))
    }
    /// A backend that does not know mentions or channel picks sends only a message that needs
    /// neither; anything else fails closed (a mention must never silently become plain text,
    /// a picked channel never silently another one).
    public func sendText(threadID: String, clientID: String, text: String, replyTo: String?, mentions: [CommsMention], channel: CommsChannelRef?) async throws -> CommsSendResult {
        guard mentions.isEmpty, channel == nil else { throw CommsError.sendFailed(CommsSendFailure(reason: .unsupportedNetwork)) }
        return try await sendText(threadID: threadID, clientID: clientID, text: text, replyTo: replyTo)
    }
    public func sendAttachment(threadID: String, clientID: String, attachment: OutgoingAttachment, channel: CommsChannelRef?) async throws -> CommsSendResult {
        guard channel == nil else { throw CommsError.sendFailed(CommsSendFailure(reason: .unsupportedNetwork)) }
        return try await sendAttachment(threadID: threadID, clientID: clientID, attachment: attachment)
    }
    /// Forum topics: a backend that knows none reads the thread as one (the topic is ignored), and
    /// never sends into a topic it cannot name (fails closed).
    public func messages(threadID: String, before: String?, limit: Int, topic: String?) async throws -> CommsMessagePage {
        try await messages(threadID: threadID, before: before, limit: limit)
    }
    public func sendText(threadID: String, clientID: String, text: String, replyTo: String?, mentions: [CommsMention], channel: CommsChannelRef?, topic: String?) async throws -> CommsSendResult {
        guard topic == nil else { throw CommsError.sendFailed(CommsSendFailure(reason: .topicRequired)) }
        return try await sendText(threadID: threadID, clientID: clientID, text: text, replyTo: replyTo, mentions: mentions, channel: channel)
    }
    public func sendAttachment(threadID: String, clientID: String, attachment: OutgoingAttachment, channel: CommsChannelRef?, topic: String?) async throws -> CommsSendResult {
        guard topic == nil else { throw CommsError.sendFailed(CommsSendFailure(reason: .topicRequired)) }
        return try await sendAttachment(threadID: threadID, clientID: clientID, attachment: attachment, channel: channel)
    }
    public func addReaction(threadID: String, messageID: String, clientID: String, key: String, topic: String?) async throws -> CommsSendResult {
        try await addReaction(threadID: threadID, messageID: messageID, clientID: clientID, key: key)
    }
    public func removeReaction(threadID: String, messageID: String, key: String, topic: String?) async throws {
        try await removeReaction(threadID: threadID, messageID: messageID, key: key)
    }
    /// A backend that cannot react refuses (fails closed).
    public func addReaction(threadID: String, messageID: String, clientID: String, key: String) async throws -> CommsSendResult {
        throw CommsError.sendFailed(CommsSendFailure(reason: .sendDisabled))
    }
    public func removeReaction(threadID: String, messageID: String, key: String) async throws {
        throw CommsError.sendFailed(CommsSendFailure(reason: .sendDisabled))
    }
    /// A backend without a recipients directory suggests nothing.
    public func recipients(query: String, limit: Int) async throws -> CommsRecipients { CommsRecipients(query: query) }
    public var pinsSupported: Bool { false }
    public func pin(threadID: String) async throws -> CommsThread { throw CommsError.pinsDisabled }
    public func unpin(threadID: String) async throws -> CommsThread { throw CommsError.pinsDisabled }
    public func reorderPins(_ threadIDs: [String]) async throws -> [CommsThread] { throw CommsError.pinsDisabled }
    /// A backend without Omni offers none of it (fails closed: nothing is decided or sent).
    public var omniAvailable: Bool { false }
    public func omniState(threadID: String) async throws -> CommsOmniState { throw CommsOmniError.disabled }
    public func askOmni(threadID: String, instruction: String, messageIDs: [String], idempotencyKey: IdempotencyKey) async throws -> CommsOmniStart { throw CommsOmniError.disabled }
    public func catchUp(threadID: String, idempotencyKey: IdempotencyKey) async throws -> CommsOmniStart { throw CommsOmniError.disabled }
    public func decide(draft: Approval, _ decision: ApprovalDecisionKind, feedback: String?, idempotencyKey: IdempotencyKey) async throws -> ApprovalDecision { throw CommsOmniError.disabled }
    public func pendingApprovals() async throws -> [Approval] { [] }
    public func dismissOmniNote(threadID: String, turnID: String) async throws {}
    /// A backend without transcoding answers the original bytes.
    public func playableAudio(token: String) async throws -> (Data, String) { try await media(token: token) }
    /// A backend that cannot start conversations refuses (fails closed).
    public func startConversation(clientID: String, handle: String, network: CommsClient.NewConversationNetwork, text: String) async throws -> CommsNewConversation {
        throw CommsError.sendFailed(CommsSendFailure(reason: .sendDisabled))
    }
    /// Backends without read state (test doubles) keep it local.
    public func markRead(threadID: String, upTo: Date?, viewing: Bool?, explicit: Bool) async throws {}
    public func markRead(threadID: String, upTo: Date?, viewing: Bool?, explicit: Bool, topic: String?) async throws {
        try await markRead(threadID: threadID, upTo: upTo, viewing: viewing, explicit: explicit)
    }
    public func askOmni(threadID: String, instruction: String, messageIDs: [String], topic: String?, idempotencyKey: IdempotencyKey) async throws -> CommsOmniStart {
        try await askOmni(threadID: threadID, instruction: instruction, messageIDs: messageIDs, idempotencyKey: idempotencyKey)
    }
    public func markUnread(threadID: String) async throws {}
    public func unreadSummary() async throws -> CommsStatusCounts.Unread? { nil }
    public func notificationSettings() async throws -> CommsNotifySettingsResponse {
        CommsNotifySettingsResponse(settings: .defaults, available: CommsNotifyAvailability(push: false, readReceipts: false))
    }
    public func updateNotificationSettings(_ patch: CommsNotifySettingsPatch) async throws -> CommsNotifySettingsResponse {
        CommsNotifySettingsResponse(settings: CommsNotifySettings.defaults.applying(patch), available: CommsNotifyAvailability(push: false, readReceipts: false))
    }
    public func registerPush(deviceToken: Data, environment: CommsPushEnvironment, platform: CommsPushPlatform) async throws -> CommsPushRegistration {
        throw CommsError.unsupportedServer("push not available")
    }
    public func unregisterPush() async throws {}
    public func sendTestNotification() async throws -> CommsPushTestResult { throw CommsError.unsupportedServer("push not available") }
}

/// The live backend: a thin pass-through to PrismKit's `CommsClient`.
public struct PrismChatBackend: ChatBackend {
    private let client: CommsClient
    /// The Omni approval routes (`/api/omni/approvals`), on the same signed-in transport.
    private let omni: OmniClient
    /// `capabilities.send` from the last verified `capabilities()` (the session's check).
    private let limits = OSAllocatedUnfairLock<CommsSendCapabilities?>(initialState: nil)
    /// The last verified capabilities' operations (pins are offered only when listed).
    private let operations = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private let omniOn = OSAllocatedUnfairLock<Bool>(initialState: false)

    public init(client: CommsClient) {
        self.client = client
        omni = OmniClient(transport: client.client)
    }

    public func capabilities() async throws -> CommsCapabilities {
        let caps = try await client.capabilities()
        limits.withLock { $0 = caps.send }
        operations.withLock { $0 = Set(caps.operations) }
        omniOn.withLock { $0 = caps.omniEnabled }
        return caps
    }
    public var omniAvailable: Bool { omniOn.withLock { $0 } }
    public func omniState(threadID: String) async throws -> CommsOmniState { try await client.omni(threadID: threadID) }
    public func askOmni(threadID: String, instruction: String, messageIDs: [String], idempotencyKey: IdempotencyKey) async throws -> CommsOmniStart {
        try await client.assist(threadID: threadID, instruction: instruction, messageIDs: messageIDs, idempotencyKey: idempotencyKey)
    }
    public func catchUp(threadID: String, idempotencyKey: IdempotencyKey) async throws -> CommsOmniStart {
        try await client.catchUp(threadID: threadID, idempotencyKey: idempotencyKey)
    }
    public func decide(draft: Approval, _ decision: ApprovalDecisionKind, feedback: String?, idempotencyKey: IdempotencyKey) async throws -> ApprovalDecision {
        try await omni.decide(shown: draft, decision, feedback: feedback, idempotencyKey: idempotencyKey)
    }
    public func pendingApprovals() async throws -> [Approval] { try await omni.approvals(status: .pending) }
    public func dismissOmniNote(threadID: String, turnID: String) async throws { try await client.dismissOmniNote(threadID: threadID, turnID: turnID) }
    public var pinsSupported: Bool { operations.withLock { $0.contains("threads:pin") } }
    public var rowActions: RowActionSupport { RowActionSupport(operations: operations.withLock { $0 }) }
    public func setMuted(threadID: String, _ muted: Bool) async throws -> CommsThread { try await client.setMuted(threadID: threadID, muted) }
    public func setArchived(threadID: String, _ archived: Bool) async throws -> CommsThread { try await client.setArchived(threadID: threadID, archived) }
    public func setStatus(threadID: String, _ status: CommsThreadStatus) async throws -> CommsStatusChange { try await client.setStatus(threadID: threadID, status) }
    public func undoStatus(threadID: String, undoID: String) async throws -> CommsThread { try await client.undoStatus(threadID: threadID, undoID: undoID) }
    public var foldersSupported: Bool { operations.withLock { $0.contains("threads:folders") } }
    public func folders() async throws -> [CommsChatFolder] { try await client.folders() }
    public func createFolder(name: String) async throws -> CommsChatFolder { try await client.createFolder(name: name) }
    public func renameFolder(id: String, name: String) async throws -> CommsChatFolder { try await client.renameFolder(id: id, name: name) }
    public func deleteFolder(id: String) async throws { try await client.deleteFolder(id: id) }
    public func reorderFolders(_ ids: [String]) async throws -> [CommsChatFolder] { try await client.reorderFolders(ids) }
    public func addToFolder(id: String, threadIDs: [String]) async throws -> CommsChatFolder { try await client.addToFolder(id: id, threadIDs: threadIDs) }
    public func removeFromFolder(id: String, threadIDs: [String]) async throws -> CommsChatFolder { try await client.removeFromFolder(id: id, threadIDs: threadIDs) }
    public func pin(threadID: String) async throws -> CommsThread { try await client.pin(threadID: threadID) }
    public func unpin(threadID: String) async throws -> CommsThread { try await client.unpin(threadID: threadID) }
    public func reorderPins(_ threadIDs: [String]) async throws -> [CommsThread] { try await client.reorderPins(threadIDs) }
    public var sendLimits: CommsSendCapabilities? { limits.withLock { $0 } }
    public func threads(_ q: CommsThreadQuery) async throws -> CommsThreadPage { try await client.threads(q) }
    public func thread(id: String) async throws -> CommsThreadDetail { try await client.thread(id: id) }
    public func person(id: String) async throws -> CommsPerson { try await client.person(id: id) }
    public func messages(threadID: String, before: String?, limit: Int) async throws -> CommsMessagePage {
        try await client.messages(threadID: threadID, before: before, limit: limit)
    }
    public func messages(threadID: String, before: String?, limit: Int, topic: String?) async throws -> CommsMessagePage {
        try await client.messages(threadID: threadID, before: before, limit: limit, topic: topic)
    }
    public func sendText(threadID: String, clientID: String, text: String, replyTo: String?, mentions: [CommsMention], channel: CommsChannelRef?, topic: String?) async throws -> CommsSendResult {
        try await client.sendText(threadID: threadID, clientID: clientID, text: text, replyTo: replyTo, mentions: mentions, channel: channel, topic: topic)
    }
    public func addReaction(threadID: String, messageID: String, clientID: String, key: String, topic: String?) async throws -> CommsSendResult {
        try await client.addReaction(threadID: threadID, messageID: messageID, clientID: clientID, key: key, topic: topic)
    }
    public func removeReaction(threadID: String, messageID: String, key: String, topic: String?) async throws {
        try await client.removeReaction(threadID: threadID, messageID: messageID, key: key, topic: topic)
    }
    public func mediaURL(token: String) -> URL { client.mediaURL(token: token) }
    public func media(token: String) async throws -> (Data, String) { try await client.media(token: token) }
    public func playableAudio(token: String) async throws -> (Data, String) { try await client.media(token: token, playableAudio: true) }
    public func refreshMedia(tokens: [String]) async throws -> [String: String] { try await client.refreshMedia(tokens: tokens) }
    public func events(lastEventID: String?) -> AsyncThrowingStream<CommsEvent, Error> {
        client.stream(lastEventID: lastEventID)
    }
    public func sendText(threadID: String, clientID: String, text: String, replyTo: String?) async throws -> CommsSendResult {
        try await client.sendText(threadID: threadID, clientID: clientID, text: text, replyTo: replyTo)
    }
    public func sendText(threadID: String, clientID: String, text: String, replyTo: String?, mentions: [CommsMention], channel: CommsChannelRef?) async throws -> CommsSendResult {
        try await client.sendText(threadID: threadID, clientID: clientID, text: text, replyTo: replyTo, mentions: mentions, channel: channel)
    }
    public func addReaction(threadID: String, messageID: String, clientID: String, key: String) async throws -> CommsSendResult {
        try await client.addReaction(threadID: threadID, messageID: messageID, clientID: clientID, key: key)
    }
    public func removeReaction(threadID: String, messageID: String, key: String) async throws {
        try await client.removeReaction(threadID: threadID, messageID: messageID, key: key)
    }
    public func recipients(query: String, limit: Int) async throws -> CommsRecipients {
        try await client.recipients(query: query, limit: limit)
    }
    public func startConversation(clientID: String, handle: String, network: CommsClient.NewConversationNetwork, text: String) async throws -> CommsNewConversation {
        try await client.startConversation(clientID: clientID, handle: handle, network: network, text: text)
    }
    public func markRead(threadID: String, upTo: Date?, viewing: Bool?, explicit: Bool) async throws {
        try await client.markRead(threadID: threadID, upTo: upTo, viewing: viewing, explicit: explicit)
    }
    public func markRead(threadID: String, upTo: Date?, viewing: Bool?, explicit: Bool, topic: String?) async throws {
        try await client.markRead(threadID: threadID, upTo: upTo, viewing: viewing, explicit: explicit, topic: topic)
    }
    public func askOmni(threadID: String, instruction: String, messageIDs: [String], topic: String?, idempotencyKey: IdempotencyKey) async throws -> CommsOmniStart {
        try await client.assist(threadID: threadID, instruction: instruction, messageIDs: messageIDs, topic: topic, idempotencyKey: idempotencyKey)
    }
    public func markUnread(threadID: String) async throws { try await client.markUnread(threadID: threadID) }
    public func unreadSummary() async throws -> CommsStatusCounts.Unread? { try await client.statusCounts().unread }
    public func notificationSettings() async throws -> CommsNotifySettingsResponse { try await client.notificationSettings() }
    public func sendTestNotification() async throws -> CommsPushTestResult { try await client.sendTestNotification() }
    public func updateNotificationSettings(_ patch: CommsNotifySettingsPatch) async throws -> CommsNotifySettingsResponse {
        try await client.updateNotificationSettings(patch)
    }
    public func registerPush(deviceToken: Data, environment: CommsPushEnvironment, platform: CommsPushPlatform) async throws -> CommsPushRegistration {
        try await client.registerPush(deviceToken: deviceToken, environment: environment, platform: platform)
    }
    public func unregisterPush() async throws { try await client.unregisterPush() }
    public func sendEmailReply(threadID: String, clientID: String, text: String, email: CommsEmailDetail.Reply) async throws -> CommsSendResult {
        try await client.sendText(threadID: threadID, clientID: clientID, text: text, email: email)
    }
    public func startEmail(clientID: String, to: String, subject: String, text: String) async throws -> CommsNewConversation {
        try await client.startConversation(clientID: clientID, handle: to, network: .email, text: text, subject: subject)
    }
    public func emailOriginal(threadID: String, messageID: String) async throws -> CommsEmailOriginal {
        try await client.emailOriginal(threadID: threadID, messageID: messageID)
    }
    public func search(query: String, filter: CommsSearchFilter, cursor: String?, limit: Int) async throws -> CommsSearchResults {
        try await client.search(query: query, filter: filter, cursor: cursor, limit: limit)
    }
    public func searchMedia(kind: CommsMediaKind, query: String?, threadID: String?, cursor: String?) async throws -> CommsMediaPage {
        try await client.searchMedia(kind: kind, query: query, threadID: threadID, cursor: cursor)
    }
    public func tidyList(cursor: String?, limit: Int) async throws -> CommsTidyPage { try await client.tidyList(cursor: cursor, limit: limit) }
    public func tidyItem(threadID: String) async throws -> CommsTidyItem? { try await client.tidyItem(threadID: threadID) }
    public func tidyLink(threadID: String, personID: String) async throws -> CommsTidyResult { try await client.tidyLink(threadID: threadID, personID: personID) }
    public func tidyCreate(threadID: String, name: String, allowSimilar: Bool) async throws -> CommsTidyResult {
        try await client.tidyCreate(threadID: threadID, name: name, allowSimilar: allowSimilar)
    }
    public func tidyIgnore(threadID: String) async throws -> CommsTidyResult { try await client.tidyIgnore(threadID: threadID) }
    public func tidyUndo(actionID: String) async throws -> CommsTidyResult { try await client.tidyUndo(actionID: actionID) }
    public func sendAttachment(threadID: String, clientID: String, attachment a: OutgoingAttachment) async throws -> CommsSendResult {
        try await sendAttachment(threadID: threadID, clientID: clientID, attachment: a, channel: nil)
    }
    public func sendAttachment(threadID: String, clientID: String, attachment a: OutgoingAttachment, channel: CommsChannelRef?) async throws -> CommsSendResult {
        try await sendAttachment(threadID: threadID, clientID: clientID, attachment: a, channel: channel, topic: nil)
    }
    public func sendAttachment(threadID: String, clientID: String, attachment a: OutgoingAttachment, channel: CommsChannelRef?, topic: String?) async throws -> CommsSendResult {
        if let file = a.fileURL {
            // Large items stream from their temporary file; never loaded into memory.
            let cap = sendLimits?.maxAttachmentBytes
            return try await client.sendAttachment(threadID: threadID, clientID: clientID, kind: a.kind, fileURL: file, mime: a.mime,
                                                   filename: a.filename, durationMs: a.durationMs, waveform: a.waveform,
                                                   w: a.pixelWidth, h: a.pixelHeight, maxBytes: cap.flatMap { $0 > 0 ? $0 : nil }, channel: channel, topic: topic)
        }
        return try await client.sendAttachment(threadID: threadID, clientID: clientID, kind: a.kind, data: a.data, mime: a.mime,
                                        filename: a.filename, durationMs: a.durationMs, waveform: a.waveform,
                                        w: a.pixelWidth, h: a.pixelHeight, channel: channel, topic: topic)
    }
}

extension ChatBackend {
    /// A backend that cannot send email refuses (fails closed).
    public func sendEmailReply(threadID: String, clientID: String, text: String, email: CommsEmailDetail.Reply) async throws -> CommsSendResult {
        throw CommsError.sendFailed(CommsSendFailure(reason: .sendDisabled))
    }
    public func startEmail(clientID: String, to: String, subject: String, text: String) async throws -> CommsNewConversation {
        throw CommsError.sendFailed(CommsSendFailure(reason: .sendDisabled))
    }
    public func emailOriginal(threadID: String, messageID: String) async throws -> CommsEmailOriginal { throw CommsError.threadUnavailable }
}

extension ChatBackend {
    /// Backends without people (test doubles) answer that the person is unavailable.
    public func person(id: String) async throws -> CommsPerson { throw CommsError.personUnavailable }
}

extension CommsNotifySettings {
    /// `patch` merged the way the server merges it (keys, then map entries).
    public func applying(_ patch: CommsNotifySettingsPatch) -> CommsNotifySettings {
        var s = self
        if let v = patch.enabled { s.enabled = v }
        for (k, v) in patch.statuses ?? [:] {
            if let path = CommsNotifySettings.Statuses.keys.first(where: { $0.key == k })?.path { s.statuses[keyPath: path] = v }
        }
        for (k, v) in patch.folders ?? [:] { s.folders[k] = v == .default ? nil : v }
        for (k, v) in patch.networks ?? [:] { s.networks[k] = v }
        if let v = patch.knownPeopleImmediately { s.knownPeopleImmediately = v }
        if let v = patch.hidePreviews { s.hidePreviews = v }
        if let v = patch.readReceipts { s.readReceipts = v }
        for (k, v) in patch.readReceiptsByNetwork ?? [:] { s.readReceiptsByNetwork[k] = v }
        return s
    }
}
