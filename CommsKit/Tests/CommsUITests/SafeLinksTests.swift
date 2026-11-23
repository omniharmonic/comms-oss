import PrismModels
import SwiftUI
import XCTest
@testable import CommsUI

/// I3: link cards open http(s) only; links in message text are limited to http, https and
/// mailto, so a sender-controlled `file:` / custom-scheme link never launches anything.
@MainActor
final class SafeLinksTests: XCTestCase {
    private var opened: [URL] = []
    private var savedOpener: ((URL) -> Void)?

    override func setUp() async throws {
        savedOpener = SafeLinks.opener
        opened = []
        SafeLinks.opener = { [unowned self] in self.opened.append($0) }
    }

    override func tearDown() async throws {
        if let savedOpener { SafeLinks.opener = savedOpener }
    }

    func testPreviewCardOpensHTTPAndHTTPSOnly() {
        XCTAssertTrue(SafeLinks.openPreview("https://example.org/article"))
        XCTAssertTrue(SafeLinks.openPreview("http://example.org/a?b=c"))
        for bad in ["file:///etc/passwd", "mailto:a@example.org", "javascript:alert(1)", "smb://host/share",
                    "comms://auth/callback", "x-apple.systempreferences:", "https://", "not a url", ""] {
            XCTAssertFalse(SafeLinks.openPreview(bad), bad)
        }
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.org/article", "http://example.org/a?b=c"])
    }

    func testTextLinksAllowHTTPHTTPSAndMailto() {
        XCTAssertNotNil(SafeLinks.textURL("https://example.org"))
        XCTAssertNotNil(SafeLinks.textURL("HTTP://EXAMPLE.ORG"))
        XCTAssertNotNil(SafeLinks.textURL("mailto:alex@example.org"))
        for bad in ["file:///Users", "smb://host", "javascript:alert(1)", "tel:5550100", "vnc://h", "comms://x", "ftp://h/f"] {
            XCTAssertNil(SafeLinks.textURL(bad), bad)
        }
    }

    func testDisallowedSchemeRendersAsPlainText() {
        let blocks = RichTextBlocks.build([
            .link(href: "https://example.org/notes", [.text("notes")]), .text(" "),
            .link(href: "file:///etc/hosts", [.text("hosts")]), .text(" "),
            .link(href: "mailto:alex@example.org", []),
        ], metrics: .mac)
        guard case .paragraph(let s)? = blocks.first, blocks.count == 1 else { return XCTFail("one paragraph") }
        var links: [String: URL?] = [:]
        for run in s.runs { links[String(s[run.range].characters)] = run.link }
        XCTAssertEqual(links["notes"] ?? nil, URL(string: "https://example.org/notes"))
        XCTAssertEqual(links["hosts"] ?? nil, nil, "a file: link is plain text")
        XCTAssertEqual(links["mailto:alex@example.org"] ?? nil, URL(string: "mailto:alex@example.org"))
    }

    func testOpenURLActionRefusesOtherSchemes() {
        // The action the transcript installs: allowed links reach the opener, others do not.
        SafeLinks.openURLAction(URL(string: "https://example.org")!)
        SafeLinks.openURLAction(URL(string: "file:///etc/hosts")!)
        SafeLinks.openURLAction(URL(string: "mailto:a@example.org")!)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.org", "mailto:a@example.org"])
    }

    /// Bridged messages are plain text: web and email addresses in them must still open.
    func testPlainTextAddressesAreDetected() {
        let text = "see example.org/menu or https://news.example.com/a?b=1, mail alex@example.org; not file:///etc/hosts"
        let found = SafeLinks.detectedLinks(in: text).map(\.url.absoluteString)
        XCTAssertEqual(found, ["https://example.org/menu", "https://news.example.com/a?b=1", "mailto:alex@example.org"])
        XCTAssertTrue(SafeLinks.detectedLinks(in: "no links here").isEmpty)
    }

    func testPlainTextRunsCarryDetectedLinks() {
        let blocks = RichTextBlocks.build([.text("Menu: example.org/menu today")], metrics: BubbleMetrics.current)
        guard case .paragraph(let s)? = blocks.first else { return XCTFail("expected a paragraph") }
        let links = s.runs.compactMap { run in run.link.map { (String(s[run.range].characters), $0.absoluteString) } }
        XCTAssertEqual(links.map(\.0), ["example.org/menu"])
        XCTAssertEqual(links.map(\.1), ["https://example.org/menu"])
    }
}
