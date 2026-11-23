import CommsClient
import CommsCore
import Foundation

/// The demo's email conversation (PRD §5.8), shaped as the server projects one: titled by the
/// sender, the subject as the preview's first line, each email a bubble with its subject, a
/// quoted history the bubble collapses, and an HTML part behind "View Full Email". Replies
/// can be sent (the demo answers them) with the To/Cc/Subject header shown above the composer.
/// Synthetic addresses only (example.test).
public enum DemoEmail {
    public static let threadID = "th_demo_billing"
    public static let account = "owner@example.test"
    /// Reply (the default): the sender only. Reply All adds the colleague on the invoice email.
    public static let reply = CommsEmailDetail.Reply(to: ["billing@northwind.example.test"], cc: [], subject: "Re: Your November invoice")
    public static let replyAll = CommsEmailDetail.Reply(to: ["billing@northwind.example.test"], cc: ["finance@northwind.example.test"], subject: "Re: Your November invoice")

    /// The two inbound emails of the thread, oldest first, ending `endAt`.
    public static func messages(endAt: Date) -> [CommsMessage] {
        let quote: [CommsSpan] = [.text("On Tue, Nov 18, 2026, Owner <owner@example.test> wrote:"), .br, .text("> Could you resend the October receipt?")]
        var first = FixtureMessages.message(id: "\(threadID)_e0", threadID: threadID, network: "email", sender: "Northwind Billing",
                                            senderID: "mailto:billing@northwind.example.test", at: endAt.addingTimeInterval(-3_600),
                                            text: "Hello,\nYour October receipt is attached as requested.\nThanks,\nNorthwind Billing")
        first.email = CommsMessage.Email(subject: "Re: October receipt", from: "Northwind Billing <billing@northwind.example.test>",
                                         to: [account], cc: [], quotedCollapsed: true)
        first.body = CommsRichText(spans: [.text("Hello,"), .br, .text("Your October receipt is attached as requested."), .br, .text("Thanks,"), .br, .text("Northwind Billing"), .quote(quote)],
                                   plain: "Hello,\nYour October receipt is attached as requested.\nThanks,\nNorthwind Billing")
        first.attachments = FixtureMessages.message(id: "x", at: endAt, attachments: [["kind": "file", "name": "receipt-october.pdf"]]).attachments
        var second = FixtureMessages.message(id: "\(threadID)_e1", threadID: threadID, network: "email", sender: "Northwind Billing",
                                             senderID: "mailto:billing@northwind.example.test", at: endAt,
                                             text: "Your November invoice is ready. The total is $48.00, due December 1.")
        second.email = CommsMessage.Email(subject: "Your November invoice", from: "Northwind Billing <billing@northwind.example.test>",
                                          to: [account, "finance@northwind.example.test"], cc: [], quotedCollapsed: false, hasHtml: true)
        return [first, second]
    }

    /// Replace the plain demo email thread with the projected shape.
    public static func install(on backend: FixtureBackend) {
        guard var t = backend.currentThread(id: threadID) else { return }
        let msgs = messages(endAt: t.lastActivityAt)
        t.title = "Northwind Billing"
        t.titleSource = .email
        t.lastMessage = FixtureMessages.preview(text: msgs[1].body?.plain ?? "", senderName: "Northwind Billing", isSelf: false, at: msgs[1].sentAt)
        t.lastMessage?.subject = msgs[1].email?.subject
        t.channels[0].accountLabel = account
        t.channels[0].capabilities = CommsChannelCapabilities(reply: false, attachments: false, send: true)
        backend.replaceThread(t)
        backend.setMessagePages([nil: FixtureMessages.page(msgs, before: nil, hasMore: false)], threadID: threadID)
        backend.setThreadDetail(CommsThreadDetail(thread: t, capabilities: t.channels[0].capabilities, members: [],
                                                  email: CommsEmailDetail(account: account, reply: reply, replyAll: replyAll)))
        backend.setEmailOriginal(CommsEmailOriginal(
            subject: "Your November invoice", from: "Northwind Billing <billing@northwind.example.test>", to: account, cc: "",
            date: "2026-11-21T09:30:00.000Z", text: msgs[1].body?.plain ?? "",
            html: "<h2>Invoice #1124</h2><p>Your November invoice is ready.</p><table><tr><td>Total</td><td><b>$48.00</b></td></tr></table><img src=\"https://tracker.example.test/p.gif\">"),
            messageID: msgs[1].id)
    }
}
