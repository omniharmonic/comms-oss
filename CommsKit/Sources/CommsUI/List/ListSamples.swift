import CommsClient
import CoreGraphics
import Foundation

/// Synthetic conversations for previews and snapshots (no real names, numbers or messages).
enum ListSamples {
    /// Saturday 21 November 2026, 15:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_795_273_200)

    static func thread(
        _ id: String,
        title: String,
        kind: CommsThreadKind = .dm,
        avatar: CommsAvatar?,
        networks: [CommsNetwork],
        preview: String,
        minutesAgo: Double,
        unread: Int = 0,
        pinned: Bool = false,
        muted: Bool = false
    ) -> CommsThread {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let at = iso.string(from: now.addingTimeInterval(-minutesAgo * 60))
        var json: [String: Any] = [
            "id": id, "title": title, "titleSource": "contact", "kind": kind.wire,
            "networks": networks.map(\.wire), "lastActivityAt": at,
            "lastMessage": ["text": preview, "isSelf": false, "sentAt": at],
            "unread": ["count": unread, "trusted": true], "folder": "inbox",
            "pinned": pinned, "muted": muted, "channels": [[String: Any]](),
        ]
        if let avatar, let data = try? PrismJSON.encoder().encode(avatar) {
            json["avatar"] = try? JSONSerialization.jsonObject(with: data)
        }
        // The inputs are literals: a decode failure is a programmer error in this file.
        return try! PrismJSON.decoder().decode(CommsThread.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static let pinned: [CommsThread] = [
        thread("p1", title: "Juniper", avatar: .token("sample-1"), networks: [.imessage], preview: "Did the plants arrive?", minutesAgo: 5, unread: 1, pinned: true),
        thread("p2", title: "Orin", avatar: .token("sample-2"), networks: [.whatsapp], preview: "On my way", minutesAgo: 30, pinned: true),
        thread("p3", title: "Garden Crew", kind: .group, avatar: .monogram("GC", members: [.token("sample-3"), .token("sample-4"), .monogram("TQ", members: [])]), networks: [.whatsapp], preview: "Saturday works", minutesAgo: 45, unread: 4, pinned: true),
        thread("p4", title: "Tessa", avatar: .monogram("TQ", members: []), networks: [.telegram], preview: "Thanks!", minutesAgo: 70, unread: 1, pinned: true),
        thread("p5", title: "Wren", avatar: .token("sample-5"), networks: [.sms], preview: "See you", minutesAgo: 90, unread: 1, pinned: true),
        thread("p6", title: "Studio Team", kind: .group, avatar: nil, networks: [.discord], preview: "Shipped", minutesAgo: 120, pinned: true),
        thread("p7", title: "Supper Club", kind: .group, avatar: .token("sample-6"), networks: [.messenger], preview: "Booked", minutesAgo: 200, pinned: true),
        thread("p8", title: "Trail Friends", kind: .group, avatar: .token("sample-7"), networks: [.telegram], preview: "Map attached", minutesAgo: 300, pinned: true),
        thread("p9", title: "Ash & Rook", kind: .group, avatar: .monogram("AR", members: [.token("sample-8"), .token("sample-9")]), networks: [.imessage], preview: "Ha", minutesAgo: 400, pinned: true),
    ]

    static let rows: [CommsThread] = [
        thread("r1", title: "Marlow Finch", avatar: .token("sample-4"), networks: [.imessage], preview: "Sure! Happy to meet any time", minutesAgo: 322),
        thread("r2", title: "Fenna Lark", avatar: .token("sample-2"), networks: [.whatsapp], preview: "Thanks again for taking the kids this weekend!", minutesAgo: 328),
        thread("r3", title: "Juno Reyes", avatar: .monogram("JR", members: []), networks: [.email], preview: "Here's my latest", minutesAgo: 378, unread: 1),
        thread("r4", title: "Milo Hart", avatar: .token("sample-6"), networks: [.telegram], preview: "Let me know what she says!", minutesAgo: 60 * 20, muted: true),
    ]

    /// Fill `AvatarCache` with synthetic "photos" for the sample tokens (soft two-tone gradients).
    static func seedAvatars() {
        let hues: [Double] = [0.58, 0.08, 0.33, 0.9, 0.14, 0.5, 0.75, 0.02, 0.45]
        for (i, hue) in hues.enumerated() {
            let token = "sample-\(i + 1)"
            guard AvatarCache.shared.image(for: token) == nil, let image = gradientImage(hue: hue) else { continue }
            AvatarCache.shared.insert(image, for: token)
        }
    }

    private static func gradientImage(hue: Double, size: Int = 160) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func rgb(_ h: Double, _ s: Double, _ v: Double) -> CGColor {
            let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
            let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
            let (r, g, b): (Double, Double, Double) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
            return CGColor(colorSpace: space, components: [r, g, b, 1])!
        }
        let gradient = CGGradient(colorsSpace: space, colors: [rgb(hue, 0.35, 0.98), rgb(hue, 0.65, 0.78)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: 0), options: [])
        // A lighter "head and shoulders" so it reads as a photo, not a flat fill.
        ctx.setFillColor(rgb(hue, 0.15, 1))
        ctx.fillEllipse(in: CGRect(x: Double(size) * 0.32, y: Double(size) * 0.42, width: Double(size) * 0.36, height: Double(size) * 0.36))
        ctx.fillEllipse(in: CGRect(x: Double(size) * 0.16, y: -Double(size) * 0.3, width: Double(size) * 0.68, height: Double(size) * 0.62))
        return ctx.makeImage()
    }
}

#if DEBUG
import SwiftUI

#Preview("Sidebar content") {
    SidebarContent(pinned: ListSamples.pinned, threads: ListSamples.rows, selection: "r2", now: ListSamples.now, onSelect: { _ in }, onReachEnd: {})
        .frame(width: 290)
        .onAppear { ListSamples.seedAvatars() }
}
#endif
