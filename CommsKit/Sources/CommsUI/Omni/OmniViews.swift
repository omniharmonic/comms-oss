import CommsClient
import CommsCore
import PrismModels
import SwiftUI

// Omni in Comms (PRD §5.7, D9). Omni never speaks in the chat: its drafts are dashed bubbles (the
// Send Later look) with Approve & Send / Edit / Refine… / Discard, its answers are private cards,
// and "Omni is drafting…" floats above the composer like Messages' translation chip.

extension EnvironmentValues {
    /// The window's Omni state (nil = no Omni: previews, older servers).
    @Entry public var omniStore: OmniStore? = nil
}

/// Omni's colour: the composer tint in Omni mode, the sparkle on drafts and cards.
public enum OmniStyle {
    public static let tint = Color(red: 0.49, green: 0.36, blue: 0.96)
    public static let sparkle = "sparkle"
}

/// One Omni draft at the end of the transcript: the centred caption "Omni drafted a reply", the
/// dashed outgoing bubble with the sparkle (a capped, scrolling PREVIEW), and its actions.
///
/// Approve & Send is NOT offered here (review round 2, N1: what is visible inside a bubble at the
/// bottom of a squeezed screen — landscape, keyboard up, large text — is not provably what the owner
/// saw). "Review & Send…" opens `DraftReview`, a sheet where every line has to have been on screen
/// before Approve & Send is enabled.
public struct OmniDraftBubble: View {
    let body_: String
    let busy: Bool
    let canSend: Bool
    let onApprove: () -> Void
    let onEdit: () -> Void
    let onRefine: (String) -> Void
    let onDiscard: () -> Void
    /// The review sheet's header and bubble colour.
    let recipient: String?
    let network: CommsNetwork?
    /// A forum draft: the topic it posts in (shown on the card and in the review header).
    let topic: String?

    @State private var refining = false
    @State private var feedback = ""
    @State private var reviewing = false

    public init(text: String, busy: Bool = false, canSend: Bool = true, onApprove: @escaping () -> Void = {}, onEdit: @escaping () -> Void = {},
                onRefine: @escaping (String) -> Void = { _ in }, onDiscard: @escaping () -> Void = {},
                recipient: String? = nil, network: CommsNetwork? = nil, topic: String? = nil) {
        body_ = text
        self.topic = topic
        self.recipient = recipient
        self.network = network
        self.busy = busy
        self.canSend = canSend
        self.onApprove = onApprove
        self.onEdit = onEdit
        self.onRefine = onRefine
        self.onDiscard = onDiscard
    }

    /// "Trailhead Collective in #Gear": who a forum draft goes to.
    static func recipient(_ r: String?, topic: String?) -> String? {
        guard let topic else { return r }
        return r.map { "\($0) in #\(topic)" } ?? "#\(topic)"
    }

    #if os(macOS)
    static let font: CGFloat = 13
    static let radius: CGFloat = 14
    static let side: CGFloat = 16
    /// The preview never grows past this (it scrolls).
    static let maxTextHeight: CGFloat = 120
    #else
    static let font: CGFloat = 17
    static let radius: CGFloat = 18
    static let side: CGFloat = 16
    static let maxTextHeight: CGFloat = 132
    #endif

    @ViewBuilder private var secondaryActions: some View {
        Button("Discard", role: .destructive, action: onDiscard)
            .lineLimit(1)
            .tint(.red)
            .accessibilityIdentifier("draft-discard")
        Button("Refine…") { refining = true }
            .lineLimit(1)
            .accessibilityIdentifier("draft-refine")
        Button("Edit", action: onEdit)
            .lineLimit(1)
            .accessibilityIdentifier("draft-edit")
    }

    private var reviewButton: some View {
        Button { reviewing = true } label: {
            Text("Review & Send…").lineLimit(1).fixedSize()
        }
        .buttonStyle(.glassProminent)
        .tint(OmniStyle.tint)
        .disabled(!canSend)
        .accessibilityHint(canSend ? "Opens the whole draft; Approve & Send is there" : "Sending isn't available in this conversation")
        .accessibilityIdentifier("draft-review")
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(topic.map { "Omni drafted a reply in #\($0)" } ?? "Omni drafted a reply")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 60)
                ScrollView(.vertical) {
                    Text(body_)
                        .font(.system(size: Self.font))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: Self.maxTextHeight)
                .fixedSize(horizontal: false, vertical: true)
                .overlay {
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                        .strokeBorder(Tokens.color.accent.color, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    Image(systemName: OmniStyle.sparkle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OmniStyle.tint)
                        .padding(3)
                        .background(.background, in: .circle)
                        .offset(x: -6, y: -6)
                        .allowsHitTesting(false)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Draft from Omni: \(body_)")
                .accessibilityIdentifier("omni-draft")
            }
            // One row as in Messages' wide bubbles; the main action alone on top when the row would wrap.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { secondaryActions; reviewButton }
                VStack(alignment: .trailing, spacing: 8) {
                    reviewButton
                    HStack(spacing: 8) { secondaryActions }
                }
            }
            // Round 3 (owner: "tiny low-contrast grey pills"): regular-size glass buttons with
            // full-contrast labels; Discard in red, Review & Send in Omni's colour.
            .buttonStyle(.glass)
            .controlSize(.regular)
            .font(.subheadline.weight(.semibold))
            .disabled(busy)
        }
        .padding(.horizontal, Self.side)
        .sheet(isPresented: $reviewing) {
            DraftReview(text: body_, busy: busy, canSend: canSend, recipient: Self.recipient(recipient, topic: topic), network: network,
                        onEdit: onEdit, onRefine: onRefine) {
                reviewing = false
                onApprove()
            }
            .id(body_) // other text = a new reading (review M1)
        }
        .alert("Refine Draft", isPresented: $refining) {
            TextField("Tell Omni what to change", text: $feedback)
                .accessibilityIdentifier("draft-refine-field")
            Button("Cancel", role: .cancel) { feedback = "" }
            Button("Refine") {
                let f = feedback
                feedback = ""
                onRefine(f)
            }
        } message: {
            Text("Omni will write a new draft. Nothing is sent.")
        }
    }
}

/// The only place Approve & Send exists: the whole draft in a sheet, its text in a scroll view
/// that is on screen by construction. Every line must have been on screen — the union of the
/// visible ranges must cover the text from top to bottom (`ReadCoverage`; a jump leaves a gap and
/// keeps the button disabled) — and the text must pass the character policy (`DraftText`).
public struct DraftReview: View {
    let text: String
    let busy: Bool
    let canSend: Bool
    let onApprove: () -> Void
    /// Who it goes to and on which network (the header and the bubble's colour); nil = unknown.
    let recipient: String?
    let network: CommsNetwork?
    /// Secondary actions (nil = not offered here): Edit moves the text to the composer (after the
    /// draft is taken back), Refine… asks Omni for a new draft with this feedback.
    let onEdit: (() -> Void)?
    let onRefine: ((String) -> Void)?
    /// False in snapshots (no dismiss environment): the close button is left out.
    let embedded: Bool
    @State private var coverage = ReadCoverage()
    @State private var lastSeen = ""
    @State private var height: CGFloat = 360
    @State private var refining = false
    @State private var feedback = ""
    @Environment(\.dismiss) private var dismiss

    public init(text: String, busy: Bool = false, canSend: Bool = true, recipient: String? = nil, network: CommsNetwork? = nil,
                embedded: Bool = true, onEdit: (() -> Void)? = nil, onRefine: ((String) -> Void)? = nil, onApprove: @escaping () -> Void = {}) {
        self.text = text
        self.busy = busy
        self.canSend = canSend
        self.recipient = recipient
        self.network = network
        self.embedded = embedded
        self.onEdit = onEdit
        self.onRefine = onRefine
        self.onApprove = onApprove
    }

    #if os(macOS)
    static let maxTextHeight: CGFloat = 360
    static let width: CGFloat = 480
    #else
    static let maxTextHeight: CGFloat = 420
    #endif

    private var problem: String? { DraftText.problem(text) }
    private var readFraction: Double {
        let h = coverage.contentHeight
        guard h > 0 else { return 0 }
        let seen = coverage.ranges.reduce(CGFloat(0)) { $0 + ($1.upperBound - $1.lowerBound) }
        return Double(min(seen, h) / h)
    }
    /// "Read 40 %" for VoiceOver (DEBUG builds add the raw ranges, for the UI tests).
    private var coverageDescription: String {
        let pct = Int((readFraction * 100).rounded())
        #if DEBUG
        return "Read \(pct) % " + coverage.ranges.map { "\(Int($0.lowerBound))-\(Int($0.upperBound))" }.joined(separator: ",") + " of \(Int(coverage.contentHeight)) last \(lastSeen)"
        #else
        return "Read \(pct) %"
        #endif
    }
    private var approvable: Bool { canSend && !busy && problem == nil && coverage.isComplete }
    private var bubbleFill: Color {
        Tokens.color.outgoingByNetwork.shade(for: network ?? .imessage).mac.color
    }
    private var title: String {
        if let recipient, !recipient.isEmpty { return "Omni's draft for \(recipient)" }
        return "Omni's draft"
    }

    public var body: some View {
        VStack(spacing: 14) {
            header
            // The draft as it will look: an outgoing bubble in the chat's network colour. The
            // scroll view's frame IS the on-screen viewport (no insets over the text), so its
            // visible range is exactly what the owner sees (review round 2, N1).
            ScrollView {
                HStack(spacing: 0) {
                    Spacer(minLength: 36)
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(bubbleFill, in: .rect(cornerRadius: 18, style: .continuous))
                        .accessibilityIdentifier("draft-full-text")
                }
                .padding(.vertical, 4)
            }
            .contentMargins(0, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.maxTextHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onScrollGeometryChange(for: [CGFloat].self) { g in
                [g.contentOffset.y + g.contentInsets.top, g.contentOffset.y + g.containerSize.height - g.contentInsets.bottom, g.contentSize.height, g.containerSize.width]
            } action: { _, v in
                coverage.see(v[0]...max(v[0], v[1]), contentHeight: v[2], width: v[3])
                #if DEBUG
                lastSeen = v.map { String(Int($0)) }.joined(separator: "/")
                #endif
            }
            status
            actions
        }
        .padding(20)
        #if os(macOS)
        // The sheet's natural width (a Mac sheet sizes to its content's ideal size).
        .frame(idealWidth: Self.width)
        #endif
        // Sized to its content: the sheet is as tall as the draft needs (up to the cap).
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        #if os(iOS)
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.hidden)
        #endif
        .alert("Refine Draft", isPresented: $refining) {
            TextField("Tell Omni what to change", text: $feedback)
                .accessibilityIdentifier("draft-refine-field")
            Button("Cancel", role: .cancel) { feedback = "" }
            Button("Refine") {
                let f = feedback
                feedback = ""
                onRefine?(f)
                if embedded { dismiss() }
            }
        } message: {
            Text("Omni will write a new draft. Nothing is sent.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: OmniStyle.sparkle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(OmniStyle.tint.gradient, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("draft-review-title")
                if let network {
                    HStack(spacing: 5) {
                        Circle().fill(bubbleFill).frame(width: 7, height: 7)
                        Text(network.displayName).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassEffect(.regular, in: .capsule)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("draft-review-network")
                }
            }
            Spacer(minLength: 0)
            if embedded {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("draft-review-cancel")
            }
        }
    }

    /// The character-policy refusal, or — subtly — how much has been read.
    @ViewBuilder private var status: some View {
        if let problem {
            Text(problem).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("draft-review-problem")
        } else if !coverage.isComplete {
            HStack(spacing: 8) {
                ProgressView(value: readFraction)
                    .progressViewStyle(.linear)
                    .tint(OmniStyle.tint.opacity(0.7))
                    .frame(width: 60)
                Text("Scroll through the whole draft to approve it")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("draft-read-hint")
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// One row when everything fits at its natural size; otherwise Approve & Send full width with
    /// Edit / Refine… under it (never squeezed).
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                secondaryButtons
                approveButton
            }
            VStack(spacing: 10) {
                approveButton
                HStack(spacing: 10) { secondaryButtons }
            }
        }
    }

    @ViewBuilder private var secondaryButtons: some View {
        if let onEdit {
            Button("Edit") {
                if embedded { dismiss() }
                onEdit()
            }
            .fixedSize()
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(busy)
            .accessibilityIdentifier("draft-review-edit")
        }
        if onRefine != nil {
            Button("Refine…") { refining = true }
                .fixedSize()
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(busy)
                .accessibilityIdentifier("draft-review-refine")
        }
    }

    private var approveButton: some View {
        Button(action: onApprove) {
            Label("Approve & Send", systemImage: "faceid")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(OmniStyle.tint)
        .controlSize(.large)
        .disabled(!approvable)
        .accessibilityHint(approvable ? "Sends this exact text as your message after Face ID or Touch ID" : "Read the whole draft first")
        .accessibilityValue(coverageDescription)
        .accessibilityIdentifier("draft-approve")
    }
}

/// "Omni is drafting…" — the glass chip above the composer.
public struct OmniStatusChip: View {
    let text: String
    public init(_ text: String = "Omni is drafting…") { self.text = text }
    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: OmniStyle.sparkle)
                .foregroundStyle(OmniStyle.tint)
                .symbolEffect(.pulse, options: .repeating)
            Text(text)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("omni-drafting")
    }
}

/// Omni's private answer (catch me up, or what it said about a draft): only the owner sees it.
public struct OmniNoteCard: View {
    let title: String
    let text: String
    let onClose: () -> Void
    public init(title: String, text: String, onClose: @escaping () -> Void = {}) {
        self.title = title
        self.text = text
        self.onClose = onClose
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: OmniStyle.sparkle).foregroundStyle(OmniStyle.tint)
                Text(title).font(.footnote.weight(.semibold))
                Text("· Only you can see this").font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("omni-note-close")
            }
            ScrollView {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 96)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("omni-note")
    }
}

/// The suggestion slot above the composer: "Draft with Omni" (an owed reply) and "Catch Me Up"
/// (a long unread run).
struct OmniSuggestionChips: View {
    let showsDraft: Bool
    let showsCatchUp: Bool
    let onDraft: () -> Void
    let onCatchUp: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            if showsDraft {
                chip("Draft with Omni", id: "omni-chip-draft", action: onDraft)
            }
            if showsCatchUp {
                chip("Catch Me Up", id: "omni-chip-catchup", action: onCatchUp)
            }
        }
    }
    private func chip(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: OmniStyle.sparkle)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .tint(OmniStyle.tint)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier(id)
    }
}

/// Everything Omni adds to one transcript, stacked above the composer (so it reads as the end of
/// the conversation): Omni's private note, the pending drafts, a notice, "Omni is drafting…", and
/// the suggestion chips. Draws nothing when Omni is off.
public struct OmniTranscriptAccessory: View {
    let store: TimelineStore
    @Environment(\.omniStore) private var omni
    @State private var draftIndex = 0
    @State private var showsNote = false

    public init(store: TimelineStore) { self.store = store }

    /// A long unread run earns "Catch Me Up".
    static let catchUpUnread = 10

    public var body: some View {
        if let omni, omni.isAvailable {
            let id = store.threadID
            VStack(spacing: 10) {
                let drafts = omni.drafts(id)
                // Omni's note: shown when no draft waits; with a draft, one tap away (it may explain it).
                if let r = omni.reply(id) {
                    if drafts.isEmpty || showsNote {
                        OmniNoteCard(title: r.turn.kind == .catchUp ? "Catch Up" : "Omni", text: r.reply.text) {
                            if drafts.isEmpty { omni.dismissReply(id) } else { showsNote = false }
                        }
                        .transition(.opacity)
                    } else {
                        Button { showsNote = true } label: { Label("Omni's Note", systemImage: OmniStyle.sparkle).font(.caption.weight(.semibold)) }
                            .buttonStyle(.plain).foregroundStyle(OmniStyle.tint)
                            .accessibilityIdentifier("omni-note-show")
                    }
                }
                // One draft at a time (review C1); the others are a tap away (N5).
                let index = min(draftIndex, max(drafts.count - 1, 0))
                if drafts.count > 1 {
                    HStack(spacing: 8) {
                        Text("Draft \(index + 1) of \(drafts.count)").font(.caption2).foregroundStyle(.secondary)
                        Button("Next Draft") { draftIndex = (index + 1) % drafts.count }
                            .font(.caption2.weight(.semibold)).buttonStyle(.plain).foregroundStyle(Tokens.color.accent.color)
                            .accessibilityIdentifier("omni-next-draft")
                    }
                    .accessibilityIdentifier("omni-more-drafts")
                }
                if drafts.indices.contains(index), let d = CommsDraft(drafts[index]) {
                    let draft = drafts[index]
                    OmniDraftBubble(
                        text: d.body, busy: omni.deciding.contains(draft.id), canSend: store.canSend,
                        onApprove: { Task { await omni.approve(draft, threadID: id) } },
                        onEdit: { Task { await omni.edit(draft, threadID: id) } },
                        onRefine: { f in Task { await omni.refine(draft, threadID: id, feedback: f) } },
                        onDiscard: { Task { await omni.discard(draft, threadID: id) } },
                        recipient: store.thread?.title, network: store.sendNetwork, topic: d.topic)
                    .id(draft.id) // a new draft starts unread
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let n = omni.notices[id] {
                    Text(n.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .accessibilityIdentifier("omni-notice")
                        .onTapGesture { omni.clearNotice(id) }
                }
                if omni.isDrafting(id) {
                    OmniStatusChip(omni.state(id)?.turn?.kind == .catchUp ? "Omni is reading…" : "Omni is drafting…")
                        .transition(.scale.combined(with: .opacity))
                } else {
                    let owed = store.thread.map { $0.urgency == .needsReply || $0.urgency == .urgent } ?? false
                    let unread = store.thread?.unread.count ?? 0
                    let draft = owed && omni.drafts(id).isEmpty && !omni.omniComposer.contains(id)
                    let catchUp = unread >= Self.catchUpUnread && omni.reply(id) == nil
                    if draft || catchUp {
                        OmniSuggestionChips(showsDraft: draft, showsCatchUp: catchUp,
                                            onDraft: { Task { await omni.ask(threadID: id, text: "Draft a reply to the latest message.") } },
                                            onCatchUp: { Task { await omni.catchUp(threadID: id) } })
                    }
                }
            }
            .animation(.snappy, value: omni.drafts(id).map(\.id))
            .animation(.snappy, value: omni.isDrafting(id))
            .task(id: id) { await omni.load(id) }
        }
    }
}

/// Needs you: the owner's pending Omni proposals. EVERY row opens (polish r2 — the owner "can't
/// click through"; non-draft rows used to be disabled): a Comms reply draft opens the draft review
/// sheet (Approve & Send lives only there), any other proposal (tasks, invites, emails…) opens
/// read-only with "Approve in Omni" (the Omni app's `omni://approval/<id>`).
public struct NeedsYouList: View {
    let items: [Approval]
    /// "Show Conversation" from a Comms draft (nil = not offered).
    let onOpenConversation: ((String) -> Void)?
    @State private var opened: Approval?

    public init(items: [Approval], onOpenConversation: ((String) -> Void)? = nil) {
        self.items = items
        self.onOpenConversation = onOpenConversation
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { a in
                NeedsYouRow(approval: a) { opened = a }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("needs-you")
        .sheet(item: $opened) { a in
            NeedsYouDetail(approval: a, onOpenConversation: onOpenConversation.map { open in
                { id in opened = nil; open(id) }
            })
        }
    }
}

struct NeedsYouRow: View {
    let approval: Approval
    let open: () -> Void

    static func title(_ a: Approval) -> String {
        if CommsDraft(a) != nil { return a.summary ?? "Reply draft" }
        if let s = a.summary, !s.isEmpty { return s }
        return kindTitle(a)
    }

    static func kindTitle(_ a: Approval) -> String {
        if CommsDraft(a) != nil { return "Reply draft" }
        switch a.kind.rawValue {
        case "email": return "Email draft"
        case "email-reply": return "Email reply"
        case "calendar-invite": return "Calendar invite"
        case "calendar-rsvp": return "RSVP"
        case "message": return "Message"
        case "tweet": return "Post"
        case "action": return "Action"
        default: return "Omni proposal"
        }
    }

    static func detail(_ a: Approval) -> String {
        if let d = CommsDraft(a) { return d.body }
        return a.payload["body"]?.stringValue ?? a.payload["title"]?.stringValue ?? a.payload["text"]?.stringValue ?? "Approve in Omni"
    }

    var body: some View {
        let isDraft = CommsDraft(approval) != nil
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isDraft ? "text.bubble" : OmniStyle.sparkle)
                    .foregroundStyle(OmniStyle.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(approval)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(Self.detail(approval)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(isDraft ? "Opens the draft to review and send" : "Opens the proposal; approve it in Omni")
        .accessibilityIdentifier("needs-you-row")
    }
}

/// One Needs You item, opened: the draft review sheet for a Comms reply draft, else the proposal
/// read-only with "Approve in Omni".
struct NeedsYouDetail: View {
    let approval: Approval
    let onOpenConversation: ((String) -> Void)?
    @Environment(\.omniStore) private var omni
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let d = CommsDraft(approval) {
            VStack(spacing: 0) {
                DraftReview(text: d.body, busy: omni?.deciding.contains(approval.id) ?? true, canSend: omni != nil,
                            recipient: OmniDraftBubble.recipient(approval.summary.map { $0.hasPrefix("Reply to ") ? String($0.dropFirst(9)) : $0 }, topic: d.topic),
                            onEdit: onOpenConversation.map { open in {
                                Task { await omni?.edit(approval, threadID: d.threadID) }
                                open(d.threadID)
                            } },
                            onRefine: { f in Task { await omni?.refine(approval, threadID: d.threadID, feedback: f) } }) {
                    Task {
                        // Face ID / Touch ID, then exactly this draft (OmniStore.approve).
                        if await omni?.approve(approval, threadID: d.threadID) == true { dismiss() }
                    }
                }
                .id(d.body)
                if let notice = omni?.notices[d.threadID] {
                    Text(notice.text).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal).padding(.bottom, 8)
                        .accessibilityIdentifier("needs-you-notice")
                }
                if let onOpenConversation {
                    Button("Show Conversation") { onOpenConversation(d.threadID) }
                        .padding(.bottom, 14)
                        .accessibilityIdentifier("needs-you-show-conversation")
                }
            }
        } else {
            ProposalReadOnly(approval: approval)
        }
    }
}

/// A non-Comms Omni proposal, read-only. Approving happens in the Omni app (its own review and
/// executors); Comms never decides these.
struct ProposalReadOnly: View {
    let approval: Approval
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var omniMissing = false

    /// The Omni app's link to this approval.
    static func omniURL(_ a: Approval) -> URL? {
        guard a.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }), !a.id.isEmpty else { return nil }
        return URL(string: "omni://approval/\(a.id)")
    }

    /// The payload's readable fields, in a fixed order (never raw JSON).
    static func fields(_ a: Approval) -> [(String, String)] {
        let order: [(String, String)] = [
            ("to", "To"), ("expectTo", "To"), ("cc", "Cc"), ("subject", "Subject"), ("title", "Title"), ("start", "Starts"),
            ("end", "Ends"), ("location", "Location"), ("attendees", "Attendees"), ("amount", "Amount"), ("token", "Token"),
            ("chain", "Chain"), ("purpose", "Purpose"), ("reaches", "Reaches"), ("url", "Link"),
        ]
        var out: [(String, String)] = []
        for (key, label) in order {
            guard let v = a.payload[key] else { continue }
            let text = v.stringValue ?? v.stringArrayValue?.joined(separator: ", ") ?? v.doubleValue.map { String($0) }
            if let text, !text.isEmpty, !out.contains(where: { $0.0 == label }) { out.append((label, text)) }
        }
        return out
    }

    static func body(_ a: Approval) -> String? {
        for key in ["body", "text", "description"] { if let s = a.payload[key]?.stringValue, !s.isEmpty { return s } }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Done") { dismiss() }.accessibilityIdentifier("proposal-done")
                Text(NeedsYouRow.kindTitle(approval)).font(.headline).lineLimit(1).frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                Button("Done") {}.hidden().accessibilityHidden(true)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let s = approval.summary, !s.isEmpty {
                        Label(s, systemImage: OmniStyle.sparkle).font(.subheadline.weight(.semibold)).foregroundStyle(OmniStyle.tint)
                    }
                    ForEach(Self.fields(approval), id: \.0) { label, value in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(label).font(.subheadline).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                            Text(value).font(.subheadline).textSelection(.enabled)
                        }
                    }
                    if let b = Self.body(approval) {
                        Text(b).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .accessibilityIdentifier("proposal-content")
            Divider()
            VStack(spacing: 6) {
                if omniMissing {
                    Text("Open Omni to approve this proposal.").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("proposal-omni-missing")
                }
                Button {
                    guard let url = Self.omniURL(approval) else { omniMissing = true; return }
                    openURL(url) { accepted in
                        if accepted { dismiss() } else { omniMissing = true }
                    }
                } label: {
                    Label("Approve in Omni", systemImage: OmniStyle.sparkle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .accessibilityHint("Opens this proposal in the Omni app, where it is approved")
                .accessibilityIdentifier("proposal-approve-in-omni")
            }
            .padding()
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}

/// The Needs You page of the list (chosen from the list's folder menu, like a folder).
struct NeedsYouPage: View {
    @Binding var selection: String?
    @Environment(\.omniStore) private var omni

    var body: some View {
        Group {
            if let omni, !omni.needsYou.isEmpty {
                NeedsYouList(items: omni.needsYou) { selection = $0 }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: OmniStyle.sparkle).font(.title2).foregroundStyle(OmniStyle.tint)
                    Text("Nothing Needs You").font(.headline)
                    Text("Omni's drafts and proposals waiting for you show here.").font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("needs-you-empty")
            }
        }
        .task { await omni?.loadNeedsYou() }
    }
}
