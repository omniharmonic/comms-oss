import SwiftUI

/// A Messages bubble: a rounded rect (circular corners, `radius`, clamped to a capsule) and,
/// when `tail` is set, the curled tail from `Tokens.bubble.tail.path`, unioned into ONE path.
///
/// The tail path is in points for a radius-20 body, with its origin at the bubble's
/// bottom-outer corner, +x pointing inward and +y down (CALIBRATION.md). It is placed at the
/// bottom-left for incoming and mirrored to the bottom-right for outgoing, and scaled by
/// radius ÷ 20 so the Mac's smaller capsule gets a proportionally smaller tail. The tip
/// hangs `tail.drop × scale` below the body, outside the shape's layout rect.
///
/// `outgoing` puts the tail at the bottom-right. In a right-to-left layout SwiftUI mirrors the
/// drawing itself, so the tail follows the bubble to the other side with no extra code
/// (verified by the `rtlLayoutMirrorsBubble` snapshot).
///
/// `bottomInset` shortens the body by that much from the bottom of `rect`, for media clipped
/// by this shape whose image is drawn taller so it also fills the tail.
public struct BubbleShape: Shape {
    public var tail: Bool
    public var outgoing: Bool
    public var radius: CGFloat
    public var bottomInset: CGFloat

    public init(tail: Bool, outgoing: Bool, radius: CGFloat, bottomInset: CGFloat = 0) {
        self.tail = tail
        self.outgoing = outgoing
        self.radius = radius
        self.bottomInset = bottomInset
    }

    public func path(in rect: CGRect) -> Path {
        var body = rect
        body.size.height = max(0, rect.height - bottomInset)
        let r = max(0, min(radius, body.height / 2, body.width / 2))
        let bodyPath = Path(roundedRect: body, cornerRadius: r, style: .circular)
        guard tail, r > 0 else { return bodyPath }

        let scale = r / Tokens.bubble.radius
        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: outgoing ? body.maxX - p.x * scale : body.minX + p.x * scale, y: body.maxY + p.y * scale)
        }
        var tailPath = Path()
        for command in Tokens.bubble.tail.path {
            switch command {
            case .move(let p): tailPath.move(to: place(p))
            case .line(let p): tailPath.addLine(to: place(p))
            case .curve(let c1, let c2, let p): tailPath.addCurve(to: place(p), control1: place(c1), control2: place(c2))
            case .close: tailPath.closeSubpath()
            }
        }
        // A true union, so the overlap stays filled whatever each subpath's winding.
        return bodyPath.union(tailPath)
    }
}

