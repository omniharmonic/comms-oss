import CommsClient
import CommsCore
import PrismModels
import SwiftUI

/// What a transcript row needs besides the row itself.
struct TranscriptRowContext: Hashable {
    var isGroup: Bool
    /// Space above the row (gaps from `BubbleMetrics`, by what the previous row was).
    var spacingAbove: CGFloat
    /// "Delivered" / "Read" under the owner's newest message (only when it is the last
    /// message and the network reported delivery; nil otherwise).
    var receipt: Receipt? = nil
    /// "Now" for the read time (snapshots pin it; nil = the clock).
    var now: Date? = nil
}

/// Messages' delivery caption under the owner's latest message (sprint Task 8): "Sending…",
/// "Sent", "Delivered", "Read 2:14 PM" (a DM, with the reader's time when the network gives one),
/// or "Read by 3" in a group (tap: who read it, and when). Failed is "Not Delivered", drawn by
/// the row. Only the newest row, and only when it is the owner's (as iMessage: a reply after it
/// hides the caption).
struct Receipt: Hashable {
    enum Kind: Hashable {
        case sending, sent, delivered
        case read(at: Date?)
        case readBy([CommsMessage.Reader])
    }
    var kind: Kind

    /// The receipt for `m` if it is the owner's and not failed; nil otherwise (or when the
    /// network reported nothing — a message without delivery info shows nothing, as Messages).
    init?(_ m: CommsMessage, isGroup: Bool = false) {
        guard m.sender.isSelf, !m.redacted else { return nil }
        switch m.delivery {
        case .pending?: kind = .sending
        case .sent?: kind = .sent
        case .delivered?: kind = .delivered
        case .read?:
            if isGroup, let by = m.readBy, !by.isEmpty { kind = .readBy(by) } else { kind = .read(at: m.readAt ?? m.readBy?.last?.readAt) }
        default: return nil
        }
    }

    init(kind: Kind) { self.kind = kind }

    var text: String { text(now: .now) }

    func text(now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        switch kind {
        case .sending: "Sending…"
        case .sent: "Sent"
        case .delivered: "Delivered"
        case .read(let at?): "Read " + Self.readTime(at, now: now, calendar: calendar, locale: locale)
        case .read(nil): "Read"
        case .readBy(let r): "Read by \(r.count)"
        }
    }

    /// The readers of a group message (the "Read by" list), oldest read first.
    var readers: [CommsMessage.Reader] {
        if case .readBy(let r) = kind { return r }
        return []
    }

    /// Messages' read time: "2:14 PM" today, "Yesterday", a weekday within the week, else the
    /// short numeric date ("11/14/26").
    static func readTime(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 {
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        }
        if days == 1 { return "Yesterday" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        if days < 7 { f.setLocalizedDateFormatFromTemplate("EEEE") } else { f.dateStyle = .short }
        return f.string(from: date)
    }

    /// The receipt for the newest row, when that row is the owner's message.
    static func forLast(_ rows: [TranscriptRow], isGroup: Bool = false) -> (id: TranscriptRow.ID, receipt: Receipt)? {
        guard let last = rows.last, case .message(let m, _, _, _) = last, let r = Receipt(m, isGroup: isGroup) else { return nil }
        return (last.id, r)
    }
}

/// The caption under the owner's newest bubble. A group's "Read by N" opens the per-person list
/// (a popover on the Mac, a sheet on the phone).
struct ReceiptCaption: View {
    let receipt: Receipt
    var now: Date = .now
    @Environment(\.bubbleMetrics) private var metrics
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @State private var showsReaders = false

    private var zoned: Calendar {
        var cal = calendar
        cal.timeZone = timeZone
        return cal
    }

    var body: some View {
        let label = Text(receipt.text(now: now, calendar: zoned, locale: locale))
            .font(.system(size: metrics.captionSize - 1, weight: .semibold))
            .foregroundStyle(Tokens.color.secondaryLabel.color)
        if receipt.readers.isEmpty {
            label.accessibilityIdentifier("receipt")
        } else {
            Button { showsReaders = true } label: { label }
                .buttonStyle(.plain)
                .accessibilityIdentifier("receipt")
                .accessibilityHint("Shows who read it")
                #if os(macOS)
                .popover(isPresented: $showsReaders, arrowEdge: .bottom) { ReadersList(readers: receipt.readers, now: now).frame(minWidth: 240) }
                #else
                .sheet(isPresented: $showsReaders) {
                    NavigationStack {
                        ReadersList(readers: receipt.readers, now: now)
                            .navigationTitle("Read By")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsReaders = false } } }
                    }
                    .presentationDetents([.medium, .large])
                }
                #endif
        }
    }
}

/// Who read a group message, and when: name on the left, read time on the right.
struct ReadersList: View {
    let readers: [CommsMessage.Reader]
    var now: Date = .now

    var body: some View {
        List(readers) { r in
            HStack {
                Text(r.name).lineLimit(1)
                Spacer(minLength: 12)
                Text(Receipt.readTime(r.readAt, now: now))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
        #if os(macOS)
        .listStyle(.inset)
        .frame(minHeight: CGFloat(min(readers.count, 8)) * 28 + 16)
        #endif
        .accessibilityIdentifier("receipt-readers")
    }
}

/// One transcript row: a time header, a system caption, or a message bubble with its
/// "Edited" note. Long messages are shown in full, as Messages does (owner ruling: no
/// "Show more" clamp).
struct TranscriptRowView: View {
    let row: TranscriptRow
    let context: TranscriptRowContext

    @Environment(\.bubbleMetrics) private var metrics

    var body: some View {
        content
            .padding(.top, context.spacingAbove)
            // Mac: the row holds the tail and the group avatar that hang below the bubble (an
            // NSTableView row clips at its bounds); the next row's gap gives the same back.
            .padding(.bottom, Self.overhang(row, metrics: metrics))
            .padding(.horizontal, Self.sideMargin)
            .frame(maxWidth: .infinity, alignment: .top)
            .coordinateSpace(.named(Self.space))
    }

    /// The row's own coordinate space (origin = the cell's top-left): bubble frames are
    /// reported in it.
    static let space = "transcriptRow"

    static let sideMargin: CGFloat = Tokens.calibration.sideMarginCompact

    @ViewBuilder private var content: some View {
        switch row {
        case .time(let date):
            #if os(iOS)
            TimeHeader(date: date)
            #else
            TimeHeader(date: date)
                .padding(.bottom, 2)
            #endif
        case .system(let text, _):
            SystemCaption(actor: nil, text: text)
        case .message(let m, let position, _, _):
            message(m, position: position)
        }
    }

    @ViewBuilder
    private func message(_ m: CommsMessage, position: RunPosition) -> some View {
        let outgoing = m.sender.isSelf
        let failed = outgoing && m.delivery == .failed
        VStack(alignment: outgoing ? .trailing : .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                MessageBubble(message: m, position: position, isGroup: context.isGroup)
                    // Every pending bubble says its state to VoiceOver, not only the newest.
                    .accessibilityValue(Self.deliveryValue(m))
                    // Tapbacks, Reply, Copy… (VoiceOver everywhere; menus and popovers on the Mac).
                    .modifier(MessageInteractionModifier(message: m))
                if failed {
                    NotDeliveredBadge(message: m)
                        .padding(.trailing, 4)
                }
            }
            if m.editedAt != nil, !m.redacted {
                Text("Edited")
                    .foregroundStyle(Tokens.color.secondaryLabel.color)
                    .font(.system(size: metrics.captionSize))
                    .padding(.leading, outgoing ? 0 : leadingInset)
                    .padding(.trailing, outgoing ? metrics.padH : 0)
            }
            if failed {
                // Messages: a red "Not Delivered" under the bubble, beside the red ! badge.
                Text("Not Delivered")
                    .font(.system(size: metrics.captionSize - 1, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.trailing, NotDeliveredBadge.size + 12 + metrics.padH)
                    .padding(.top, 4)
                    .accessibilityIdentifier("not-delivered-caption")
            }
            if let receipt = context.receipt {
                // Messages: Caption 2 semibold, secondary, right-aligned 20 pt from the screen
                // edge, its top 6 pt under the bubble body (real app: x 314 → 366, y +6).
                ReceiptCaption(receipt: receipt, now: context.now ?? .now)
                    .padding(.trailing, 20)
                    .padding(.top, 4) // 6 pt under the bubble body (VStack spacing 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
        .accessibilityElement(children: .contain)
    }

    static func deliveryValue(_ m: CommsMessage) -> String {
        guard m.sender.isSelf, PendingSend.clientID(ofMessageID: m.id) != nil else { return "" }
        switch m.delivery {
        case .pending?: return "Sending"
        case .failed?: return "Not Delivered"
        default: return "Sent"
        }
    }

    /// Notes under an incoming bubble line up with its text (past the group avatar column).
    private var leadingInset: CGFloat {
        metrics.padH + (context.isGroup ? metrics.groupAvatar + metrics.avatarGap : 0)
    }

    /// What hangs below a row's frame: a tailed bubble's tail and the group avatar aligned to its
    /// tip (`metrics.tailDrop`). Counted into the row on the Mac only (its table clips rows;
    /// iOS cells draw past their bounds and keep the calibrated geometry).
    static func overhang(_ row: TranscriptRow, metrics: BubbleMetrics) -> CGFloat {
        #if os(macOS)
        if case .message(let m, let position, _, _) = row, position.hasTail, !m.redacted, m.system == nil { return metrics.tailDrop }
        #endif
        return 0
    }

    /// Space above `row` given the row before it (nil = the first row), less what the row
    /// before already holds below its bubble (`overhang`), so the visible gap is unchanged.
    static func spacingAbove(_ row: TranscriptRow, after previous: TranscriptRow?, metrics: BubbleMetrics) -> CGFloat {
        guard let previous else { return 12 }
        return max(0, gap(row, after: previous, metrics: metrics) - overhang(previous, metrics: metrics))
    }

    private static func gap(_ row: TranscriptRow, after previous: TranscriptRow, metrics: BubbleMetrics) -> CGFloat {
        switch (previous, row) {
        case (_, .time): return 16
        case (.time, _):
            #if os(iOS)
            return 7 // the real app: "Today 12:50 AM" ends 7 pt above the first bubble
            #else
            return 6
            #endif
        case (.system, _), (_, .system): return 8
        case (.message, .message(let m, let position, let showsName, _)):
            if position == .middle || position == .last { return metrics.gapSameSender }
            if m.redacted { return metrics.gapSenderChange }
            // The group gap includes the sender-name line (≈ caption line + same-sender gap).
            if showsName { return max(metrics.gapSenderChange, metrics.gapGroupSenderChange - metrics.captionSize * 1.3 - metrics.gapSameSender) }
            return metrics.gapSenderChange
        }
    }
}

/// What a failed bubble's badge can do: Try Again (same clientId) or Delete. The transcript
/// controllers put the open thread's store behind it.
public struct SendActions: Sendable {
    public var retry: @MainActor @Sendable (String) -> Void
    public var discard: @MainActor @Sendable (String) -> Void
    /// "Send Again as New Message" (past the safe-retry window).
    public var resendAsNew: @MainActor @Sendable (String) -> Void
    /// The failure behind a pending bubble (whether Try Again can work).
    public var failure: @MainActor @Sendable (String) -> CommsSendFailure?
    /// "View Full Email" for an email message id (nil: not offered).
    public var openEmailOriginal: (@MainActor @Sendable (String) -> Void)?

    public init(retry: @escaping @MainActor @Sendable (String) -> Void, discard: @escaping @MainActor @Sendable (String) -> Void,
                resendAsNew: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                failure: @escaping @MainActor @Sendable (String) -> CommsSendFailure? = { _ in nil },
                openEmailOriginal: (@MainActor @Sendable (String) -> Void)? = nil) {
        self.retry = retry
        self.discard = discard
        self.resendAsNew = resendAsNew
        self.failure = failure
        self.openEmailOriginal = openEmailOriginal
    }

    public static let none = SendActions(retry: { _ in }, discard: { _ in })

    /// Actions on `store`'s pending sends.
    @MainActor public static func store(_ store: TimelineStore) -> SendActions {
        SendActions(retry: { [weak store] id in Task { await store?.retrySend(clientID: id) } },
                    discard: { [weak store] id in store?.discardSend(clientID: id) },
                    resendAsNew: { [weak store] id in Task { await store?.resendAsNew(clientID: id) } },
                    failure: { [weak store] id in store?.outbox.pendingSend(clientID: id)?.failure },
                    openEmailOriginal: { [weak store] id in store?.emailOriginalRequest = EmailOriginalRequest(id: id) })
    }
}

extension EnvironmentValues {
    @Entry public var sendActions: SendActions = .none
}

/// Messages' red ! beside an undelivered bubble. Its menu offers Try Again (never automatic)
/// and Delete, under the reason (which warns when it may have been sent after all).
struct NotDeliveredBadge: View {
    let message: CommsMessage
    static let size: CGFloat = 22

    @Environment(\.sendActions) private var actions

    var body: some View {
        let clientID = PendingSend.clientID(ofMessageID: message.id)
        let failure = clientID.flatMap { actions.failure($0) }
        Menu {
            // The reason as a (disabled) row: macOS menus drop an empty section's header.
            if let reason = message.deliveryError { Button(reason) {}.disabled(true) }
            if failure?.retryWindowExpired == true {
                // The server can no longer retry it safely: check, then send it as new.
                Button("Send Again as New Message") { if let clientID { actions.resendAsNew(clientID) } }
            } else if failure?.isFinal != true {
                Button("Try Again") { if let clientID { actions.retry(clientID) } }
            }
            Button("Delete", role: .destructive) { if let clientID { actions.discard(clientID) } }
        } label: {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: Self.size))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .frame(width: Self.size, height: Self.size)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Not Delivered")
        .accessibilityHint("Shows Try Again")
        .accessibilityIdentifier("not-delivered")
    }
}
