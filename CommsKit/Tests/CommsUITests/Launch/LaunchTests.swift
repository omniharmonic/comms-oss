#if os(macOS)
import AppKit
import CommsClient
import CommsCore
import CommsTestSupport
@testable import CommsUI
import PrismAuth
import SwiftUI
import XCTest

/// The launch paths, hosted in a real window: demo → the main window over the demo backend,
/// no saved sign-in → the sign-in form. Regression: the main window once launched blank
/// because its content was created in `onAppear` of an empty `Group` (which never fires).
@MainActor
final class LaunchTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    // MARK: Launch mode

    func testDemoArgumentSelectsTheDemo() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LaunchTests-\(UUID())"))
        // `-CommsDemo YES` arrives in the argument domain as the string "YES".
        defaults.setVolatileDomain(["CommsDemo": "YES"], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(LaunchMode.resolve(defaults: defaults, environment: [:], demoAllowed: true), .demo)
        XCTAssertEqual(LaunchMode.resolve(defaults: defaults, environment: [:], demoAllowed: false), .signIn, "Release never demos")
        defaults.setVolatileDomain(["CommsDemo": "NO"], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(LaunchMode.resolve(defaults: defaults, environment: [:], demoAllowed: true), .signIn)
    }

    func testDemoEnvironmentSelectsTheDemo() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LaunchTests-\(UUID())"))
        XCTAssertEqual(LaunchMode.resolve(defaults: defaults, environment: ["COMMS_DEMO": "1"], demoAllowed: true), .demo)
        XCTAssertEqual(LaunchMode.resolve(defaults: defaults, environment: ["COMMS_DEMO": "0"], demoAllowed: true), .signIn)
        XCTAssertEqual(LaunchMode.resolve(defaults: defaults, environment: [:], demoAllowed: true), .signIn)
    }

    // MARK: Hosted windows

    /// The main window over the demo backend renders the list and opens the live stream as
    /// soon as it is on screen — no interaction, no `onAppear` on an empty view.
    func testMainWindowShowsTheSidebarOnLaunch() async throws {
        let backend = try DemoBackend.make()
        let host = show(MainWindow(backend: backend))
        let split = try await waitFor("the split view") { self.views(in: host).contains { $0 is NSSplitView } }
        XCTAssertTrue(split, "the sidebar + detail split view")
        XCTAssertTrue(views(in: host).contains { String(describing: type(of: $0)).contains("ScrollView") }, "the sidebar's list")
        let live = try await waitFor("the live event stream") { !backend.requestedEventIDs.isEmpty }
        XCTAssertTrue(live, "the window's task ran: the list store exists and the stream started")
    }

    /// No saved sign-in: the sign-in form (server field + Sign In), not an empty window.
    func testSignedOutLaunchShowsSignIn() async throws {
        UserDefaults.standard.removeObject(forKey: "comms.serverOrigin")
        var made = 0
        let root = RootView(makeSession: { origin in
            made += 1
            return Session(origin: origin, store: InMemoryTokenStore(), backendFactory: { _ in try! DemoBackend.make() }, deviceLabel: "test")
        })
        let host = show(root)
        let field = try await waitFor("the server field") { self.views(in: host).contains { $0 is NSTextField && ($0 as? NSTextField)?.isEditable == true } }
        XCTAssertTrue(field, "the sign-in form's server field")
        XCTAssertEqual(made, 0, "nothing restored without a saved server")
    }

    // MARK: Helpers

    private func show(_ view: some View) -> NSView {
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderFront(nil)
        window = w
        return host
    }

    private func waitFor(_ what: String, timeout: Duration = .seconds(5), _ check: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            window?.contentView?.layoutSubtreeIfNeeded()
            if check() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("\(what) never appeared")
        return false
    }

    /// Every view under `root` (SwiftUI's accessibility tree is not built without an
    /// assistive client, so the hosted tests look at the AppKit views it renders into).
    private func views(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views(in: $0) }
    }
}
#endif
