import CommsClient
import CommsCore
import Foundation
import OmniClient
import os
import PrismModels
import PrismTransport

/// The fixture's Omni (tests, the DEBUG demo, UI tests): `@Omni` answers with a draft after a
/// short delay, decisions behave as the server's (a digest that does not match is refused; Approve
/// & Send goes through this backend's own send path, so the sent message echoes like any other).
/// Nothing touches the network.
public final class FixtureOmni: Sendable {
    public struct Decision: Sendable, Equatable {
        public var approvalID: String
        public var decision: String
        public var digest: String
        public var feedback: String?
        public var key: String
    }

    struct State {
        var available = false
        var states: [String: CommsOmniState] = [:]
        var approvals: [Approval] = []
        var asks: [(threadID: String, instruction: String, messageIDs: [String])] = []
        var catchUps: [String] = []
        /// (threadID, turnID) the owner closed Omni's note for — like the server, for every device.
        var dismissed: Set<[String]> = []
        var decisions: [Decision] = []
        var replies: [String: ApprovalDecision] = [:]
        var delay: Duration = .milliseconds(600)
        var count = 0
        var draftFor: @Sendable (String) -> String = { _ in "Sounds good — Thursday at 3 works for me." }
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    /// Sends an approved draft's text (the backend's own send path).
    let send: @Sendable (String, String) async throws -> Void

    init(send: @escaping @Sendable (String, String) async throws -> Void) { self.send = send }

    public func setAvailable(_ on: Bool) { state.withLock { $0.available = on } }
    public func setDelay(_ d: Duration) { state.withLock { $0.delay = d } }
    public func setDraftText(_ f: @escaping @Sendable (String) -> String) { state.withLock { $0.draftFor = f } }
    public var decisions: [Decision] { state.withLock { $0.decisions } }
    public var asks: [(threadID: String, instruction: String, messageIDs: [String])] { state.withLock { $0.asks } }
    public var catchUps: [String] { state.withLock { $0.catchUps } }
    public var dismissedNotes: Set<[String]> { state.withLock { $0.dismissed } }
    var available: Bool { state.withLock { $0.available } }

    /// Put a pending draft on a conversation now (as if Omni had proposed it).
    @discardableResult
    public func addDraft(threadID: String, body: String, summary: String = "Reply") -> Approval {
        let a = Self.approval(id: "apr_fx_\(state.withLock { s -> Int in s.count += 1; return s.count })", threadID: threadID, body: body, summary: summary)
        state.withLock { s in
            s.approvals.insert(a, at: 0)
            var st = s.states[threadID] ?? CommsOmniState()
            st.drafts.insert(a, at: 0)
            s.states[threadID] = st
        }
        return a
    }

    /// Put a pending non-Comms proposal in Needs You (a calendar invite: approved in the Omni app).
    @discardableResult
    public func addProposal(kind: String = "calendar-invite", payload: [String: String], summary: String) -> Approval {
        let id = "apr_fx_\(state.withLock { s -> Int in s.count += 1; return s.count })"
        let value: JSONValue = .object(payload.mapValues { .string($0) })
        let json: [String: Any] = [
            "id": id, "kind": kind, "payload": payload, "digest": ApprovalDigest.digest(kind: kind, payload: value),
            "summary": summary, "status": "pending",
            "createdAt": "2026-11-22T10:00:00.000Z", "expiresAt": "2026-11-23T10:00:00.000Z",
        ]
        let a = try! PrismJSON.decoder().decode(Approval.self, from: try! JSONSerialization.data(withJSONObject: json))
        state.withLock { $0.approvals.append(a) }
        return a
    }

    /// An approval as the server writes it (its digest over the exact payload).
    public static func approval(id: String, threadID: String, body: String, summary: String = "Reply", status: String = "pending") -> Approval {
        let payload: JSONValue = .object(["commsThreadId": .string(threadID), "roomId": .string("!fx:\(threadID)"), "body": .string(body)])
        let digest = ApprovalDigest.digest(kind: "message", payload: payload)
        let json: [String: Any] = [
            "id": id, "threadId": "omni-comms-\(threadID)", "kind": "message",
            "payload": ["commsThreadId": threadID, "roomId": "!fx:\(threadID)", "body": body],
            "digest": digest, "summary": summary, "status": status,
            "createdAt": "2026-11-22T10:00:00.000Z", "expiresAt": "2026-11-23T10:00:00.000Z",
            "executor": ["name": "comms-send", "available": true, "enabled": true],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! PrismJSON.decoder().decode(Approval.self, from: data)
    }

    private func with(_ a: Approval, status: String) -> Approval {
        Self.approval(id: a.id, threadID: CommsDraft(a)?.threadID ?? "", body: CommsDraft(a)?.body ?? "", summary: a.summary ?? "Reply", status: status)
    }

    private func setStatus(_ id: String, _ status: String) -> Approval? {
        state.withLock { s -> Approval? in
            guard let i = s.approvals.firstIndex(where: { $0.id == id }) else { return nil }
            let a = with(s.approvals[i], status: status)
            s.approvals[i] = a
            for (t, var st) in s.states {
                if let j = st.drafts.firstIndex(where: { $0.id == id }) {
                    st.drafts[j] = a
                    if status == "revised" { st.drafts.remove(at: j) }
                    s.states[t] = st
                }
            }
            return a
        }
    }

    // MARK: ChatBackend side

    func omniState(threadID: String) throws -> CommsOmniState {
        guard available else { throw CommsOmniError.disabled }
        return state.withLock { s in
            var st = s.states[threadID] ?? CommsOmniState()
            if let t = st.turn, s.dismissed.contains([threadID, t.id]) { st.reply = nil }
            return st
        }
    }

    func dismiss(threadID: String, turnID: String) {
        state.withLock { _ = $0.dismissed.insert([threadID, turnID]) }
    }

    func ask(threadID: String, instruction: String, messageIDs: [String]) throws -> CommsOmniStart {
        guard available else { throw CommsOmniError.disabled }
        let (delay, text, n) = state.withLock { s -> (Duration, String, Int) in
            s.asks.append((threadID, instruction, messageIDs))
            s.count += 1
            var st = s.states[threadID] ?? CommsOmniState()
            st.drafting = true
            st.turn = CommsOmniTurn(id: "turn_fx_\(s.count)", kind: .draft, status: "running")
            s.states[threadID] = st
            return (s.delay, s.draftFor(instruction), s.count)
        }
        Task { [self] in
            try? await Task.sleep(for: delay)
            addDraft(threadID: threadID, body: text, summary: "Reply")
            state.withLock { s in
                var st = s.states[threadID] ?? CommsOmniState()
                st.drafting = false
                st.turn = CommsOmniTurn(id: "turn_fx_\(n)", kind: .draft, status: "done")
                st.reply = CommsOmniReply(text: "Here's a draft for you to check.")
                s.states[threadID] = st
            }
        }
        return CommsOmniStart(omniThreadId: "omni-comms-\(threadID)", turnId: "turn_fx_\(n)", kind: .draft)
    }

    func catchUp(threadID: String) throws -> CommsOmniStart {
        guard available else { throw CommsOmniError.disabled }
        let (delay, n) = state.withLock { s -> (Duration, Int) in
            s.catchUps.append(threadID)
            s.count += 1
            var st = s.states[threadID] ?? CommsOmniState()
            st.drafting = true
            st.turn = CommsOmniTurn(id: "turn_fx_\(s.count)", kind: .catchUp, status: "running")
            s.states[threadID] = st
            return (s.delay, s.count)
        }
        Task { [self] in
            try? await Task.sleep(for: delay)
            state.withLock { s in
                var st = s.states[threadID] ?? CommsOmniState()
                st.drafting = false
                st.turn = CommsOmniTurn(id: "turn_fx_\(n)", kind: .catchUp, status: "done")
                st.reply = CommsOmniReply(text: "• They asked whether Thursday works for the grant call.\n• Nothing else needs you.")
                s.states[threadID] = st
            }
        }
        return CommsOmniStart(omniThreadId: "omni-comms-\(threadID)", turnId: "turn_fx_\(n)", kind: .catchUp)
    }

    func decide(draft: Approval, _ decision: ApprovalDecisionKind, feedback: String?, key: IdempotencyKey) async throws -> ApprovalDecision {
        guard available else { throw CommsOmniError.disabled }
        // The server's rules: the digest the owner saw, once per key, only while pending.
        if let replay = state.withLock({ $0.replies[key.value] }) { return ApprovalDecision(approval: replay.approval, replayed: true) }
        let current = state.withLock { $0.approvals.first { $0.id == draft.id } }
        guard let current else { throw PrismError.rejected(ServerFailure(status: 404, code: "not_found", detail: nil, body: Data())) }
        state.withLock { $0.decisions.append(Decision(approvalID: draft.id, decision: decision.rawValue, digest: draft.digest, feedback: feedback, key: key.value)) }
        guard current.digest == draft.digest else { throw PrismError.conflict(ServerFailure(status: 409, code: "digest_mismatch", detail: nil, body: Data())) }
        guard current.isPending else { throw PrismError.conflict(ServerFailure(status: 409, code: "already_decided", detail: nil, body: Data())) }
        let out: Approval?
        switch decision.rawValue {
        case "send":
            guard let d = CommsDraft(current) else { throw PrismError.rejected(ServerFailure(status: 400, code: "bad_request", detail: nil, body: Data())) }
            _ = setStatus(draft.id, "approved")
            do {
                try await send(d.threadID, d.body)
                out = setStatus(draft.id, "sent")
            } catch {
                out = setStatus(draft.id, "failed")
            }
        case "cancel":
            out = setStatus(draft.id, "cancelled")
        case "revise":
            out = setStatus(draft.id, "revised")
            if let d = CommsDraft(current), let feedback {
                let delay = state.withLock { s -> Duration in
                    var st = s.states[d.threadID] ?? CommsOmniState()
                    st.drafting = true
                    s.states[d.threadID] = st
                    return s.delay
                }
                Task { [self] in
                    try? await Task.sleep(for: delay)
                    addDraft(threadID: d.threadID, body: "\(d.body) (\(feedback))", summary: "Reply")
                    state.withLock { s in s.states[d.threadID]?.drafting = false }
                }
            }
        default:
            throw PrismError.rejected(ServerFailure(status: 400, code: "bad_request", detail: nil, body: Data()))
        }
        let result = ApprovalDecision(approval: out ?? current, httpStatus: out?.status == .failed ? 422 : 200)
        state.withLock { $0.replies[key.value] = result }
        return result
    }

    func pending() -> [Approval] {
        guard available else { return [] }
        return state.withLock { $0.approvals.filter(\.isPending) }
    }
}

extension FixtureBackend {
    public var omniAvailable: Bool { omni.available }
    public func omniState(threadID: String) async throws -> CommsOmniState { try omni.omniState(threadID: threadID) }
    public func askOmni(threadID: String, instruction: String, messageIDs: [String], idempotencyKey: IdempotencyKey) async throws -> CommsOmniStart {
        try omni.ask(threadID: threadID, instruction: instruction, messageIDs: messageIDs)
    }
    public func catchUp(threadID: String, idempotencyKey: IdempotencyKey) async throws -> CommsOmniStart { try omni.catchUp(threadID: threadID) }
    public func decide(draft: Approval, _ decision: ApprovalDecisionKind, feedback: String?, idempotencyKey: IdempotencyKey) async throws -> ApprovalDecision {
        try await omni.decide(draft: draft, decision, feedback: feedback, key: idempotencyKey)
    }
    public func pendingApprovals() async throws -> [Approval] { omni.pending() }
    public func dismissOmniNote(threadID: String, turnID: String) async throws { omni.dismiss(threadID: threadID, turnID: turnID) }
}
