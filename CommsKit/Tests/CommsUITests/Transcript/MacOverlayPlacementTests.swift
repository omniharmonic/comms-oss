#if os(macOS)
import AppKit
@testable import CommsUI
import XCTest

/// Polish r2 (owner bug): on the Mac the message overlay was drawn shifted towards the sidebar —
/// a dimmed rectangle over the left of the transcript, the bubbles clipped, no bar or menu, and a
/// ghost at the bottom-left of the sidebar. Its frames are in the transcript scroll view's space
/// while SwiftUI placed the overlay elsewhere (under the floating sidebar, into the safe areas).
/// Now the overlay measures where it was put and shifts onto the pane: these check that the lifted
/// bubble lands exactly on the original, and that the bar and menu stay inside the pane, for the
/// sidebar shown / hidden, the inspector open / closed, other window sizes and scroll positions,
/// incoming / outgoing.
@MainActor
final class MacOverlayPlacementTests: XCTestCase {
    struct Layout {
        var name: String
        var window: CGSize
        /// The transcript pane (the scroll view) in the window, top-left origin.
        var pane: CGRect
        /// Where SwiftUI put the overlay (it ignores the safe areas: under the sidebar and toolbar).
        var overlayOrigin: CGPoint
    }

    static let layouts: [Layout] = [
        Layout(name: "sidebar, no inspector, 1100 wide", window: CGSize(width: 1100, height: 760),
               pane: CGRect(x: 300, y: 0, width: 800, height: 760), overlayOrigin: CGPoint(x: 0, y: 0)),
        Layout(name: "sidebar hidden", window: CGSize(width: 1100, height: 760),
               pane: CGRect(x: 0, y: 0, width: 1100, height: 760), overlayOrigin: CGPoint(x: 0, y: 0)),
        Layout(name: "sidebar + inspector", window: CGSize(width: 1100, height: 760),
               pane: CGRect(x: 300, y: 0, width: 520, height: 760), overlayOrigin: CGPoint(x: 0, y: -52)),
        Layout(name: "narrow window", window: CGSize(width: 760, height: 520),
               pane: CGRect(x: 240, y: 0, width: 520, height: 520), overlayOrigin: CGPoint(x: 240, y: 0)),
        Layout(name: "large window", window: CGSize(width: 1600, height: 1000),
               pane: CGRect(x: 320, y: 0, width: 1280, height: 1000), overlayOrigin: CGPoint(x: 12, y: 0)),
    ]

    /// A window with the pane at its place (an unflipped content view, as AppKit's).
    private func window(_ l: Layout) -> (NSWindow, NSView) {
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: l.window), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let content = NSView(frame: CGRect(origin: .zero, size: l.window))
        w.contentView = content
        let pane = NSView(frame: CGRect(x: l.pane.minX, y: l.window.height - l.pane.maxY, width: l.pane.width, height: l.pane.height))
        content.addSubview(pane)
        return (w, pane)
    }

    func testPaneFrameInWindowCoordinates() {
        for l in Self.layouts {
            let (w, pane) = window(l)
            XCTAssertEqual(TranscriptTableController.windowFrame(of: pane), l.pane, l.name)
            _ = w
        }
        let detached = NSView(frame: .init(x: 0, y: 0, width: 10, height: 10))
        XCTAssertNil(TranscriptTableController.windowFrame(of: detached), "not in a window")
    }

    func testNestedPaneInsideAContainer() {
        let l = Self.layouts[0]
        let (w, _) = window(l)
        let column = NSView(frame: CGRect(x: 300, y: 0, width: 800, height: 760))
        w.contentView!.addSubview(column)
        let inner = NSView(frame: CGRect(x: 0, y: 60, width: 800, height: 640)) // under a toolbar band, above the composer
        column.addSubview(inner)
        XCTAssertEqual(TranscriptTableController.windowFrame(of: inner), CGRect(x: 300, y: 60, width: 800, height: 640))
    }

    /// The lifted bubble lands exactly on the original bubble, wherever SwiftUI put the overlay.
    func testLiftedBubbleSitsOverTheOriginal() {
        for l in Self.layouts {
            for scroll in [CGFloat(0), 180, 420] {
                for outgoing in [false, true] {
                    // The bubble as the table lays it out, in the pane's top-left space (scrolled).
                    let x: CGFloat = outgoing ? l.pane.width - 20 - 240 : 20
                    let content = CGRect(x: x, y: 300 - scroll + 200, width: 240, height: 60)
                    let shift = MessageOverlayPlacement.shift(pane: l.pane, overlayOrigin: l.overlayOrigin)
                    // Overlay-local → window: overlay origin + its shift + the frame.
                    let drawn = content.offsetBy(dx: l.overlayOrigin.x + shift.width, dy: l.overlayOrigin.y + shift.height)
                    let original = content.offsetBy(dx: l.pane.minX, dy: l.pane.minY)
                    XCTAssertEqual(drawn, original, "\(l.name), scroll \(scroll), outgoing \(outgoing)")
                    // Never under the sidebar: inside the pane.
                    XCTAssertGreaterThanOrEqual(drawn.minX, l.pane.minX)
                }
            }
        }
        XCTAssertEqual(MessageOverlayPlacement.shift(pane: nil, overlayOrigin: CGPoint(x: 5, y: 5)), .zero, "iPhone: frames are already the overlay's")
        XCTAssertEqual(MessageOverlayPlacement.shift(pane: CGRect(x: 300, y: 0, width: 1, height: 1), overlayOrigin: nil), .zero, "not measured yet")
    }

    /// The bar and the menu are positioned and clamped within the pane (its own coordinates).
    func testBarAndMenuStayInsideThePane() {
        let bar = CGSize(width: 290, height: 44)
        let menu = CGSize(width: 220, height: 180)
        for l in Self.layouts {
            for outgoing in [false, true] {
                for y in [CGFloat(8), 300, l.pane.height - 70] {
                    let x: CGFloat = outgoing ? l.pane.width - 16 - 200 : 16
                    let content = CGRect(x: x, y: y, width: 200, height: 60)
                    let g = MessageOverlayGeometry.layout(content: content, screen: l.pane.size, safeTop: 52, safeBottom: 8, outgoing: outgoing,
                                                          bar: bar, menu: menu, lifts: true)
                    let m = MessageOverlayGeometry.margin
                    XCTAssertGreaterThanOrEqual(g.barOrigin.x, m - 0.001, l.name)
                    XCTAssertLessThanOrEqual(g.barOrigin.x + bar.width, l.pane.width - m + 0.001, l.name)
                    XCTAssertGreaterThanOrEqual(g.menuOrigin.x, m - 0.001, l.name)
                    XCTAssertLessThanOrEqual(g.menuOrigin.x + menu.width, l.pane.width - m + 0.001, l.name)
                    XCTAssertGreaterThanOrEqual(g.barOrigin.y, 52, "\(l.name): below the toolbar band")
                    XCTAssertLessThanOrEqual(g.menuOrigin.y + menu.height, l.pane.height - 8 + 0.001, "\(l.name): above the bottom")
                    // The bar sits right above the lifted bubble.
                    XCTAssertEqual(g.barOrigin.y + bar.height + MessageOverlayGeometry.gap, content.minY + g.shift, accuracy: 0.001, l.name)
                }
            }
        }
    }
}
#endif
