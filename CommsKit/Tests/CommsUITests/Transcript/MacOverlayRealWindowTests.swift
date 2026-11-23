#if os(macOS)
import AppKit
import CommsClient
import CommsCore
import CommsTestSupport
@testable import CommsUI
import SwiftUI
import XCTest

/// Round 3 (owner, 0.3.3): the Mac message overlay still drew over the left of the transcript in
/// the real window. This hosts the REAL `MainWindow` (demo data) in an offscreen 1100×760 window
/// with the sidebar, opens a conversation, triggers the overlay on a message, renders the window
/// and checks the overlay's pieces in WINDOW coordinates. The PNGs go to `MAC_OVERLAY_PNG_DIR`
/// (if set) for review.
@MainActor
final class MacOverlayRealWindowTests: XCTestCase {
    static var windows: [NSWindow] = []

    private func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }

    /// The window rendered (as AppKit draws it), and saved to `MAC_OVERLAY_PNG_DIR` if set.
    @discardableResult
    private func render(_ window: NSWindow, named name: String) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["MAC_OVERLAY_PNG_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    /// Mean brightness of a window-point rect (top-left origin) of a render.
    private func brightness(_ rep: NSBitmapImageRep, _ r: CGRect, window: CGSize) -> CGFloat {
        let sx = CGFloat(rep.pixelsWide) / window.width, sy = CGFloat(rep.pixelsHigh) / window.height
        var total: CGFloat = 0, n: CGFloat = 0
        for y in stride(from: Int(r.minY * sy), to: Int(r.maxY * sy), by: 6) {
            for x in stride(from: Int(r.minX * sx), to: Int(r.maxX * sx), by: 6) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += (c.redComponent + c.greenComponent + c.blueComponent) / 3
                n += 1
            }
        }
        return n > 0 ? total / n : 0
    }

    struct Case { var name: String; var size: CGSize; var dark: Bool; var outgoing: Bool; var thread = DemoBackend.aliceThreadID }

    func testOverlayInTheRealWindow() throws {
        _ = NSApplication.shared
        let cases = [
            Case(name: "mac-overlay-1100-dark-incoming", size: CGSize(width: 1100, height: 760), dark: true, outgoing: false),
            Case(name: "mac-overlay-1100-dark-outgoing-dm", size: CGSize(width: 1100, height: 760), dark: true, outgoing: true, thread: "th_demo_maya"),
            Case(name: "mac-overlay-1100-dark-group", size: CGSize(width: 1100, height: 760), dark: true, outgoing: false, thread: "th_demo_climbers"),
            Case(name: "mac-overlay-1400-light-incoming", size: CGSize(width: 1400, height: 900), dark: false, outgoing: false),
            Case(name: "mac-overlay-800-dark-incoming", size: CGSize(width: 800, height: 600), dark: true, outgoing: false),
        ]
        defer {
            // The real windows loaded the demo's avatar photos into the shared cache, and later
            // snapshot tests expect monograms: stop their SwiftUI, let in-flight loads land, empty it.
            for w in Self.windows { w.contentView = NSView() }
            pump(0.5)
            AvatarCache.shared.removeAllForTests()
        }
        for c in cases { try run(c) }
    }

    private func run(_ c: Case) throws {
        let backend = try DemoBackend.make()
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: 0), size: c.size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: c.dark ? .darkAqua : .aqua)
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: MainWindow(backend: backend, presence: FixedPresence(true)))
        window.contentView = host
        window.setContentSize(c.size)
        window.orderFrontRegardless()
        // Kept alive to the end of the run (closing a SwiftUI window mid-test crashes xctest).
        Self.windows.append(window)
        defer { window.orderOut(nil) }
        pump(1.0)
        CommsPushCenter.shared.pendingThreadID = c.thread
        pump(1.5)

        guard let table = tables(in: host).first, let controller = table.delegate as? TranscriptTableController else {
            return XCTFail("\(c.name): no transcript table")
        }
        // A text message from someone else (or the owner's own).
        // A message on screen (the overlay opens on the bubble clicked).
        let visible = controller.tableView.rows(in: controller.tableView.visibleRect)
        let onScreen = Array(controller.rows.enumerated()).filter { visible.contains($0.offset) }.map(\.element)
        guard let target = onScreen.reversed().compactMap({ r -> CommsMessage? in
            if case .message(let m, _, _, _) = r, m.sender.isSelf == c.outgoing, m.system == nil, !m.redacted, m.attachments.isEmpty { return m }
            return nil
        }).first else { return XCTFail("\(c.name): no message") }
        let before = try XCTUnwrap(render(window, named: c.name + "-before"))
        let pane = try XCTUnwrap(TranscriptTableController.windowFrame(of: controller.scrollView), c.name)

        MessageOverlayProbe.reset()
        controller.presentOverlay(messageID: target.id, mode: .menu)
        pump(1.2)
        let after = try XCTUnwrap(render(window, named: c.name))

        // The overlay's host sits exactly on the transcript pane, in WINDOW coordinates.
        let overlayHost = try XCTUnwrap(controller.overlayHost, "\(c.name): the overlay is up")
        let hostFrame = try XCTUnwrap(TranscriptTableController.windowFrame(of: overlayHost))
        let tol: CGFloat = 1
        XCTAssertEqual(hostFrame.minX, pane.minX, accuracy: tol, "\(c.name): overlay \(hostFrame) vs pane \(pane)")
        XCTAssertEqual(hostFrame.minY, pane.minY, accuracy: tol, c.name)
        XCTAssertEqual(hostFrame.width, pane.width, accuracy: tol, c.name)
        XCTAssertEqual(hostFrame.height, pane.height, accuracy: tol, c.name)

        // Its pieces, in window coordinates.
        let probe = MessageOverlayProbe.frames
        let dim = try XCTUnwrap(probe["dim"], "\(c.name): the overlay drew (\(probe))")
        // (`.global` is the window's space, even in the overlay's own host.)
        XCTAssertEqual(dim.minX, pane.minX, accuracy: tol, "\(c.name): the dim starts at the pane's edge")
        XCTAssertEqual(dim.width, pane.width, accuracy: tol, "\(c.name): …and covers its width")
        // (A conversation without tapbacks — iMessage in the demo — has no bar.)
        if let bar = probe["bar"] {
            XCTAssertGreaterThan(bar.width, bar.height * 3, "\(c.name): the tapback bar is a row, not a strip (\(bar))")
        }

        // What the owner saw, as pixels: the sidebar is untouched (no ghost, no dim over it) and
        // the pane's right part is dimmed too (not only its left).
        let sidebar = CGRect(x: 8, y: 220, width: max(0, pane.minX - 16), height: 300)
        if sidebar.width > 20 {
            XCTAssertEqual(brightness(after, sidebar, window: c.size), brightness(before, sidebar, window: c.size), accuracy: 0.02,
                           "\(c.name): the sidebar is unchanged")
        }
        let right = CGRect(x: pane.maxX - 120, y: pane.midY - 60, width: 100, height: 120)
        let changed = abs(brightness(after, right, window: c.size) - brightness(before, right, window: c.size))
        XCTAssertGreaterThan(changed, 0.005, "\(c.name): the right of the pane is dimmed/blurred as well")

        controller.hideOverlay()
    }
}
#endif
