import CommsClient
import SwiftUI
import XCTest
@testable import CommsUI

/// The brand-mark network badges (Simple Icons paths, brand colours) and the SVG path parser.
@MainActor
final class NetworkBadgeTests: XCTestCase {
    static let networks: [CommsNetwork] = [.imessage, .sms, .whatsapp, .telegram, .messenger, .x, .discord, .email, .matrix, .signal, .slack]

    /// Every network at the three badge sizes in use (14 pt row, 16 pt iOS row, 20 pt pins).
    func testBadgePerNetworkAtEverySize() {
        let grid = VStack(alignment: .leading, spacing: 10) {
            ForEach([14.0, 16.0, 20.0, 28.0], id: \.self) { size in
                HStack(spacing: 10) {
                    ForEach(Self.networks, id: \.wire) { n in
                        NetworkBadge(network: n, size: size, ring: nil)
                    }
                }
            }
        }
        .padding(8)
        ListSnapshot.assert(grid, named: "networkBadges", width: 500)
    }

    func testEveryMarkParsesToAShapeInsideTheViewBox() {
        let paths: [(String, Path)] = [
            ("bubble", NetworkMark.Paths.messagesBubble), ("whatsapp", NetworkMark.Paths.whatsapp),
            ("telegram", NetworkMark.Paths.telegram), ("messenger", NetworkMark.Paths.messenger),
            ("x", NetworkMark.Paths.x), ("discord", NetworkMark.Paths.discord),
            ("matrix", NetworkMark.Paths.matrix), ("signal", NetworkMark.Paths.signal),
            ("instagram", NetworkMark.Paths.instagram), ("linkedin", NetworkMark.Paths.linkedin),
        ] + NetworkMark.Paths.slack.enumerated().map { ("slack\($0.offset)", $0.element.path) }
        for (name, p) in paths {
            let b = p.boundingRect
            XCTAssertFalse(p.isEmpty, name)
            XCTAssertGreaterThan(b.width, name.hasPrefix("slack") ? 9 : 12, name)
            XCTAssertGreaterThanOrEqual(b.minX, -0.01, name)
            XCTAssertLessThanOrEqual(b.maxX, 24.01, name)
            XCTAssertLessThanOrEqual(b.maxY, 24.01, name)
        }
    }

    func testParserHandlesCompactNumbersAndGluedArcFlags() {
        // ".0741.0741" is two numbers; "0 00-4.8" is rotation 0, flags 0 and 0, then x.
        let p = Path(svg: "M10 10a.5.5 0 00-1 0l2-2h.5v-.5z")
        let b = p.boundingRect
        XCTAssertEqual(b.minX, 9, accuracy: 0.01)
        XCTAssertEqual(b.maxX, 11.5, accuracy: 0.01)
        // A full circle made of two arcs.
        let circle = Path(svg: "M12 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0z").boundingRect
        XCTAssertEqual(circle.width, 24, accuracy: 0.05)
        XCTAssertEqual(circle.height, 24, accuracy: 0.05)
    }

    /// Signal and Slack at the list badge sizes, at 1x, 2x and 3x, light and dark: the marks
    /// must stay crisp and recognisable on every screen the app runs on.
    func testSignalAndSlackBadgesAtEveryScale() {
        let grid = VStack(alignment: .leading, spacing: 8) {
            ForEach([14.0, 16.0, 20.0, 28.0], id: \.self) { size in
                HStack(spacing: 8) {
                    ForEach([CommsNetwork.signal, .slack, .telegram], id: \.wire) { n in
                        NetworkBadge(network: n, size: size, ring: nil)
                    }
                }
            }
        }
        for scale in [1.0, 2.0, 3.0] {
            ListSnapshot.assert(grid, named: "networkBadgesSignalSlack@\(Int(scale))x", width: 140, scale: scale)
        }
    }

    /// The wire strings the server sends for the new bridges are recognised everywhere: brand
    /// mark (never the generic bubble), brand colour, spelling, filter entry, outgoing shade.
    func testSignalAndSlackAreRecognised() {
        for (wire, title) in [("signal", "Signal"), ("slack", "Slack")] {
            let n = CommsNetwork(wire: wire)
            if case .symbol = NetworkMark.mark(for: n) { XCTFail("\(wire) fell back to the generic symbol") }
            XCTAssertNotEqual(NetworkMark.color(for: n), NetworkMark.color(for: .unknown("somethingelse")), wire)
            XCTAssertEqual(n.title, title)
            XCTAssertEqual(n.displayName, title)
            XCTAssertTrue(FilterMenu.networks.contains(n), wire)
            XCTAssertNotEqual(Tokens.color.outgoingByNetwork.shade(for: n), Tokens.color.outgoingByNetwork.matrix, wire)
        }
        XCTAssertEqual(CommsNetwork.signal, .unknown("signal"))
        XCTAssertNotEqual(Tokens.color.outgoingByNetwork.signal, Tokens.color.outgoingByNetwork.slack)
        XCTAssertEqual(CommsNetwork(wire: "linkedin").title, "LinkedIn")
        guard case .multicolor(let layers, _) = NetworkMark.mark(for: .slack) else { return XCTFail("slack is the four-colour hash") }
        XCTAssertEqual(layers.count, 4)
    }

    /// Instagram and LinkedIn at the list badge sizes, at 1x, 2x and 3x, light and dark.
    func testInstagramAndLinkedInBadgesAtEveryScale() {
        let grid = VStack(alignment: .leading, spacing: 8) {
            ForEach([14.0, 16.0, 20.0, 28.0], id: \.self) { size in
                HStack(spacing: 8) {
                    ForEach([CommsNetwork.instagram, .linkedin, .messenger], id: \.wire) { n in
                        NetworkBadge(network: n, size: size, ring: nil)
                    }
                }
            }
        }
        for scale in [1.0, 2.0, 3.0] {
            ListSnapshot.assert(grid, named: "networkBadgesInstagramLinkedIn@\(Int(scale))x", width: 140, scale: scale)
        }
    }

    /// PrismKit's real cases for the wire strings: brand mark, colour, spelling, filter entry,
    /// composer placeholder and outgoing shade (Instagram shares Messenger's: no room under R15).
    func testInstagramAndLinkedInAreRecognised() {
        for (wire, title) in [("instagram", "Instagram"), ("linkedin", "LinkedIn")] {
            let n = CommsNetwork(wire: wire)
            XCTAssertNotEqual(n, .unknown(wire), "a real PrismKit case")
            if case .symbol = NetworkMark.mark(for: n) { XCTFail("\(wire) fell back to the generic symbol") }
            XCTAssertNotEqual(NetworkMark.color(for: n), NetworkMark.color(for: .unknown("somethingelse")), wire)
            XCTAssertEqual(n.title, title)
            XCTAssertEqual(n.displayName, title)
            XCTAssertEqual(ComposerBar.placeholder(for: n), title)
            XCTAssertTrue(FilterMenu.networks.contains(n), wire)
        }
        XCTAssertEqual(Tokens.color.outgoingByNetwork.shade(for: .instagram), Tokens.color.outgoingByNetwork.messenger)
        XCTAssertEqual(Tokens.color.outgoingByNetwork.shade(for: .linkedin), Tokens.color.outgoingByNetwork.linkedin)
        XCTAssertEqual(Tokens.brand.instagram.hex.uppercased(), "#FF0069")
    }
}
