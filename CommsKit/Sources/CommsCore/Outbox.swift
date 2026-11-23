import CommsClient
import Foundation
import Observation
import os
import PrismTransport

/// The owner's outgoing messages for one signed-in window, by thread: sending, sent but not
/// yet echoed, and failed ("Not Delivered"). It outlives any one transcript, so a message
/// stays on screen when the owner leaves the conversation and comes back before the echo (in
/// production the echo can take a minute), and a failed one keeps its clientId for a safe
/// Try Again. Transcripts (`TimelineStore`) merge in their thread's entries and tell the
/// outbox which messages they have loaded, so echoed entries are dropped.
///
/// Sends go out one at a time in the order they were made (attachments, then text) — inside
/// the server's three-uploads-in-flight limit. Nothing is ever retried without the owner.
/// Attachment bytes are released once uploaded (a picture keeps a small preview for its
/// bubble); temporary files are deleted on success, Delete, echo, or when the outbox goes.
@MainActor @Observable
public final class Outbox {
    /// Pending sends by thread id, oldest first.
    public private(set) var byThread: [String: [PendingSend]] = [:]
    /// Overrides the server's attachment cap (tests); nil = `backend.sendLimits`.
    @ObservationIgnored public var maxAttachmentBytesOverride: Int?
    /// A sent-but-unechoed entry older than this is dropped: the server has it, and the
    /// conversation's next load shows the real message.
    @ObservationIgnored public var sentRetention: TimeInterval = 30 * 60

    @ObservationIgnored private let backend: any ChatBackend
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var listeners: [String: [Listener]] = [:]
    /// What the outbox holds outside itself (LocalMedia ids, temp files), for `deinit`.
    @ObservationIgnored private nonisolated let held = OSAllocatedUnfairLock(initialState: Held())

    private struct Listener { weak var store: TimelineStore? }
    private struct Held: Sendable {
        var media: Set<UUID> = []
        var files: Set<URL> = []
    }

    public init(backend: any ChatBackend, now: @escaping @MainActor () -> Date = { Date() }) {
        self.backend = backend
        self.now = now
        OutgoingFiles.sweepOnce()
    }

    deinit {
        let h = held.withLock { $0 }
        for id in h.media { LocalMedia.remove(id) }
        for url in h.files { OutgoingFiles.remove(url) }
    }

    /// The server's cap on one attachment (nil = unknown).
    public var maxAttachmentBytes: Int? {
        if let o = maxAttachmentBytesOverride { return o }
        guard let n = backend.sendLimits?.maxAttachmentBytes, n > 0 else { return nil }
        return n
    }

    public func pending(threadID: String) -> [PendingSend] {
        let all = byThread[threadID] ?? []
        let cutoff = now().addingTimeInterval(-sentRetention)
        return all.filter { $0.eventID == nil || $0.createdAt >= cutoff }
    }

    public func pendingSend(clientID: String) -> PendingSend? {
        byThread.values.lazy.flatMap { $0 }.first { $0.clientID == clientID }
    }

    // MARK: Sending

    /// Queue what the composer holds for `threadID`: each attachment as its own message (its
    /// own clientId), then the trimmed text. Returns when this batch has been answered.
    public func send(threadID: String, text: String, attachments: [OutgoingAttachment], replyTo: CommsMessage.Reply?,
                     email: CommsEmailDetail.Reply? = nil, mentions: [ComposerMention] = [], channel: CommsChannelRef? = nil, topic: CommsTopicRef? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var batch: [PendingSend] = []
        for a in attachments {
            if !a.data.isEmpty { LocalMedia.register(a.data, for: a.id) }
            hold(a)
            batch.append(PendingSend(threadID: threadID, clientID: a.id.uuidString.lowercased(), content: .attachment(a), createdAt: nextDate(threadID), channel: channel, topic: topic))
        }
        if !trimmed.isEmpty {
            // Ranges against the TRIMMED text: what the server receives.
            let lead = text.unicodeScalars.prefix { CharacterSet.whitespacesAndNewlines.contains($0) }.reduce(0) { $0 + $1.utf16.count }
            let ranges = MentionText.resolve(trimmed, picks: mentions, offset: lead)
            batch.append(PendingSend(threadID: threadID, clientID: UUID().uuidString.lowercased(), email: email,
                                     content: .text(trimmed, replyTo: replyTo, mentions: ranges), createdAt: nextDate(threadID), channel: channel, topic: topic))
        }
        guard !batch.isEmpty else { return }
        byThread[threadID, default: []] += batch
        changed(threadID)
        await enqueue(batch.map(\.clientID)).value
    }

    /// Show attachments that cannot go out as failed bubbles ("Not Delivered" + `failure`): never
    /// sent, never dropped silently. The owner deletes them.
    public func refuse(threadID: String, attachments: [OutgoingAttachment], failure: CommsSendFailure) {
        guard !attachments.isEmpty else { return }
        for a in attachments {
            if !a.data.isEmpty { LocalMedia.register(a.data, for: a.id) }
            hold(a)
            byThread[threadID, default: []].append(PendingSend(threadID: threadID, clientID: a.id.uuidString.lowercased(),
                                                               content: .attachment(a), createdAt: nextDate(threadID), state: .failed(failure)))
        }
        changed(threadID)
    }

    /// Try Again: the SAME clientId (the server answers a resend it already delivered with the
    /// same result). Only for failures that are not final.
    public func retry(clientID: String) async {
        guard let (t, i) = locate(clientID), let f = byThread[t]?[i].failure, !f.isFinal else { return }
        byThread[t]?[i].state = .sending
        changed(t)
        await enqueue([clientID]).value
    }

    /// Send a failed message again as a NEW message (new clientId) — for a maybe-sent one past
    /// the server's safe-retry window, after the owner checked it is missing.
    public func resendAsNew(clientID: String) async {
        guard let (t, i) = locate(clientID), let p = byThread[t]?[i], p.failure?.retryWindowExpired == true else { return }
        byThread[t]?.remove(at: i)
        var fresh: PendingSend
        switch p.content {
        case .text(let text, let reply, let mentions):
            fresh = PendingSend(threadID: t, clientID: UUID().uuidString.lowercased(), email: p.email,
                                content: .text(text, replyTo: reply, mentions: mentions), createdAt: nextDate(t), channel: p.channel, topic: p.topic)
        case .attachment(let a):
            // A new id is a new clientId; the bytes move with it.
            var b = OutgoingAttachment(kind: a.kind, data: a.data, fileURL: a.fileURL, mime: a.mime, filename: a.filename,
                                       durationMs: a.durationMs, waveform: a.waveform, pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight)
            b.byteCount = a.byteCount
            LocalMedia.remove(a.id)
            release(media: a.id)
            if !b.data.isEmpty { LocalMedia.register(b.data, for: b.id) }
            hold(b)
            fresh = PendingSend(threadID: t, clientID: b.id.uuidString.lowercased(), content: .attachment(b), createdAt: nextDate(t), channel: p.channel, topic: p.topic)
        }
        fresh.state = .sending
        byThread[t, default: []].append(fresh)
        changed(t)
        await enqueue([fresh.clientID]).value
    }

    /// Remove a failed message (never delivered, or the owner checked it was).
    public func discard(clientID: String) {
        guard let (t, i) = locate(clientID), case .failed = byThread[t]?[i].state, let p = byThread[t]?.remove(at: i) else { return }
        free(p)
        changed(t)
    }

    // MARK: Echo

    /// How far a server timestamp may sit before the moment Send was pressed and still be that
    /// send's echo (device vs server / Mac clock skew).
    static let echoClockSkew: TimeInterval = 30

    /// Pending sends whose echo was recognised by its CONTENT before the server could say
    /// which event it is (a BlueBubbles webhook or a Matrix sync that beats the HTTP answer
    /// carries no clientId yet), by thread → clientId → the server message id. They are not
    /// drawn: the server's message stands in for them, so there is never a frame with two.
    public private(set) var contentEchoes: [String: [String: String]] = [:]

    /// The transcript for `threadID` loaded `messages`: drop entries they echo (same event id,
    /// or the same clientId — which also catches an echo that beats the HTTP answer), and hide
    /// entries whose echo arrived before the server said which message it is — only while the
    /// event id is unknown — (same content,
    /// from the owner, no clientId, arrived after Send was pressed: `arrivedAt` is when the
    /// transcript first saw the message, nil = unknown).
    ///
    /// Returns every server message that stands for one of this device's sends, by message id
    /// → clientId, so the transcript keeps ONE row identity across the swap (an in-place update,
    /// never an insert + delete pair).
    @discardableResult
    public func reconcile(threadID: String, messages: [CommsMessage], arrivedAt: (String) -> Date? = { _ in nil }) -> [String: String] {
        guard let list = byThread[threadID], !list.isEmpty else {
            if contentEchoes[threadID] != nil { contentEchoes[threadID] = nil }
            return [:]
        }
        var byEvent: [String: String] = [:]
        var byClient: [String: String] = [:]
        for m in messages {
            if byEvent[m.source.eventId] == nil { byEvent[m.source.eventId] = m.id }
            if let c = m.clientId?.lowercased(), !c.isEmpty, byClient[c] == nil { byClient[c] = m.id }
        }
        let cutoff = now().addingTimeInterval(-sentRetention)
        var adopted: [String: String] = [:]
        var kept: [PendingSend] = []
        var dropped = false
        for p in list {
            let cid = p.clientID.lowercased()
            if let mid = p.eventID.flatMap({ byEvent[$0] }) ?? byClient[cid] {
                adopted[mid] = p.clientID
                free(p)
                dropped = true
            } else if p.eventID != nil && p.createdAt < cutoff {
                free(p)
                dropped = true
            } else {
                kept.append(p)
            }
        }

        // Content echoes: only owner messages that carry no clientId and are nobody's event.
        let claimedEvents = Set(kept.compactMap(\.eventID))
        let candidates = messages.filter { m in
            m.sender.isSelf && (m.clientId ?? "").isEmpty && adopted[m.id] == nil && !claimedEvents.contains(m.source.eventId) && !m.redacted
        }
        var echoes: [String: String] = [:]
        var taken = Set<String>()
        var final: [PendingSend] = []
        for p in kept {
            guard p.awaitsEventID,
                  let m = candidates.first(where: { m in
                      !taken.contains(m.id) && m.sentAt >= p.createdAt.addingTimeInterval(-Self.echoClockSkew)
                          && (arrivedAt(m.id) ?? p.createdAt) >= p.createdAt && p.isEchoed(by: m)
                  }) else {
                final.append(p)
                continue
            }
            taken.insert(m.id)
            adopted[m.id] = p.clientID
            if p.failure != nil {
                // "Not Delivered" but maybe sent — and here it is: it was delivered.
                free(p)
                dropped = true
            } else {
                echoes[p.clientID] = m.id
                final.append(p)
            }
        }
        let echoesChanged = (contentEchoes[threadID] ?? [:]) != echoes
        if echoesChanged { contentEchoes[threadID] = echoes.isEmpty ? nil : echoes }
        if dropped { byThread[threadID] = final.isEmpty ? nil : final }
        if dropped || echoesChanged { changed(threadID, reconciling: true) }
        return adopted
    }

    /// Entries drawn as bubbles: not those the server's message already stands for.
    public func visible(threadID: String) -> [PendingSend] {
        let hidden = contentEchoes[threadID] ?? [:]
        return pending(threadID: threadID).filter { hidden[$0.clientID] == nil }
    }

    // MARK: Listeners

    func register(_ store: TimelineStore) {
        listeners[store.threadID, default: []].removeAll { $0.store == nil || $0.store === store }
        listeners[store.threadID, default: []].append(Listener(store: store))
    }

    private func changed(_ threadID: String, reconciling: Bool = false) {
        for l in listeners[threadID] ?? [] { l.store?.outboxChanged(reconciling: reconciling) }
    }

    // MARK: Delivery

    private func enqueue(_ ids: [String]) -> Task<Void, Never> {
        let previous = chain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            for id in ids { await self?.deliver(id) }
        }
        chain = task
        return task
    }

    private func deliver(_ clientID: String) async {
        guard let (t, i) = locate(clientID), let p = byThread[t]?[i], p.state == .sending else { return }
        let state: PendingSend.State
        do {
            let result: CommsSendResult
            switch p.content {
            case .text(let text, let reply, let mentions):
                if let email = p.email {
                    // Email: the header the owner saw goes with it (the server's one door compares it).
                    result = try await backend.sendEmailReply(threadID: t, clientID: clientID, text: text, email: email)
                } else {
                    result = try await backend.sendText(threadID: t, clientID: clientID, text: text, replyTo: reply?.messageId, mentions: mentions, channel: p.channel, topic: p.topic?.id)
                }
            case .attachment(let a):
                if let cap = maxAttachmentBytes, a.byteCount > cap {
                    throw CommsError.sendFailed(CommsSendFailure(reason: .tooLarge, message: "The attachment is too large to send."))
                }
                result = try await backend.sendAttachment(threadID: t, clientID: clientID, attachment: a, channel: p.channel, topic: p.topic?.id)
            }
            state = .sent(eventID: result.eventId)
        } catch {
            state = .failed(TimelineStore.sendFailure(error))
        }
        guard let (t2, j) = locate(clientID) else { return }
        byThread[t2]?[j].state = state
        if case .sent = state, case .attachment(let a) = byThread[t2]?[j].content {
            // Uploaded: keep only what the bubble needs.
            if a.kind == .image { LocalMedia.keepPreview(for: a.id) } else { LocalMedia.remove(a.id) }
            a.deleteFile()
            release(file: a.fileURL)
            byThread[t2]?[j].content = .attachment(a.withoutBytes)
        }
        changed(t2)
    }

    // MARK: Internals

    private func locate(_ clientID: String) -> (String, Int)? {
        for (t, list) in byThread {
            if let i = list.firstIndex(where: { $0.clientID == clientID }) { return (t, i) }
        }
        return nil
    }

    private func nextDate(_ threadID: String) -> Date {
        let t = now()
        guard let last = byThread.values.flatMap({ $0 }).map(\.createdAt).max(), t <= last else { return t }
        return last.addingTimeInterval(0.001)
    }

    private func hold(_ a: OutgoingAttachment) {
        held.withLock { h in
            h.media.insert(a.id)
            if let f = a.fileURL { h.files.insert(f) }
        }
    }

    private func release(media id: UUID) { held.withLock { _ = $0.media.remove(id) } }
    private func release(file url: URL?) { if let url { held.withLock { _ = $0.files.remove(url) } } }

    private func free(_ p: PendingSend) {
        guard case .attachment(let a) = p.content else { return }
        LocalMedia.remove(a.id)
        a.deleteFile()
        release(media: a.id)
        release(file: a.fileURL)
    }
}

extension PendingSend {
    /// Its echo may be recognised by content: the server has not named its event yet (still
    /// sending, or failed with "may have been sent"). Once the 200 named the event, ONLY that
    /// event id (or the clientId) identifies the echo — an identical message from another
    /// device must never stand in for it (review I2).
    var awaitsEventID: Bool {
        switch state {
        case .sending: true
        case .sent: false
        case .failed(let f): f.maybeSent
        }
    }

    /// `m` (from the owner, no clientId) has this send's content: the same text, or one
    /// attachment of the same kind (a voice note may come back as plain audio).
    func isEchoed(by m: CommsMessage) -> Bool {
        switch content {
        case .text(let text, _, _):
            guard m.attachments.isEmpty else { return false }
            let body = (m.body?.plain ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !body.isEmpty && body == text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .attachment(let a):
            guard m.attachments.count == 1, let k = m.attachments.first?.kind else { return false }
            switch a.kind {
            case .voice: return k == .voice || k == .audio
            case .image: return k == .image || k == .sticker
            case .video: return k == .video
            case .file: return k == .file || k == .audio || k == .image || k == .video
            }
        }
    }
}
