import CommsClient
import Foundation
import LocalAuthentication
import Observation
import OmniClient
import PrismModels
import PrismTransport

// Omni in Comms (PRD §5.7, DECISIONS D9). Omni NEVER speaks in the chat: `@Omni` is a private
// instruction, its answer is a private note, and a reply it writes is a DRAFT (an Omni approval of
// kind `message`) that goes out only when the owner presses Approve & Send on that exact text —
// after Face ID / Touch ID — or edits it and sends it as his own message.

/// "Is the owner holding the device?" — asked before every Approve & Send.
public protocol OwnerPresence: Sendable {
    /// True only when the owner just proved presence. Fails closed (no biometrics / passcode = false).
    func confirm(reason: String) async -> Bool
}

/// Face ID / Touch ID, with the device passcode (iOS) / login password (Mac) as the system's
/// fallback — `.deviceOwnerAuthentication`, the owner's decision (review M5, 2026-11-22). Never "no
/// authentication": without a passcode the check fails and nothing is approved.
public struct DeviceOwnerPresence: OwnerPresence {
    public init() {}
    public func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

#if DEBUG
/// Tests and the DEBUG demo only (the simulator has no enrolled face): a fixed answer. Not
/// compiled into Release builds (review M6).
public struct FixedPresence: OwnerPresence {
    public let answer: Bool
    public init(_ answer: Bool) { self.answer = answer }
    public func confirm(reason: String) async -> Bool { answer }
}
#endif

/// The window's Omni state: per-conversation drafts / "drafting" / private notes, the composer's
/// Omni mode, and Needs you. Every decision goes through `ChatBackend.decide` with the draft the
/// owner saw; nothing here sends a message.
@MainActor @Observable
public final class OmniStore {
    /// A forum's topic to bind an `@Omni` draft to (the open transcript's compose target); nil elsewhere.
    @ObservationIgnored public var topicFor: (@MainActor (String) -> String?)?
    /// Something the owner should read about one conversation's Omni request.
    public struct Notice: Equatable, Sendable {
        public var text: String
        public init(_ text: String) { self.text = text }
    }

    public private(set) var states: [String: CommsOmniState] = [:]
    /// Threads with an `@Omni` / Catch Me Up request on its way to the server.
    public private(set) var asking: Set<String> = []
    /// Drafts being decided right now (their buttons are disabled).
    public private(set) var deciding: Set<String> = []
    public private(set) var notices: [String: Notice] = [:]
    /// The owner's pending Omni proposals (every kind), newest first.
    public private(set) var needsYou: [Approval] = []
    /// Omni answers the owner closed (by turn id).
    public private(set) var dismissedReplies: Set<String> = []

    /// Threads whose composer is an instruction field for Omni ("Ask Omni…").
    public var omniComposer: Set<String> = []
    /// Text the composer should take over (Edit moves a draft there), by thread.
    public var composerInsert: [String: String] = [:]
    /// The messages the owner pointed at ("Ask Omni about this"), by thread.
    public var askContext: [String: [String]] = [:]

    @ObservationIgnored private let backend: any ChatBackend
    @ObservationIgnored private let presence: any OwnerPresence
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let maxPolls: Int
    @ObservationIgnored private var polls: [String: Task<Void, Never>] = [:]
    /// The key of each decision whose outcome was unclear: the next press resends it (the server
    /// then answers the stored outcome and executes nothing twice).
    @ObservationIgnored private var keys: [String: IdempotencyKey] = [:]

    public init(backend: any ChatBackend, presence: any OwnerPresence = DeviceOwnerPresence(), pollInterval: Duration = .seconds(2), maxPolls: Int = 120) {
        self.backend = backend
        self.presence = presence
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
        isAvailable = backend.omniAvailable
    }

    /// The server offers Omni in Comms (`capabilities.omni`), as last read — observable, so the
    /// composer's Omni tint appears once capabilities have loaded. Unknown reads as unavailable,
    /// and an unavailable Omni BLOCKS `@Omni …` text rather than sending it (review I2).
    public private(set) var isAvailable: Bool

    /// Read the backend's verdict again (after capabilities load).
    public func refreshAvailability() {
        let now = backend.omniAvailable
        if now != isAvailable { isAvailable = now }
    }

    // MARK: Reading

    public func state(_ threadID: String) -> CommsOmniState? { states[threadID] }
    public func drafts(_ threadID: String) -> [Approval] { states[threadID]?.pendingDrafts ?? [] }
    public func isDrafting(_ threadID: String) -> Bool { asking.contains(threadID) || states[threadID]?.drafting == true }
    /// Omni's latest private answer for this conversation, unless closed.
    public func reply(_ threadID: String) -> (turn: CommsOmniTurn, reply: CommsOmniReply)? {
        guard let s = states[threadID], let t = s.turn, let r = s.reply, !t.isRunning, !dismissedReplies.contains(t.id) else { return nil }
        return (t, r)
    }

    public func load(_ threadID: String) async {
        refreshAvailability()
        guard isAvailable else { return }
        do {
            let s = try await backend.omniState(threadID: threadID)
            states[threadID] = s
            if s.drafting { startPolling(threadID) }
        } catch CommsOmniError.disabled {
            states[threadID] = nil
        } catch {
            // Reading is best effort: the transcript stays usable without Omni.
        }
    }

    public func loadNeedsYou() async {
        refreshAvailability()
        guard isAvailable else { needsYou = []; return }
        if let list = try? await backend.pendingApprovals() { needsYou = list.filter(\.isPending) }
    }

    /// Close Omni's note. It disappears here at once and the server remembers it, so it stays
    /// closed after a relaunch and on the owner's other devices (owner-testing round 4: closed
    /// notes kept coming back). Best effort: a failed call keeps it closed on this device.
    @discardableResult
    public func dismissReply(_ threadID: String) -> Task<Void, Never>? {
        guard let id = states[threadID]?.turn?.id else { return nil }
        dismissedReplies.insert(id)
        let backend = self.backend
        return Task { try? await backend.dismissOmniNote(threadID: threadID, turnID: id) }
    }

    /// The live stream: another device closed a note (`thread.updated`, reason `omni`) — refresh
    /// that conversation's Omni state if this device shows it.
    @discardableResult
    public func apply(_ event: CommsEvent) -> Task<Void, Never>? {
        guard event.kind == .threadUpdated, event.payload["reason"]?.stringValue == "omni",
              let id = event.threadID, states[id] != nil else { return nil }
        return Task { await self.load(id) }
    }

    public func clearNotice(_ threadID: String) { notices[threadID] = nil }

    // MARK: Asking

    /// "Ask Omni about this": the composer becomes Omni's instruction field, with that message.
    public func beginAsk(threadID: String, about messageID: String? = nil) {
        omniComposer.insert(threadID)
        if let messageID { askContext[threadID] = [messageID] }
    }

    public func endAsk(threadID: String) {
        omniComposer.remove(threadID)
        askContext[threadID] = nil
    }

    /// Strip a leading `@Omni` (any case) and the separator after it.
    public static func instruction(from text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if addressesOmni(t) {
            t = String(t.dropFirst(5))
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: ",:;.!?—–-").union(.whitespacesAndNewlines))
        }
        return t
    }

    /// Does this composer text address Omni? `@omni` (any case) at the start, after any leading
    /// whitespace, followed by nothing or by anything that is not a letter or digit (`@Omni,`,
    /// `@Omni.`, `@Omni—`, `@Omni?` …). `@Omnibus` does not (review N6).
    public static func addressesOmni(_ text: String) -> Bool {
        let t = text.drop { $0.isWhitespace || $0.isNewline }
        guard t.lowercased().hasPrefix("@omni") else { return false }
        guard let next = t.dropFirst(5).first else { return true }
        return !(next.isLetter || next.isNumber)
    }

    /// Send an instruction to Omni (never to the chat).
    public func ask(threadID: String, text: String) async {
        let instruction = Self.instruction(from: text)
        guard !instruction.isEmpty else { return }
        let ids = askContext[threadID] ?? []
        // A forum: the topic the owner's composer points at (the draft is bound to it).
        let topic = topicFor?(threadID)
        endAsk(threadID: threadID)
        await start(threadID) { [backend] key in
            try await backend.askOmni(threadID: threadID, instruction: instruction, messageIDs: ids, topic: topic, idempotencyKey: key)
        }
    }

    public func catchUp(threadID: String) async {
        await start(threadID) { [backend] key in try await backend.catchUp(threadID: threadID, idempotencyKey: key) }
    }

    private func start(_ threadID: String, _ call: @escaping @Sendable (IdempotencyKey) async throws -> CommsOmniStart) async {
        guard isAvailable, !asking.contains(threadID) else { return }
        asking.insert(threadID)
        notices[threadID] = nil
        defer { asking.remove(threadID) }
        do {
            _ = try await call(.random())
            var s = states[threadID] ?? CommsOmniState()
            s.drafting = true
            states[threadID] = s
            startPolling(threadID)
        } catch CommsOmniError.busy {
            startPolling(threadID)
        } catch {
            notices[threadID] = Notice(Self.message(for: error))
        }
    }

    private func startPolling(_ threadID: String) {
        guard polls[threadID] == nil else { return }
        polls[threadID] = Task { [weak self, pollInterval, maxPolls] in
            for _ in 0..<maxPolls {
                try? await Task.sleep(for: pollInterval)
                guard let self, !Task.isCancelled else { return }
                if let s = try? await self.backend.omniState(threadID: threadID) {
                    self.states[threadID] = s
                    if !s.drafting { break }
                }
            }
            self?.polls[threadID] = nil
            await self?.loadNeedsYou()
        }
    }

    /// Tests: wait until this thread's polling stopped.
    public func pollSettled(_ threadID: String) async { await polls[threadID]?.value }

    // MARK: Deciding (the owner's presses only)

    /// Approve & Send: Face ID / Touch ID first, then the exact draft (digest) to the server, which
    /// sends it through the same path as the owner's own messages. False = not sent (yet).
    @discardableResult
    public func approve(_ draft: Approval, threadID: String) async -> Bool {
        guard draft.isPending, draft.digestMatchesPayload else {
            notices[threadID] = Notice("This draft changed. Review it again before sending.")
            return false
        }
        // The same character policy as the server's (DraftText): nothing the owner cannot see.
        if let body = CommsDraft(draft)?.body, let why = DraftText.problem(body) {
            notices[threadID] = Notice(why)
            return false
        }
        guard await presence.confirm(reason: "Send Omni's draft as your message") else { return false }
        return await decide(draft, .send, feedback: nil, threadID: threadID)
    }

    /// Discard: the draft is cancelled; nothing is sent.
    public func discard(_ draft: Approval, threadID: String) async {
        _ = await decide(draft, .cancel, feedback: nil, threadID: threadID)
    }

    /// Refine…: the follow-up goes back to Omni, which proposes a new draft.
    public func refine(_ draft: Approval, threadID: String, feedback: String) async {
        let f = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty else { return }
        if await decide(draft, .revise, feedback: String(f.prefix(4_000)), threadID: threadID) {
            var s = states[threadID] ?? CommsOmniState()
            s.drafting = true
            states[threadID] = s
            startPolling(threadID)
        }
    }

    /// Edit: the draft is discarded FIRST; only once that succeeded does its text move into the
    /// composer, where the owner sends it himself (review M4: never a pending or already-sent draft
    /// plus the same text in the composer).
    public func edit(_ draft: Approval, threadID: String) async {
        guard let d = CommsDraft(draft) else { return }
        // Text that fails the character policy never reaches the composer either (review M3).
        if let why = DraftText.problem(d.body) {
            notices[threadID] = Notice(why)
            return
        }
        guard await decide(draft, .cancel, feedback: nil, threadID: threadID) else {
            if notices[threadID] == nil { notices[threadID] = Notice("Couldn't take this draft back, so it wasn't moved to the composer.") }
            return
        }
        endAsk(threadID: threadID)
        composerInsert[threadID] = d.body
    }

    private func decide(_ draft: Approval, _ decision: ApprovalDecisionKind, feedback: String?, threadID: String) async -> Bool {
        guard !deciding.contains(draft.id) else { return false }
        deciding.insert(draft.id)
        defer { deciding.remove(draft.id) }
        let slot = "\(draft.id):\(decision.rawValue)"
        let key = keys[slot] ?? .random()
        keys[slot] = key
        notices[threadID] = nil
        var ok = false
        do {
            let r = try await backend.decide(draft: draft, decision, feedback: feedback, idempotencyKey: key)
            switch r.approval.status {
            case .failed:
                keys[slot] = nil
                notices[threadID] = Notice("Not sent. \(Self.reason(r.approval))")
            case .unknown:
                notices[threadID] = Notice("The server couldn't confirm it was sent. Check the conversation before sending it again.")
            default:
                keys[slot] = nil
                ok = true
            }
            replace(r.approval, threadID: threadID)
        } catch PrismError.outcomeUnknown {
            notices[threadID] = Notice("No answer from the server. Try again — it won't be sent twice.")
        } catch {
            keys[slot] = nil
            notices[threadID] = Notice(Self.message(for: error))
        }
        await load(threadID)
        await loadNeedsYou()
        return ok
    }

    private func replace(_ a: Approval, threadID: String) {
        if var s = states[threadID], let i = s.drafts.firstIndex(where: { $0.id == a.id }) {
            s.drafts[i] = a
            states[threadID] = s
        }
        needsYou.removeAll { $0.id == a.id && !a.isPending }
    }

    static func reason(_ a: Approval) -> String {
        switch a.result?["error"]?.stringValue {
        case "target_changed": "This conversation changed since Omni drafted it."
        case "bridge_command": "Messages starting with ! can't be sent here."
        case let e?: "(\(e))"
        case nil: ""
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case CommsOmniError.disabled: "Omni isn't available on this server."
        case CommsOmniError.deviceRequired: "Ask Omni from your signed-in device."
        case CommsOmniError.rateLimited: "Omni has a lot to do right now. Try again in a moment."
        case CommsOmniError.invalid(let why): why
        case CommsOmniError.unavailable: "Omni isn't answering right now."
        case OmniError.executorNotReady: "Sending is switched off on the server. The draft is kept."
        case OmniError.localDigestMismatch: "This draft changed. Review it again before sending."
        case let e as PrismError where e.serverCode == "digest_mismatch": "This draft changed. Review it again before sending."
        case let e as PrismError where e.serverCode == "already_decided" || e.serverCode == "in_progress": "This draft was already decided."
        case let e as PrismError where e.serverCode == "expired": "This draft expired."
        case let e as PrismError where e.serverCode == "draft_refused": "This draft can't be sent (too long, or it holds invisible characters). Discard it."
        default: "Something went wrong. Try again."
        }
    }
}
