import CommsCore
import PrismModels
import SwiftUI

/// Above the composer on an email thread (PRD §5.8): To, Cc, Subject and From in Mail's compact
/// header style. It shows EVERY recipient Send will send to — addresses wrap, never truncate; a Cc
/// list longer than `collapsedCc` shows "& N more", which expands in place. The leading menu picks
/// Reply (Mail's default: the sender only) or Reply All, when the email has others on To/Cc. The
/// header shown is exactly the set the server binds into the approval's digest (a changed set is
/// refused: `target_changed`).
public struct EmailComposerHeader: View {
    let reply: CommsEmailDetail.Reply
    let account: String?
    let replyAll: Bool
    let canReplyAll: Bool
    let choose: @MainActor (Bool) -> Void
    @State private var ccExpanded: Bool

    public init(reply: CommsEmailDetail.Reply, account: String?, replyAll: Bool = false, canReplyAll: Bool = false,
                ccExpanded: Bool = false, choose: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.reply = reply
        self.account = account
        self.replyAll = replyAll
        self.canReplyAll = canReplyAll
        self.choose = choose
        _ccExpanded = State(initialValue: ccExpanded)
    }

    /// Cc addresses shown before "& N more".
    static let collapsedCc = 3

    #if os(macOS)
    static let fontSize: CGFloat = 12
    #else
    static let fontSize: CGFloat = 15
    #endif

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if canReplyAll {
                modeMenu
                Divider()
            }
            row("To:", Text(reply.to.joined(separator: ", ")), id: "email-header-to", value: reply.to.joined(separator: ", "))
            if !reply.cc.isEmpty {
                Divider()
                ccRow
            }
            Divider()
            row("Subject:", Text(reply.subject), id: "email-header-subject", value: reply.subject)
            if let account, !account.isEmpty {
                Divider()
                row("From:", Text(account), id: "email-header-from", value: account)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("email-header")
    }

    private var modeMenu: some View {
        Menu {
            Picker("Reply", selection: Binding(get: { replyAll }, set: { choose($0) })) {
                Label("Reply", systemImage: "arrowshape.turn.up.left").tag(false)
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: replyAll ? "arrowshape.turn.up.left.2" : "arrowshape.turn.up.left")
                Text(replyAll ? "Reply All" : "Reply")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: Self.fontSize - 3, weight: .semibold))
            }
            .font(.system(size: Self.fontSize, weight: .medium))
            .foregroundStyle(Tokens.color.accent.color)
            .padding(.vertical, 5)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(replyAll ? "Reply All" : "Reply")
        .accessibilityHint("Choose Reply or Reply All")
        .accessibilityIdentifier("email-mode")
    }

    private var ccRow: some View {
        let all = reply.cc
        let hidden = ccExpanded ? 0 : max(0, all.count - Self.collapsedCc)
        let shown = hidden > 0 ? Array(all.prefix(Self.collapsedCc)) : all
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Cc:").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(shown.joined(separator: ", ")).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if hidden > 0 {
                    Button("& \(hidden) more") { withAnimation(.snappy) { ccExpanded = true } }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.color.accent.color)
                        .accessibilityLabel("Show \(hidden) more Cc recipients")
                        .accessibilityIdentifier("email-header-cc-more")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: Self.fontSize))
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        // VoiceOver always hears every recipient.
        .accessibilityLabel("Cc: \(all.joined(separator: ", "))")
        .accessibilityIdentifier("email-header-cc")
    }

    private func row(_ label: String, _ value: Text, id: String, value plain: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            // Recipients wrap: what Send sends is never cut off.
            value.foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: Self.fontSize))
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(plain)")
        .accessibilityIdentifier(id)
    }
}
