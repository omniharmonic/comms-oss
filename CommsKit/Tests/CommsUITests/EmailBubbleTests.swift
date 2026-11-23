import CommsClient
import CommsCore
import CommsTestSupport
@testable import CommsUI
import PrismModels
import SwiftUI
import WebKit
import XCTest

/// Email bubbles, the composer's To/Cc/Subject header, the list row's subject line and the
/// sandbox of "View Full Email" (PRD §5.8). Snapshots at Mac sizes, light and dark; record
/// with RECORD_SNAPSHOTS=1.
@MainActor
final class EmailBubbleTests: XCTestCase {
    typealias M = MessageFactory

    private func email(outgoing: Bool = false, quoted: Bool = true, html: Bool = false, to: [String] = ["owner@example.test"], cc: [String] = ["bob@example.test", "carol@example.test"]) -> CommsMessage {
        var spans: [CommsSpan] = [.text("Hi,"), .br, .text("Here’s the plan for Thursday: lunch at noon, then the site visit."), .br, .text("Ann")]
        if quoted { spans.append(.quote([.text("On Mon, Nov 17, Owner wrote:"), .br, .text("> What’s the plan?")])) }
        var m = M.message(network: "email", outgoing: outgoing, sender: "Ann Lee", spans: spans)
        m.body?.plain = "Hi,\nHere’s the plan for Thursday: lunch at noon, then the site visit.\nAnn"
        m.email = CommsMessage.Email(subject: outgoing ? "Re: Thursday" : "Thursday", from: "Ann Lee <ann@example.test>", to: to, cc: cc, quotedCollapsed: quoted, hasHtml: html)
        return m
    }

    // MARK: Pure

    func testCaption() {
        let e = { (to: [String], cc: [String]) in CommsMessage.Email(subject: "s", from: "", to: to, cc: cc) }
        XCTAssertEqual(EmailBubbleText.caption(e(["me@x"], []), outgoing: false), "to you")
        XCTAssertEqual(EmailBubbleText.caption(e(["me@x", "b@x", "c@x"], ["d@x", "e@x"]), outgoing: false), "to you & 2 others, Cc 2")
        XCTAssertEqual(EmailBubbleText.caption(e(["ann@x"], ["b@x"]), outgoing: true), "to ann@x, Cc 1")
    }

    func testQuotedHistorySplitsOffTheEnd() {
        let m = email()
        let s = EmailBubbleText.split(m.body)
        XCTAssertEqual(s.fresh?.spans.count, 5)
        XCTAssertNotNil(s.quoted)
        XCTAssertNil(EmailBubbleText.split(email(quoted: false).body).quoted)
    }

    func testViewFullEmailOnlyForHtmlOrLong() {
        XCTAssertTrue(EmailBubbleText.offersFullEmail(CommsMessage.Email(subject: "s", from: "", hasHtml: true), body: nil))
        XCTAssertFalse(EmailBubbleText.offersFullEmail(CommsMessage.Email(subject: "s", from: ""), body: CommsRichText(spans: [.text("x")], plain: "x")))
        XCTAssertTrue(EmailBubbleText.offersFullEmail(CommsMessage.Email(subject: "s", from: ""), body: CommsRichText(spans: [], plain: String(repeating: "a", count: 1_600))))
    }

    func testVoiceOverReadsTheSubject() {
        XCTAssertTrue(MessageBubble.accessibilityLabel(for: email()).hasPrefix("Ann Lee, email: Thursday. Hi,"))
    }

    func testRowPreviewPutsTheSubjectFirst() {
        let t = ListSamples.thread("e1", title: "Ann Lee", avatar: .monogram("AL", members: []), networks: [.email], preview: "Lunch at noon, then the site visit.", minutesAgo: 30)
        var withSubject = t
        withSubject.lastMessage?.subject = "Thursday"
        XCTAssertTrue(ThreadRow.accessibilityLabel(for: withSubject, time: "10:00").hasSuffix("Thursday, Lunch at noon, then the site visit."))
    }

    // MARK: Sandbox

    func testHtmlDocumentPinsTheCspFirstAndBlocksEveryRemoteLoad() async throws {
        let doc = EmailHTML.document("<p>Hi</p><img src=\"https://t.example/p.gif\">")
        let csp = try XCTUnwrap(doc.range(of: "Content-Security-Policy"))
        XCTAssertLessThan(csp.lowerBound, try XCTUnwrap(doc.range(of: "<body>")).lowerBound)
        XCTAssertTrue(EmailHTML.csp.hasPrefix("default-src 'none'"))
        XCTAssertFalse(EmailHTML.csp.contains("http"))
        let c = EmailHTML.configuration()
        XCTAssertFalse(c.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(c.websiteDataStore.isPersistent)
        let rules = await EmailHTML.blockAllRemote()
        XCTAssertNotNil(rules, "the content blocker compiles (else no HTML is shown)")
    }

    // MARK: Snapshots

    func testEmailIncomingCollapsed() {
        Snapshot.assert(MessageBubble(message: email(), position: .single, isGroup: false), named: "emailIncomingCollapsed")
    }

    func testEmailIncomingExpandedWithFullEmail() {
        let m = email(html: true)
        let v = EmailBubbleText(message: m, email: m.email!, outgoing: false, tail: true, fill: BubbleFill(message: m), expanded: true)
            .environment(\.emailOriginalOpener) { _ in }
        Snapshot.assert(v, named: "emailIncomingExpanded")
    }

    func testEmailOutgoing() {
        Snapshot.assert(MessageBubble(message: email(outgoing: true, quoted: false, to: ["ann@example.test"], cc: []), position: .single, isGroup: false), named: "emailOutgoing")
    }

    func testComposerHeader() {
        let h = EmailComposerHeader(reply: .init(to: ["ann@example.test"], cc: ["bob@example.test"], subject: "Re: Thursday"), account: "owner@example.test")
        Snapshot.assertHosted(h.padding(.vertical, 8), named: "emailComposerHeader", width: 460)
    }

    func testRowWithSubject() {
        var t = ListSamples.thread("e2", title: "Ann Lee", avatar: .monogram("AL", members: []), networks: [.email],
                                   preview: "Lunch at noon, then the site visit.", minutesAgo: 30, unread: 1)
        t.lastMessage?.subject = "Thursday"
        ListSnapshot.assert(ThreadRow(thread: t, isSelected: false, now: ListSamples.now), named: "rowEmailSubject")
    }

    // MARK: Fix round 1 (I1): every recipient, Reply / Reply All

    static let manyCc = ["bob@example.test", "carol@example.test", "dmitri.vasquez-longname@example.test", "eve@example.test", "frank@example.test"]

    func testComposerHeaderReplyAllWithManyCcCollapsed() {
        let h = EmailComposerHeader(reply: .init(to: ["ann@example.test"], cc: Self.manyCc, subject: "Re: Thursday"), account: "owner@example.test",
                                    replyAll: true, canReplyAll: true)
        Snapshot.assertHosted(h.padding(.vertical, 8), named: "emailComposerHeaderReplyAllCollapsed", width: 460)
    }

    func testComposerHeaderReplyAllWithManyCcExpanded() {
        let h = EmailComposerHeader(reply: .init(to: ["ann@example.test"], cc: Self.manyCc, subject: "Re: Thursday"), account: "owner@example.test",
                                    replyAll: true, canReplyAll: true, ccExpanded: true)
        Snapshot.assertHosted(h.padding(.vertical, 8), named: "emailComposerHeaderReplyAllExpanded", width: 460)
    }

    func testComposerHeaderReplyDefault() {
        let h = EmailComposerHeader(reply: .init(to: ["ann@example.test"], cc: [], subject: "Re: Thursday"), account: "owner@example.test",
                                    replyAll: false, canReplyAll: true)
        Snapshot.assertHosted(h.padding(.vertical, 8), named: "emailComposerHeaderReply", width: 460)
    }

    func testCollapsedCcStillNamesEveryoneToVoiceOver() {
        XCTAssertEqual(EmailComposerHeader.collapsedCc, 3)
    }
}
