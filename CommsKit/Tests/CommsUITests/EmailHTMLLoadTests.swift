@testable import CommsUI
import WebKit
import XCTest

/// The sandboxed "View Full Email" web view really shows the mail's text, with scripts off
/// and remote loads blocked (no network is needed: a blocked load never leaves).
@MainActor
final class EmailHTMLLoadTests: XCTestCase {
    final class Probe: SandboxedHTMLView.Coordinator {
        var urls: [String] = []
        var finished: XCTestExpectation?
        override func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            urls.append("\(action.navigationType.rawValue) \(action.request.url?.absoluteString ?? "nil")")
            return await super.webView(webView, decidePolicyFor: action)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?.fulfill() }
    }

    func testTheMailTextRendersAndScriptsDoNotRun() async throws {
        let probe = Probe()
        let done = expectation(description: "loaded")
        probe.finished = done
        let view = SandboxedHTMLView(html: "<p id=x>Invoice ready</p><script>document.title='ran'</script><img src=\"https://tracker.invalid/p.gif\">") {}
        let web = view.makeWebView(probe)
        await fulfillment(of: [done], timeout: 10)
        print("[email-html] navigations: \(probe.urls)")
        let text = try await web.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertEqual(text?.trimmingCharacters(in: .whitespacesAndNewlines), "Invoice ready")
        let title = try await web.evaluateJavaScript("document.title") as? String
        XCTAssertNotEqual(title, "ran", "page scripts never run")
    }

    /// Counts every request for its scheme (a stand-in for a remote server: tests have no network).
    final class Tracker: NSObject, WKURLSchemeHandler {
        var requests: [String] = []
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            requests.append(task.request.url?.absoluteString ?? "?")
            task.didFailWithError(URLError(.cancelled))
        }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    static let hostile = """
    <img src="x-track://pixel/img"><img/src="x-track://pixel/slash"><picture><source srcset="x-track://pixel/srcset"></picture>
    <div style="background:url(x-track://pixel/css)">bg</div>
    <style>@import url(x-track://pixel/import); @font-face{font-family:f;src:url(x-track://pixel/font)} p{font-family:f}</style>
    <link rel="stylesheet" href="x-track://pixel/link"><link rel="prefetch" href="x-track://pixel/prefetch">
    <iframe src="x-track://pixel/frame"></iframe><video poster="x-track://pixel/poster"></video>
    <object data="x-track://pixel/object"></object><embed src="x-track://pixel/embed">
    <p>Hello</p>
    """

    private func load(_ html: String, sandboxed: Bool) async throws -> (Tracker, String?) {
        let tracker = Tracker()
        let config = sandboxed ? EmailHTML.configuration() : WKWebViewConfiguration()
        config.setURLSchemeHandler(tracker, forURLScheme: "x-track")
        let probe = Probe()
        let done = expectation(description: "loaded")
        probe.finished = done
        let web: WKWebView
        if sandboxed {
            web = SandboxedHTMLView(html: html) {}.makeWebView(probe, configuration: config)
        } else {
            web = WKWebView(frame: .zero, configuration: config)
            web.navigationDelegate = probe
            web.loadHTMLString(html, baseURL: nil)
        }
        await fulfillment(of: [done], timeout: 10)
        try await Task.sleep(for: .milliseconds(500)) // late subresources
        let text = try await web.evaluateJavaScript("document.body.innerText") as? String
        return (tracker, text)
    }

    /// M5: no remote load leaves the sandbox — img, srcset, CSS url(), @import, @font-face, link,
    /// prefetch, iframe, poster, object, embed. The control (same HTML, plain web view) proves the
    /// tracker does see these loads when nothing blocks them.
    func testNoRemoteRequestLeavesTheSandbox() async throws {
        let (control, _) = try await load(Self.hostile, sandboxed: false)
        XCTAssertFalse(control.requests.isEmpty, "control: an unprotected web view requests the tracker")
        let (tracker, text) = try await load(Self.hostile, sandboxed: true)
        XCTAssertEqual(tracker.requests, [], "the sandbox let these out: \(tracker.requests)")
        XCTAssertTrue(text?.contains("Hello") ?? false)
    }
}
