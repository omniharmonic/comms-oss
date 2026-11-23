import CommsCore
import PrismModels
import SwiftUI
import WebKit

/// "View Full Email" (PRD §5.8): the whole message in a sheet — its header (From, To, Cc,
/// Date) and the HTML part when the server holds one, else the full plain text.
///
/// The HTML is untrusted mail. It is rendered in a sandboxed WKWebView: JavaScript off, a
/// non-persistent data store, a content blocker that refuses EVERY network load (no tracking
/// pixels, no remote images or styles), a `default-src 'none'` CSP on top, and no navigation —
/// a tapped https/mailto link goes through `SafeLinks` (the system browser / Mail), anything
/// else is ignored. If the blocker cannot be installed, the HTML is not shown (plain text is).
public struct EmailOriginalView: View {
    let load: @MainActor () async throws -> CommsEmailOriginal
    @State private var original: CommsEmailOriginal?
    @State private var failed = false
    @State private var htmlUsable = true
    @Environment(\.dismiss) private var dismiss

    public init(original: CommsEmailOriginal? = nil, load: @escaping @MainActor () async throws -> CommsEmailOriginal) {
        _original = State(initialValue: original)
        self.load = load
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let o = original {
                    content(o)
                } else if failed {
                    ContentUnavailableView("Couldn’t Load Email", systemImage: "envelope.badge", description: Text("Try again later."))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(original?.subject ?? "Email")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("email-original-done")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
        .task {
            guard original == nil else { return }
            do { original = try await load() } catch { failed = true }
        }
        .accessibilityIdentifier("email-original")
    }

    @ViewBuilder
    private func content(_ o: CommsEmailOriginal) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                headerLine("From", o.from)
                headerLine("To", o.to)
                if !o.cc.isEmpty { headerLine("Cc", o.cc) }
                Text(o.subject).font(.headline).padding(.top, 4)
            }
            .padding()
            Divider()
            if let html = o.html, htmlUsable {
                SandboxedHTMLView(html: html) { htmlUsable = false }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("email-original-html")
            } else {
                ScrollView {
                    Text(o.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .accessibilityIdentifier("email-original-text")
            }
        }
    }

    private func headerLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            Text(value).textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

/// The locked-down web view (see `EmailOriginalView`). Pure configuration is in `EmailHTML`.
struct SandboxedHTMLView {
    let html: String
    let unavailable: @MainActor () -> Void

    @MainActor class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = false
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The one load allowed is our own loadHTMLString (about:blank). Everything else —
            // link taps, redirects, meta refresh, form posts — is cancelled; links go out via SafeLinks.
            if !loaded, action.navigationType == .other, action.request.url?.absoluteString == EmailHTML.baseURL.absoluteString {
                loaded = true
                return .allow
            }
            if action.navigationType == .linkActivated, let url = action.request.url, let safe = SafeLinks.textURL(url.absoluteString) {
                SafeLinks.opener(safe)
            }
            return .cancel
        }
    }

    @MainActor func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor func makeWebView(_ coordinator: Coordinator, configuration: WKWebViewConfiguration = EmailHTML.configuration()) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #endif
        let html = html
        let unavailable = unavailable
        Task { @MainActor in
            guard let rules = await EmailHTML.blockAllRemote() else { unavailable(); return }
            view.configuration.userContentController.add(rules)
            view.loadHTMLString(EmailHTML.document(html), baseURL: EmailHTML.baseURL)
        }
        return view
    }
}

#if os(macOS)
extension SandboxedHTMLView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension SandboxedHTMLView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

/// The web view's configuration, the content blocker and the wrapped document (pure; tested).
enum EmailHTML {
    static let baseURL = URL(string: "about:blank")!
    /// Every load by URL scheme a mail could name (http, https, ws, file, ftp, x-…://, blob:, cid:):
    /// blocked. `data:` images (inline parts) stay. (Content-blocker regexes have no `|`.)
    static let ruleList = #"""
    [{"trigger":{"url-filter":"^[a-z][-a-z0-9+.]*://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^blob:"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^cid:"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^javascript:"},"action":{"type":"block"}}]
    """#
    /// The CSP the document carries: nothing remote, no script, no forms, no frames.
    static let csp = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; frame-src 'none'; base-uri 'none'"

    @MainActor static func configuration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .nonPersistent()
        c.defaultWebpagePreferences.allowsContentJavaScript = false
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(iOS)
        c.dataDetectorTypes = []
        c.allowsInlineMediaPlayback = false
        #endif
        c.mediaTypesRequiringUserActionForPlayback = .all
        return c
    }

    @MainActor static func blockAllRemote() async -> WKContentRuleList? {
        await withCheckedContinuation { cont in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "comms-email-block-remote", encodedContentRuleList: ruleList) { list, _ in
                cont.resume(returning: list)
            }
        }
    }

    /// The mail's HTML inside a document that pins the CSP first and fits the sheet's width.
    static func document(_ html: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="\(csp)">\
        <meta http-equiv="x-dns-prefetch-control" content="off">\
        <meta name="viewport" content="width=device-width, initial-scale=1">\
        <style>:root{color-scheme:light dark}body{font:-apple-system-body;margin:12px;word-wrap:break-word}img{max-width:100%;height:auto}</style>\
        </head><body>\(html)</body></html>
        """
    }
}
