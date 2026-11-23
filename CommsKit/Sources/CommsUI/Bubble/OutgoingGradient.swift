import PrismModels
import SwiftUI

extension OutgoingByNetworkTokens {
    /// The outgoing shade for a network; a network the tokens do not know uses `matrix`.
    public func shade(for network: CommsNetwork) -> NetworkShade {
        switch network {
        case .imessage: imessage
        case .sms: sms
        case .whatsapp: whatsapp
        case .telegram: telegram
        case .messenger: messenger
        case .x: x
        case .discord: discord
        case .email: email
        case .signal: signal
        case .slack: slack
        // Instagram DMs ride Meta's bridge; no twelfth shade fits R15, so Messenger's (provisional).
        case .instagram: messenger
        case .linkedin: linkedin
        case .matrix, .unknown: matrix
        }
    }
}

/// What a message's bubble is filled with. Incoming is the same grey on every network;
/// outgoing is the network's own blue (`Tokens.color.outgoingByNetwork`). Bubbles are opaque.
public enum BubbleFill: Equatable, Sendable {
    case incoming
    case outgoing(NetworkShade)

    public init(message: CommsMessage) {
        self = message.sender.isSelf
            ? .outgoing(Tokens.color.outgoingByNetwork.shade(for: message.channel.network))
            : .incoming
    }
}

/// The outgoing blue for one network. On iOS it is ONE window-space vertical gradient from
/// `top` (window top) to `bottom` (window bottom): each bubble samples it at its own global
/// frame, so colour depends on screen position and shifts while scrolling (UX spec §2). On
/// macOS it is the solid `mac` shade.
public struct OutgoingGradient: Equatable, Sendable {
    public let shade: NetworkShade
    public let solid: Bool

    #if os(macOS)
    public static let platformSolid = true
    #else
    public static let platformSolid = false
    #endif

    public init(network: CommsNetwork, solid: Bool = OutgoingGradient.platformSolid) {
        self.init(shade: Tokens.color.outgoingByNetwork.shade(for: network), solid: solid)
    }

    public init(shade: NetworkShade, solid: Bool = OutgoingGradient.platformSolid) {
        self.shade = shade
        self.solid = solid
    }

    /// The colour at a window y (0 = window top).
    public func color(atWindowY y: CGFloat, windowHeight: CGFloat) -> TokenColor {
        if solid { return shade.mac }
        let t = Double(min(max(y / max(windowHeight, 1), 0), 1))
        if t == 0 { return shade.top }
        if t == 1 { return shade.bottom }
        let a = shade.top, b = shade.bottom
        return TokenColor(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t, blue: a.blue + (b.blue - a.blue) * t)
    }

    /// Start/end unit points, in a bubble's own space, that make a `LinearGradient` drawn in
    /// the bubble coincide with the window-space gradient.
    public func unitPoints(bubbleFrame f: CGRect, windowHeight: CGFloat) -> (start: UnitPoint, end: UnitPoint) {
        let h = max(f.height, 1)
        return (UnitPoint(x: 0.5, y: -f.minY / h), UnitPoint(x: 0.5, y: (windowHeight - f.minY) / h))
    }
}

/// Fills `shape` with a bubble's colour: incoming grey for the scheme, or the outgoing
/// gradient sampled at the shape's global frame (solid on macOS).
struct BubbleFillView<S: Shape>: View {
    let shape: S
    let fill: BubbleFill

    @Environment(\.colorScheme) private var scheme
    @Environment(\.outgoingGradientHeight) private var windowHeight

    var body: some View {
        switch fill {
        case .incoming:
            #if os(macOS)
            if scheme == .dark {
                // Mac Messages in dark (owner's description): a translucent fill over the
                // window background plus a hairline, not the iPhone's opaque #262629, which
                // all but vanished on the dark transcript.
                shape.fill(Color.white.opacity(0.13))
                    .overlay(shape.stroke(Color.white.opacity(0.09), lineWidth: 0.5))
            } else {
                shape.fill(BubblePalette(scheme: scheme).incomingFill)
            }
            #else
            shape.fill(BubblePalette(scheme: scheme).incomingFill)
            #endif
        case .outgoing(let shade):
            let gradient = OutgoingGradient(shade: shade)
            if gradient.solid {
                shape.fill(shade.mac.color)
            } else {
                GeometryReader { geo in
                    let points = gradient.unitPoints(bubbleFrame: geo.frame(in: .global), windowHeight: windowHeight)
                    shape.fill(LinearGradient(colors: [shade.top.color, shade.bottom.color], startPoint: points.start, endPoint: points.end))
                }
            }
        }
    }
}
