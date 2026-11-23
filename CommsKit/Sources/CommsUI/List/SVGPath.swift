import CoreGraphics
import Foundation
import SwiftUI

/// A minimal SVG path-data parser (`d` attribute: M L H V C S Q T A Z, absolute and
/// relative, compact number syntax like `.07.07` and arc flags written as `00`), producing a
/// `CGPath` in the path's own coordinates. Used for the network brand marks (vector, no
/// raster), whose paths are transcribed from Simple Icons (CC0).
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        var scanner = Scanner(Array(d.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuad: CGPoint?
        var command: UInt8 = 0

        while true {
            scanner.skipSeparators()
            guard let c = scanner.peek() else { break }
            if Scanner.isCommand(c) {
                command = c
                scanner.advance()
            } else if command == 0 {
                break // malformed: numbers before any command
            }
            let rel = command >= 97 // lowercase
            let base = rel ? current : .zero
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }

            switch command | 0x20 { // to lowercase
            case UInt8(ascii: "m"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = pt(x, y)
                start = current
                path.move(to: current)
                // Subsequent pairs are implicit line-tos.
                command = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")
                lastControl = nil; lastQuad = nil
            case UInt8(ascii: "l"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = pt(x, y)
                path.addLine(to: current)
                lastControl = nil; lastQuad = nil
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: (rel ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
                lastControl = nil; lastQuad = nil
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: (rel ? current.y : 0) + y)
                path.addLine(to: current)
                lastControl = nil; lastQuad = nil
            case UInt8(ascii: "c"):
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(),
                      let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = pt(x1, y1), c2 = pt(x2, y2)
                current = pt(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2; lastQuad = nil
            case UInt8(ascii: "s"):
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = pt(x2, y2)
                current = pt(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2; lastQuad = nil
            case UInt8(ascii: "q"):
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c = pt(x1, y1)
                current = pt(x, y)
                path.addQuadCurve(to: current, control: c)
                lastQuad = c; lastControl = nil
            case UInt8(ascii: "t"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let c = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                current = pt(x, y)
                path.addQuadCurve(to: current, control: c)
                lastQuad = c; lastControl = nil
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rot = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = pt(x, y)
                addArc(path, from: current, to: end, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                current = end
                lastControl = nil; lastQuad = nil
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
                lastControl = nil; lastQuad = nil
            default:
                return path
            }
        }
        return path
    }

    /// SVG elliptical arc (endpoint parameterisation, SVG 1.1 F.6.5) as cubic Béziers.
    static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                       rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, dTheta > 0 { dTheta -= 2 * .pi }
        if sweep, dTheta < 0 { dTheta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segments)
        let t = 4 / 3 * tan(delta / 4)
        var theta = theta1
        func point(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosP - ry * sin(a) * sinP, y: cy + rx * cos(a) * sinP + ry * sin(a) * cosP)
        }
        func deriv(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP, y: -rx * sin(a) * sinP + ry * cos(a) * cosP)
        }
        for i in 0..<segments {
            let a1 = theta, a2 = theta + delta
            let s = point(a1), e = i == segments - 1 ? p1 : point(a2)
            let d1 = deriv(a1), d2 = deriv(a2)
            path.addCurve(to: e,
                          control1: CGPoint(x: s.x + t * d1.x, y: s.y + t * d1.y),
                          control2: CGPoint(x: e.x - t * d2.x, y: e.y - t * d2.y))
            theta = a2
        }
    }

    struct Scanner {
        let bytes: [UInt8]
        var i = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        func peek() -> UInt8? { i < bytes.count ? bytes[i] : nil }
        mutating func advance() { i += 1 }

        static func isCommand(_ c: UInt8) -> Bool {
            "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c)
        }

        mutating func skipSeparators() {
            while let c = peek(), c == 32 || c == 44 || c == 9 || c == 10 || c == 13 { i += 1 }
        }

        /// An arc flag: a single `0` or `1`, possibly glued to what follows.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard let c = peek(), c == UInt8(ascii: "0") || c == UInt8(ascii: "1") else { return nil }
            i += 1
            return c == UInt8(ascii: "1")
        }

        /// A number: sign, digits, one decimal point, exponent. `.5.5` is two numbers.
        mutating func number() -> CGFloat? {
            skipSeparators()
            let s = i
            if let c = peek(), c == 43 || c == 45 { i += 1 }
            var seenDot = false, seenDigit = false
            while let c = peek() {
                if c >= 48 && c <= 57 { seenDigit = true; i += 1 }
                else if c == 46 && !seenDot { seenDot = true; i += 1 }
                else { break }
            }
            if seenDigit, let c = peek(), c == 101 || c == 69 {
                i += 1
                if let c = peek(), c == 43 || c == 45 { i += 1 }
                while let c = peek(), c >= 48 && c <= 57 { i += 1 }
            }
            guard seenDigit, let str = String(bytes: bytes[s..<i], encoding: .ascii), let v = Double(str) else {
                i = s
                return nil
            }
            return CGFloat(v)
        }
    }
}

/// An SVG path in a square `viewBox` (Simple Icons use 24 × 24), scaled to fit the rect.
struct SVGPathShape: Shape {
    let path: Path
    var viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / viewBox
        let t = CGAffineTransform(translationX: rect.midX - viewBox * s / 2, y: rect.midY - viewBox * s / 2).scaledBy(x: s, y: s)
        return path.applying(t)
    }
}

extension Path {
    /// A path from SVG path data (`SVGPath.parse`).
    init(svg d: String) { self.init(SVGPath.parse(d)) }
}
