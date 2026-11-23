@testable import CommsUI
import XCTest
#if os(macOS)
import AppKit
#endif

/// The swipe's physics (polish r2: Messages' circles, parallax, rubber band, velocity) on both
/// platforms, and the Mac trackpad's decision of what a two-finger movement is.
final class RowSwipeTests: XCTestCase {
    private typealias G = SwipeGeometry
    private let g = SwipeGeometry(leading: 2, trailing: 3)

    func testRevealIsTheInsetAndOneSlotPerCircle() {
        XCTAssertEqual(g.leadingReveal, G.inset + 2 * G.slot)
        XCTAssertEqual(g.trailingReveal, G.inset + 3 * G.slot)
        XCTAssertEqual(SwipeGeometry(leading: 0, trailing: 0).leadingReveal, 0)
    }

    func testFullSwipeUnchanged() {
        // Released past reveal + 86 (at least 160), or flicked fast past the buttons.
        let full = max(G.minimumFull, g.trailingReveal + 86)
        XCTAssertEqual(g.end(reach: -full, velocity: 0), .fireTrailing)
        XCTAssertEqual(g.end(reach: -(full - 1), velocity: 0), .openTrailing)
        XCTAssertEqual(g.end(reach: -(g.trailingReveal + 1), velocity: -1000), .fireTrailing, "a fast flick past the buttons")
        XCTAssertEqual(g.end(reach: -(g.trailingReveal - 1), velocity: -1000), .openTrailing, "not past the buttons yet")
        XCTAssertEqual(g.end(reach: max(G.minimumFull, g.leadingReveal + 86), velocity: 0), .fireLeading)
        // A menu outer button never fires, however far or fast.
        let menuOnly = SwipeGeometry(leading: 0, trailing: 1, trailingFires: false)
        XCTAssertEqual(menuOnly.end(reach: -400, velocity: -3000), .openTrailing)
        XCTAssertFalse(menuOnly.isArmed(-400))
    }

    func testReleaseIsProjectedByVelocity() {
        let half = g.trailingReveal / 2
        XCTAssertEqual(g.end(reach: -(half - 10), velocity: 0), .close, "short of half, still")
        XCTAssertEqual(g.end(reach: -(half - 10), velocity: -400), .openTrailing, "a flick open coasts past half: opens")
        XCTAssertEqual(g.end(reach: -(half + 10), velocity: 0), .openTrailing)
        XCTAssertEqual(g.end(reach: -(half + 10), velocity: 500), .close, "a flick back closes")
        XCTAssertEqual(g.end(reach: 20, velocity: 600), .openLeading)
        XCTAssertEqual(g.end(reach: g.leadingReveal, velocity: -800), .close)
    }

    func testTrackingRubberBandsWhereNothingCanFire() {
        XCTAssertEqual(g.track(40), 40, "1:1 inside the buttons")
        XCTAssertEqual(g.track(-300, rowWidth: 1000), -300, "a firing side tracks 1:1 past the buttons")
        XCTAssertEqual(g.track(-2000, rowWidth: 400), -400, "…up to the row's width")
        let noLeading = SwipeGeometry(leading: 0, trailing: 2)
        XCTAssertEqual(noLeading.track(80), 0, "no leading buttons: the row does not move right")
        let menu = SwipeGeometry(leading: 0, trailing: 1, trailingFires: false)
        let r = menu.trailingReveal
        let shown = -menu.track(-(r + 200))
        XCTAssertGreaterThan(shown, r)
        XCTAssertLessThan(shown, r + 120, "rubber band: never more than its dimension")
        XCTAssertLessThan(shown - r, 200 * 0.6, "and well short of the finger")
        XCTAssertEqual(SwipeGeometry.rubber(0), 0)
        XCTAssertLessThan(SwipeGeometry.rubber(10_000), 120)
    }

    func testThresholdArmsOnceAndNeverPastTheRow() {
        let full = max(G.minimumFull, g.trailingReveal + 86)
        XCTAssertFalse(g.isArmed(-(full - 1)))
        XCTAssertTrue(g.isArmed(-full))
        XCTAssertFalse(g.isArmed(0))
        // A narrow row: the threshold comes earlier (80 % of the row), never inside the buttons.
        XCTAssertEqual(g.full(g.trailingReveal, rowWidth: 260), min(full, max(g.trailingReveal + 24, 208)))
        XCTAssertGreaterThan(g.full(g.trailingReveal, rowWidth: 100), g.trailingReveal, "never inside the buttons")
    }

    func testParallaxLayout() {
        let n = 3
        let reveal = G.reveal(n)
        // Closed: nothing shows.
        XCTAssertEqual(G.layout(index: 0, count: n, offset: 0, armed: false).opacity, 0)
        // Half open: every circle part-scaled, at half its resting place (they lag the row).
        let half = (0..<n).map { G.layout(index: $0, count: n, offset: -reveal / 2, armed: false) }
        for (i, l) in half.enumerated() {
            let rest = G.inset + G.diameter / 2 + G.slot * CGFloat(i)
            XCTAssertEqual(l.center, rest / 2, accuracy: 0.001)
            XCTAssertEqual(l.scale, min(0.775, 0.5 * (1 + 2 * G.spacing / G.diameter)), accuracy: 0.001)
            XCTAssertLessThan(l.center + G.diameter * l.scale / 2, reveal / 2 + 0.001, "never past the row's edge")
        }
        // Open: full size, at rest, in order outer → inner.
        let open = (0..<n).map { G.layout(index: $0, count: n, offset: -reveal, armed: false) }
        XCTAssertEqual(open.map(\.scale), [1, 1, 1])
        XCTAssertEqual(open.map(\.width), [G.diameter, G.diameter, G.diameter])
        XCTAssertTrue(open[0].center < open[1].center && open[1].center < open[2].center)
        // Past the buttons: the inner ones hug the row, the outer one stretches.
        let past = (0..<n).map { G.layout(index: $0, count: n, offset: -(reveal + 40), armed: false) }
        XCTAssertEqual(past[0].width, G.diameter + 40)
        XCTAssertEqual(past[2].center, open[2].center + 40)
        // Armed: the outer one covers the reveal, the others fade beneath it.
        let armed = (0..<n).map { G.layout(index: $0, count: n, offset: -(reveal + 120), armed: true) }
        XCTAssertEqual(armed[0].width, reveal + 120 - G.inset - G.spacing)
        XCTAssertEqual(armed[1].opacity, 0)
        XCTAssertEqual(armed[2].opacity, 0)
    }

    /// Round 3 (owner: the row slid back over the icons while closing): at EVERY point of a close
    /// the circles fit inside the width the row has vacated, and they vanish as it reaches home.
    func testCirclesCollapseInLockstepWithTheRow() {
        for n in 1...3 {
            let reveal = G.reveal(n)
            for step in 0...40 {
                let w = reveal * CGFloat(step) / 40
                for i in 0..<n {
                    let l = G.layout(index: i, count: n, offset: -w, armed: false)
                    guard l.opacity > 0 else { continue }
                    let half = G.diameter * l.scale / 2
                    XCTAssertLessThanOrEqual(l.center + half, w + 0.001, "n \(n), w \(w), circle \(i): never under the row")
                    XCTAssertGreaterThanOrEqual(l.center - half, -0.001, "n \(n), w \(w), circle \(i): never past the screen edge")
                }
            }
            let near = G.layout(index: 0, count: n, offset: -1, armed: false)
            XCTAssertLessThan(near.opacity, 0.05, "nearly home: faded")
            XCTAssertLessThan(near.scale, 0.1, "nearly home: shrunk")
        }
    }

    func testMacReleaseVelocityFromRecentSamples() {
        XCTAssertEqual(SwipeCoordinator.velocity([]), 0)
        XCTAssertEqual(SwipeCoordinator.velocity([(1.0, -10)]), 0, "one sample: no velocity")
        // -60 pt in 50 ms → -1200 pt/s; an older sample (> 80 ms) is ignored.
        let v = SwipeCoordinator.velocity([(0.80, 0), (0.95, -20), (0.97, -40), (1.00, -80)])
        XCTAssertEqual(v, -1200, accuracy: 0.5)
    }

    func testMacTrackerLocksDirectionEarly() {
        var t = MacSwipeTracker()
        XCTAssertEqual(t.feed(dx: 2, dy: 1, hit: .row("a")), .undecided)
        XCTAssertEqual(t.feed(dx: 6, dy: 1, hit: .row("a")), .horizontal(.row("a")))
        XCTAssertEqual(t.feed(dx: 0, dy: 40, hit: nil), .horizontal(.row("a")), "locked once decided")
        var v = MacSwipeTracker()
        XCTAssertEqual(v.feed(dx: 3, dy: 8, hit: .row("a")), .vertical, "a scroll stays a scroll")
        var nothing = MacSwipeTracker()
        XCTAssertEqual(nothing.feed(dx: 10, dy: 0, hit: nil), .ignored, "not over a row (the folder menu no longer pages)")
    }

    /// One row open at a time; the physics drive the row's state.
    @MainActor
    func testCoordinatorOpensOneRowAndClosesOnRequest() {
        let c = SwipeCoordinator()
        let a = RowSwipeState(), b = RowSwipeState()
        for s in [a, b] {
            s.trailing = [SwipeItem(title: "Archive", systemImage: "archivebox.fill", color: .purple, identifier: "x") {}]
            s.frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        }
        c.register("a", a)
        c.register("b", b)
        c.begin("a")
        c.drag("a", translation: -50)
        XCTAssertEqual(a.offset, -50)
        c.release("a", velocity: 0)
        XCTAssertEqual(a.offset, -a.geometry.trailingReveal, "opened")
        XCTAssertEqual(c.openID, "a")
        c.begin("b")
        XCTAssertEqual(a.offset, 0, "swiping another row closes the open one")
        XCTAssertEqual(c.openID, "b")
        c.drag("b", translation: -10)
        c.release("b", velocity: 0)
        XCTAssertEqual(b.offset, 0)
        XCTAssertNil(c.openID)
        c.begin("a")
        c.drag("a", translation: -60)
        c.release("a", velocity: -200)
        c.closeAll()
        XCTAssertEqual(a.offset, 0, "a scroll or a touch elsewhere closes it")
        XCTAssertNil(c.openID)
    }

    @MainActor
    func testFullSwipeFiresTheOuterActionOnce() {
        let c = SwipeCoordinator()
        let s = RowSwipeState()
        var read = 0
        s.leading = [SwipeItem(title: "Read", systemImage: "message.fill", color: .blue, identifier: "r") { read += 1 }]
        s.frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        c.register("a", s)
        c.begin("a")
        c.drag("a", translation: 300)
        XCTAssertTrue(s.armed, "past the threshold: the outer button expands")
        c.drag("a", translation: 120)
        XCTAssertFalse(s.armed, "back below it: it shrinks")
        c.drag("a", translation: 300)
        c.release("a", velocity: 0)
        XCTAssertEqual(read, 1)
        XCTAssertEqual(s.offset, 0, "a non-removing action springs back")
        XCTAssertFalse(s.armed)
    }

    #if os(macOS)
    /// Final review I1: only the sidebar's own, key, sheet-free window may swipe its rows.
    @MainActor
    func testMacSwipeOnlyFromTheSidebarsOwnKeyWindow() {
        let host = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let quickLook = NSPanel(contentRect: .init(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        XCTAssertTrue(SwipeCoordinator.accepts(eventWindow: host, host: host, hostIsKey: true, hostHasSheet: false))
        XCTAssertFalse(SwipeCoordinator.accepts(eventWindow: quickLook, host: host, hostIsKey: true, hostHasSheet: false), "Quick Look / Settings / a second window")
        XCTAssertFalse(SwipeCoordinator.accepts(eventWindow: host, host: host, hostIsKey: false, hostHasSheet: false), "the sidebar's window is behind another")
        XCTAssertFalse(SwipeCoordinator.accepts(eventWindow: host, host: host, hostIsKey: true, hostHasSheet: true), "a sheet is over it")
        XCTAssertFalse(SwipeCoordinator.accepts(eventWindow: host, host: nil, hostIsKey: true, hostHasSheet: false), "not yet in a window")
        XCTAssertFalse(SwipeCoordinator.accepts(eventWindow: nil, host: host, hostIsKey: true, hostHasSheet: false))
    }
    #endif
}
