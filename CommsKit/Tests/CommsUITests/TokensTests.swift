import CommsCore
import CommsUI
import Foundation
import PrismModels
import XCTest

final class TokensTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: Sync with design/tokens.json

    /// Regenerate Tokens.swift from tokens.json and diff it with the checked-in file.
    func testTokensSwiftIsInSyncWithTokensJSON() throws {
        #if os(macOS)
        let script = Self.repo.appendingPathComponent("scripts/gen-tokens.swift").path
        let json = Self.repo.appendingPathComponent("design/tokens.json").path
        let checkedIn = try String(contentsOf: Self.repo.appendingPathComponent("CommsKit/Sources/CommsUI/Tokens.swift"), encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["swift", script, "--stdout", json]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let generated = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(generated, checkedIn, "Tokens.swift is stale: run `swift scripts/gen-tokens.swift`")
        #else
        throw XCTSkip("Runs the generator with Process: macOS only (the source sync is platform-independent).")
        #endif
    }

    /// Key values straight from the JSON, so the sync holds even without the script.
    func testKeyValuesMatchTokensJSON() throws {
        let data = try Data(contentsOf: Self.repo.appendingPathComponent("design/tokens.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let color = try XCTUnwrap(root["color"] as? [String: Any])
        let bubble = try XCTUnwrap(root["bubble"] as? [String: Any])
        let byNet = try XCTUnwrap(color["outgoingByNetwork"] as? [String: [String: String]])

        XCTAssertEqual(Tokens.color.incomingLight.hex, color["incomingLight"] as? String)
        XCTAssertEqual(Tokens.color.incomingDark.hex, color["incomingDark"] as? String)
        XCTAssertEqual(Tokens.color.accent.hex, color["accent"] as? String)
        XCTAssertEqual(Set(Tokens.color.outgoingByNetwork.all.map(\.network)), Set(byNet.keys))
        for (net, shade) in Tokens.color.outgoingByNetwork.all {
            XCTAssertEqual(shade.top.hex, byNet[net]?["top"], net)
            XCTAssertEqual(shade.bottom.hex, byNet[net]?["bottom"], net)
            XCTAssertEqual(shade.mac.hex, byNet[net]?["mac"], net)
        }
        XCTAssertEqual(Double(Tokens.bubble.radius), bubble["radius"] as? Double)
        XCTAssertEqual(Double(Tokens.bubble.padH), bubble["padH"] as? Double)
        XCTAssertEqual(Double(Tokens.bubble.padV), bubble["padV"] as? Double)
        let tail = try XCTUnwrap(bubble["tail"] as? [String: Any])
        XCTAssertEqual((tail["path"] as? [Any])?.count, Tokens.bubble.tail.path.count)
    }

    // MARK: Colour rules

    func testNoGreenAnywhere() {
        for (name, c) in Tokens.color.all {
            let hsl = ColorMath.hsl(c)
            let green = hsl.h >= 90 && hsl.h <= 160 && hsl.s > 0.3
            XCTAssertFalse(green, "\(name) \(c.hex) is green (hue \(Int(hsl.h))°, saturation \(hsl.s))")
        }
    }

    /// Palette rules per ruling R15 / plan Global Constraints (D4 amended), mirroring
    /// design/check-palette.py. The brief's original "contrast ≥ 3:1, ΔE ≥ 10" was superseded
    /// by R15 (Apple's own iMessage blue is ≈ 2.6:1).
    func testPaletteRules() {
        let shades = Tokens.color.outgoingByNetwork.all
        let imessage = Tokens.color.outgoingByNetwork.imessage
        let kinds: [(String, KeyPath<NetworkShade, TokenColor>)] = [("top", \.top), ("bottom", \.bottom), ("mac", \.mac)]
        for (net, shade) in shades {
            for (kind, kp) in kinds {
                let c = shade[keyPath: kp]
                let label = "\(net).\(kind) \(c.hex)"
                let h = ColorMath.hsl(c).h
                XCTAssert((195...235).contains(h), "\(label): hue \(h) outside 195–235°")
                XCTAssertGreaterThanOrEqual(ColorMath.contrastOnWhiteText(c), 2.5, "\(label): white-text contrast")
                let lab = ColorMath.lab(c), ref = ColorMath.lab(imessage[keyPath: kp])
                XCTAssertLessThanOrEqual(abs(lab.l - ref.l), 12, "\(label): L* too far from iMessage")
                XCTAssertGreaterThanOrEqual(hypot(lab.a, lab.b), 40, "\(label): chroma")
                for (other, otherShade) in shades where other != net {
                    let de = ColorMath.ciede2000(c, otherShade[keyPath: kp])
                    XCTAssertGreaterThanOrEqual(de, 5, "\(label) vs \(other): ΔE00 \(de)")
                }
            }
        }
    }

    func testOutgoingShadePerNetwork() {
        let wa = MessageFactory.message(network: "whatsapp", outgoing: true, text: "hi")
        let im = MessageFactory.message(network: "imessage", outgoing: true, text: "hi")
        let unknown = MessageFactory.message(network: "carrier-pigeon", outgoing: true, text: "hi")
        let incoming = MessageFactory.message(network: "whatsapp", outgoing: false, text: "hi")
        XCTAssertEqual(BubbleFill(message: wa), .outgoing(Tokens.color.outgoingByNetwork.whatsapp))
        XCTAssertEqual(BubbleFill(message: im), .outgoing(Tokens.color.outgoingByNetwork.imessage))
        XCTAssertEqual(BubbleFill(message: unknown), .outgoing(Tokens.color.outgoingByNetwork.matrix))
        XCTAssertEqual(BubbleFill(message: incoming), .incoming)
        XCTAssertNotEqual(Tokens.color.outgoingByNetwork.whatsapp, Tokens.color.outgoingByNetwork.imessage)
    }

    /// iOS: the gradient is in window space, so two bubbles at different heights get
    /// different colours and a bubble at the very top starts at `top`.
    func testOutgoingGradientIsWindowSpace() {
        let g = OutgoingGradient(network: .imessage, solid: false)
        let window: CGFloat = 800
        XCTAssertEqual(g.color(atWindowY: 0, windowHeight: window), Tokens.color.outgoingByNetwork.imessage.top)
        XCTAssertEqual(g.color(atWindowY: window, windowHeight: window), Tokens.color.outgoingByNetwork.imessage.bottom)
        let points = g.unitPoints(bubbleFrame: CGRect(x: 0, y: 400, width: 100, height: 40), windowHeight: window)
        XCTAssertEqual(points.start.y, -10, accuracy: 1e-9) // window top is 10 bubble-heights above
        XCTAssertEqual(points.end.y, 10, accuracy: 1e-9)
        let mac = OutgoingGradient(network: .whatsapp, solid: true)
        XCTAssertEqual(mac.color(atWindowY: 123, windowHeight: window), Tokens.color.outgoingByNetwork.whatsapp.mac)
    }

    func testTailOnlyOnSingleAndLast() {
        XCTAssertTrue(RunPosition.single.hasTail)
        XCTAssertTrue(RunPosition.last.hasTail)
        XCTAssertFalse(RunPosition.first.hasTail)
        XCTAssertFalse(RunPosition.middle.hasTail)
    }

    /// The shape is one path: the tail's tip (≈ 7 pt below the body at radius 20) is inside it,
    /// mirrored per side, and absent without a tail.
    func testBubbleShapeTailGeometry() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        let tipIncoming = CGPoint(x: 9.6, y: 40 + 6.6)
        let tipOutgoing = CGPoint(x: 200 - 9.6, y: 40 + 6.6)
        XCTAssertTrue(BubbleShape(tail: true, outgoing: false, radius: 20).path(in: rect).contains(tipIncoming))
        XCTAssertFalse(BubbleShape(tail: true, outgoing: false, radius: 20).path(in: rect).contains(tipOutgoing))
        XCTAssertTrue(BubbleShape(tail: true, outgoing: true, radius: 20).path(in: rect).contains(tipOutgoing))
        XCTAssertFalse(BubbleShape(tail: false, outgoing: true, radius: 20).path(in: rect).contains(tipOutgoing))
        // Union, not even-odd: the overlap of body and tail stays filled.
        XCTAssertTrue(BubbleShape(tail: true, outgoing: false, radius: 20).path(in: rect).contains(CGPoint(x: 15, y: 38)))
    }
}

/// sRGB → HSL / CIELAB / CIEDE2000, matching design/check-palette.py.
enum ColorMath {
    static func hsl(_ c: TokenColor) -> (h: Double, s: Double, l: Double) {
        let r = c.red, g = c.green, b = c.blue
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    static func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

    static func contrastOnWhiteText(_ c: TokenColor) -> Double {
        let y = 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
        return 1.05 / (y + 0.05)
    }

    static func lab(_ c: TokenColor) -> (l: Double, a: Double, b: Double) {
        let r = lin(c.red), g = lin(c.green), b = lin(c.blue)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func ciede2000(_ c1: TokenColor, _ c2: TokenColor) -> Double {
        let (L1, a1, b1) = lab(c1), (L2, a2, b2) = lab(c2)
        let deg = Double.pi / 180
        let C1 = hypot(a1, b1), C2 = hypot(a2, b2), Cb = (C1 + C2) / 2
        let G = 0.5 * (1 - sqrt(pow(Cb, 7) / (pow(Cb, 7) + pow(25, 7))))
        let a1p = (1 + G) * a1, a2p = (1 + G) * a2
        let C1p = hypot(a1p, b1), C2p = hypot(a2p, b2)
        func hue(_ b: Double, _ a: Double) -> Double { let h = atan2(b, a) / deg; return h < 0 ? h + 360 : h }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = L2 - L1, dCp = C2p - C1p
        var dhp: Double
        if C1p * C2p == 0 { dhp = 0 }
        else {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * sqrt(C1p * C2p) * sin(dhp / 2 * deg)
        let Lbp = (L1 + L2) / 2, Cbp = (C1p + C2p) / 2
        var hbp: Double
        if C1p * C2p == 0 { hbp = h1p + h2p }
        else if abs(h1p - h2p) <= 180 { hbp = (h1p + h2p) / 2 }
        else { hbp = h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2 }
        let T = 1 - 0.17 * cos((hbp - 30) * deg) + 0.24 * cos(2 * hbp * deg) + 0.32 * cos((3 * hbp + 6) * deg) - 0.20 * cos((4 * hbp - 63) * deg)
        let dTheta = 30 * exp(-pow((hbp - 275) / 25, 2))
        let Rc = 2 * sqrt(pow(Cbp, 7) / (pow(Cbp, 7) + pow(25, 7)))
        let Sl = 1 + 0.015 * pow(Lbp - 50, 2) / sqrt(20 + pow(Lbp - 50, 2))
        let Sc = 1 + 0.045 * Cbp, Sh = 1 + 0.015 * Cbp * T
        let Rt = -sin(2 * dTheta * deg) * Rc
        return sqrt(pow(dLp / Sl, 2) + pow(dCp / Sc, 2) + pow(dHp / Sh, 2) + Rt * (dCp / Sc) * (dHp / Sh))
    }
}
