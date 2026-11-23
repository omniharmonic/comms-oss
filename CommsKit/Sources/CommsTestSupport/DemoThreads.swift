import CommsClient
import CoreGraphics
import Foundation
import ImageIO

/// The demo list beyond the three staging rooms: realistic, synthetic conversations (made-up
/// names, 555 numbers, example.test addresses) across every network the list badges, with a
/// pinned photo-avatar thread, a group with a member-cluster avatar (D16), unread counts,
/// urgency and threads filed in every folder. Each thread has a short transcript, and its
/// `lastMessage` is what the server's `previewText` would say for the newest event.
public enum DemoThreads {
    struct Spec {
        var id: String
        var title: String
        var titleSource = "contact"
        var kind = "dm"
        var network: String
        var avatar: [String: Any]
        var folder = "inbox"
        var unread = 0
        var pinned = false
        var muted = false
        var urgency: String?
        /// Prism's triage status (wire value).
        var status: String?
        /// The vault person of a DM (`DemoPeople`).
        var personId: String?
        /// Oldest first; the newest message drives the preview.
        var messages: [CommsMessage]
        /// The latest event is a reaction: (reactor's first name, key) on the newest message.
        var reaction: (name: String, key: String)?
    }

    /// Avatar tokens the demo backend answers with generated "photos".
    static let photoHues: [String: Double] = [
        "demo-avatar-maya": 0.07, "demo-avatar-ivy": 0.55, "demo-avatar-lena": 0.9,
        "demo-avatar-priya": 0.33, "demo-avatar-noor": 0.12, "demo-avatar-eli": 0.62,
        "demo-photo-crag": 0.42,
    ]

    /// The demo threads, newest first, each with its newest page, the latest `before` `anchor`.
    static func make(before anchor: Date) -> [(thread: CommsThread, messages: [CommsMessage])] {
        /// Message `i` of `n`, four minutes apart, the last `endAgo` minutes before the anchor.
        func at(_ endAgo: Double, _ i: Int, of n: Int) -> Date {
            anchor.addingTimeInterval(-(endAgo + Double(n - 1 - i) * 4) * 60)
        }
        func convo(_ id: String, network: String, endAgo: Double, _ lines: [(who: String?, text: String?, extra: [String: Any]?)]) -> [CommsMessage] {
            lines.enumerated().map { i, l in
                var attachments: [[String: Any]] = []
                if let extra = l.extra { attachments = [extra] }
                return FixtureMessages.message(
                    id: "\(id)_m\(i)", threadID: id, network: network,
                    sender: l.who ?? "Me", outgoing: l.who == nil,
                    avatarToken: l.who.map { "demo-avatar-" + DemoPreview.firstName($0).lowercased() }.flatMap { Self.photoHues[$0] != nil ? $0 : nil },
                    at: at(endAgo, i, of: lines.count), text: l.text, attachments: attachments)
            }
        }
        /// The newest outgoing message reported delivered (the rest sent).
        func delivered(_ messages: [CommsMessage]) -> [CommsMessage] {
            messages.enumerated().map { i, m in
                var m = m
                m.delivery = i == messages.count - 1 ? .delivered : .sent
                return m
            }
        }
        let photo: [String: Any] = FixtureMessages.image(token: "demo-photo-crag", w: 1200, h: 900)
        // An iPhone photo as iMessage carries it: HEIC bytes, declared image/heic (owner report).
        var heic: [String: Any] = FixtureMessages.image(token: Self.heicToken, w: 640, h: 480)
        heic["mime"] = "image/heic"
        heic["name"] = "IMG_0420.HEIC"
        let voice: [String: Any] = ["kind": "voice", "mime": "audio/ogg", "durationMs": 42_000, "mediaToken": "demo-voice"]
        let pdf: [String: Any] = ["kind": "file", "mime": "application/pdf", "name": "lease-renewal.pdf", "size": 182_000, "mediaToken": "demo-file"]

        let specs: [Spec] = [
            Spec(id: "th_demo_maya", title: "Maya Okafor", network: "imessage", avatar: ["token": "demo-avatar-maya"],
                 unread: 2, pinned: true,
                 messages: convo("th_demo_maya", network: "imessage", endAgo: 6, [
                    ("Maya Okafor", nil, heic),
                    (nil, "Booked the table for 7:30 🍝", nil),
                    ("Maya Okafor", "Perfect, I'll bring the wine", nil),
                    ("Maya Okafor", "Are we still on for dinner Friday?", nil),
                 ])),
            Spec(id: "th_demo_climbers", title: "Weekend Climbers", kind: "group", network: "whatsapp",
                 avatar: ["monogram": "", "members": [["token": "demo-avatar-priya"], ["token": "demo-avatar-noor"], ["token": "demo-avatar-eli"]]],
                 unread: 4, pinned: true,
                 messages: convo("th_demo_climbers", network: "whatsapp", endAgo: 18, [
                    ("Noor Haddad", "Who's driving Saturday?", nil),
                    (nil, "I can take three", nil),
                    ("Eli Brandt", "Count me in 🙋", nil),
                    ("Priya Natarajan", nil, photo),
                 ])),
            Spec(id: "th_demo_ivy", title: "Ivy Chen", network: "matrix", avatar: ["token": "demo-avatar-ivy"], pinned: true,
                 messages: convo("th_demo_ivy", network: "matrix", endAgo: 41, [
                    ("Ivy Chen", "Can you send me the slides from Tuesday?", nil),
                    (nil, "Yes! Give me ten minutes", nil),
                 ])),
            // Mirrors the iOS Simulator's own Messages sample thread (design/fidelity/apple-ios/
            // transcript-light.png): five outgoing iMessages, the last one Delivered, so the
            // transcript, header, receipt and composer can be compared like for like.
            Spec(id: "th_demo_jamie", title: "Jamie Abbott", network: "imessage", avatar: ["monogram": "JA"],
                 messages: delivered(convo("th_demo_jamie", network: "imessage", endAgo: 48, [
                    (nil, "Hey! Are we still on for dinner tonight?", nil),
                    (nil, "Running about 10 minutes late", nil),
                    (nil, "See you soon 👋", nil),
                    (nil, "ok", nil),
                    (nil, "Typing a longer reply so the composer grows onto two lines", nil),
                 ]))),
            Spec(id: "th_demo_theo", title: "Theo Marsh", network: "whatsapp", avatar: ["monogram": "TM"], unread: 1, urgency: "urgent",
                 messages: convo("th_demo_theo", network: "whatsapp", endAgo: 55, [
                    ("Theo Marsh", "Call me when you can, it's about the flat", nil),
                    ("Theo Marsh", nil, voice),
                 ])),
            Spec(id: "th_demo_jonah", title: "Jonah Reyes", network: "telegram", avatar: ["monogram": "JR"],
                 messages: convo("th_demo_jonah", network: "telegram", endAgo: 95, [
                    ("Jonah Reyes", "Drinks at the usual place?", nil),
                    (nil, "Sounds good, see you at 7", nil),
                 ])),
            Spec(id: "th_demo_lena", title: "Lena Park", network: "messenger", avatar: ["token": "demo-avatar-lena"],
                 messages: convo("th_demo_lena", network: "messenger", endAgo: 140, [
                    ("Lena Park", "Did you get the train times?", nil),
                    (nil, "Sending the itinerary now", nil),
                 ]),
                 reaction: ("Lena", "❤️")),
            Spec(id: "th_demo_guild", title: "Design Guild", kind: "group", network: "discord", avatar: ["monogram": "DG"],
                 unread: 7, urgency: "fyi",
                 messages: convo("th_demo_guild", network: "discord", endAgo: 210, [
                    ("Rowan Ellis", "Review at 3?", nil),
                    ("Sam Ortiz", "Shipped the new icon set 🎉", nil),
                 ])),
            Spec(id: "th_demo_billing", title: "billing@northwind.example.test", titleSource: "email", network: "email",
                 avatar: ["monogram": "B"], unread: 1, urgency: "needs-reply",
                 messages: convo("th_demo_billing", network: "email", endAgo: 60 * 9, [
                    ("Northwind Billing", "Your November invoice is ready", nil),
                 ])),
            Spec(id: "th_demo_stranger", title: "+1 (555) 010-4477", titleSource: "handle", network: "whatsapp",
                 avatar: ["monogram": "#"], folder: "unknown", unread: 1,
                 messages: convo("th_demo_stranger", network: "whatsapp", endAgo: 60 * 11, [
                    ("+1 (555) 010-4477", "Hi! Is the bike still for sale?", nil),
                 ])),
            Spec(id: "th_demo_deals", title: "Coastline Deals", kind: "group", network: "telegram", avatar: ["monogram": "CD"],
                 folder: "low", muted: true,
                 messages: convo("th_demo_deals", network: "telegram", endAgo: 60 * 20, [
                    ("Coastline Deals", "Weekend sale: 20% off all kayaks", nil),
                 ])),
            Spec(id: "th_demo_roommates", title: "Old Roommates", kind: "group", network: "whatsapp", avatar: ["monogram": "OR"],
                 folder: "archived",
                 messages: convo("th_demo_roommates", network: "whatsapp", endAgo: 60 * 50, [
                    (nil, "Did anyone sign the renewal?", nil),
                    ("Ana Ruiz", nil, pdf),
                 ])),
            Spec(id: "th_demo_prize", title: "+1 (555) 019-2020", titleSource: "handle", network: "sms", avatar: ["monogram": "#"],
                 folder: "spam",
                 messages: convo("th_demo_prize", network: "sms", endAgo: 60 * 70, [
                    ("+1 (555) 019-2020", "Congratulations! You won a $500 gift card. Claim at prize.example.test", nil),
                 ])),
        ]
        // Two more conversations with people already in the list, so their contact cards
        // show "Conversations" across networks (DemoPeople).
        let extra: [Spec] = [
            Spec(id: "th_demo_alice_tg", title: "Alice Example", network: "telegram", avatar: ["monogram": "AE"],
                 messages: convo("th_demo_alice_tg", network: "telegram", endAgo: 60 * 26, [
                    ("Alice Example", "Sent you the trail map on here too", nil),
                    (nil, "Got it, thanks!", nil),
                 ])),
            Spec(id: "th_demo_maya_wa", title: "Maya Okafor", network: "whatsapp", avatar: ["token": "demo-avatar-maya"],
                 messages: convo("th_demo_maya_wa", network: "whatsapp", endAgo: 60 * 30, [
                    ("Maya Okafor", "Here's the recipe I mentioned", nil),
                 ])),
        ]
        /// Synthetic reactions on a few messages (the reaction details list shows these names).
        func reacting(_ messages: [CommsMessage], _ index: Int, _ reactions: [FixtureMessages.Reaction]) -> [CommsMessage] {
            var out = messages
            guard out.indices.contains(index) else { return out }
            let net = out[index].channel.network.wire
            out[index].reactions = reactions.map { r in
                let others = r.names.map { n in CommsReaction.Sender(id: "@\(net)_\(n.lowercased().filter(\.isLetter)):example.test", name: n) }
                return CommsReaction(key: r.key, count: r.count, mine: r.mine,
                                     senders: (r.mine ? [.init(id: FixtureMessages.selfID, name: "Me")] : []) + others)
            }
            return out
        }
        let decorated = (specs + extra).map { spec -> Spec in
            var s = spec
            switch s.id {
            case "th_demo_climbers":
                s.messages = reacting(s.messages, 0, [.init("👍", count: 2, names: ["Eli Brandt", "Priya Natarajan"])])
                s.messages = reacting(s.messages, 1, [.init("❤️", count: 2, names: ["Noor Haddad", "Eli Brandt"]), .init("😂", names: ["Priya Natarajan"])])
            case "th_demo_lena":
                s.messages = reacting(s.messages, 1, [.init("❤️", names: ["Lena Park"])])
            case "th_demo_guild":
                s.messages = reacting(s.messages, 1, [.init("🎉", count: 2, mine: true, names: ["Rowan Ellis"])])
            default: break
            }
            return s
        }
        return decorated.map { spec in
            var s = spec
            s.status = DemoPeople.statuses[s.id]
            s.personId = DemoPeople.threadPeople[s.id]
            return (thread(s), s.messages)
        }
    }

    static func thread(_ s: Spec) -> CommsThread {
        let newest = s.messages.last!
        let isGroup = s.kind == "group"
        let text = s.reaction.map { DemoPreview.text(newest, senderFirstName: $0.name, isGroup: isGroup, reactionKey: $0.key) }
            ?? DemoPreview.text(newest, senderFirstName: DemoPreview.firstName(newest.sender.name), isGroup: isGroup)
        let iso = { (d: Date) in d.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
        var preview: [String: Any] = ["text": text, "isSelf": s.reaction == nil && newest.sender.isSelf, "sentAt": iso(newest.sentAt)]
        if s.reaction == nil, !newest.sender.isSelf { preview["senderName"] = newest.sender.name }
        if let r = s.reaction { preview["senderName"] = r.name }
        var json: [String: Any] = [
            "id": s.id, "title": s.title, "titleSource": s.titleSource, "avatar": s.avatar, "kind": s.kind,
            "networks": [s.network], "lastMessage": preview, "lastActivityAt": iso(newest.sentAt),
            "unread": ["count": s.unread, "trusted": true], "folder": s.folder,
            "pinned": s.pinned, "muted": s.muted,
            "channels": [["network": s.network, "accountLabel": NSNull(),
                          "capabilities": ["react": DemoBackend.demoCanReact(network: s.network), "edit": true, "unsend": true, "reply": true,
                                           "typing": false, "receipts": true, "attachments": true,
                                           // Demo: every network but SMS and email can send (the
                                           // live server says false for iMessage until BlueBubbles).
                                           "send": DemoBackend.demoCanSend(network: s.network),
                                           // As the server: bridges that turn pills into mentions.
                                           "mentions": DemoBackend.demoCanMention(network: s.network)]]],
        ]
        json["urgency"] = s.urgency ?? NSNull()
        if let status = s.status { json["status"] = status }
        if let personId = s.personId { json["personId"] = personId }
        return FixtureMessages.decode(CommsThread.self, json)
    }

    /// PNG bytes for the demo's photo tokens (soft gradients with a head-and-shoulders shape,
    /// or a landscape for the shared photo). Synthetic: no real faces or places.
    /// The demo's HEIC photo (Maya's thread): a synthetic landscape encoded as HEIC.
    static let heicToken = "demo-photo-heic"
    static let heicData: Data? = Bundle.module.url(forResource: "demo-photo", withExtension: "heic", subdirectory: "Fixtures")
        .flatMap { try? Data(contentsOf: $0) }

    static func media(_ token: String) -> Data? {
        let base = token.hasSuffix("_thumb") ? String(token.dropLast(6)) : token
        if base == heicToken { return heicData }
        guard let hue = photoHues[base] else { return nil }
        return png(hue: hue, landscape: base.hasPrefix("demo-photo"))
    }

    private static func png(hue: Double, landscape: Bool) -> Data? {
        let w = landscape ? 480 : 160, h = landscape ? 360 : 160
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func rgb(_ h: Double, _ s: Double, _ v: Double) -> CGColor {
            let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
            let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
            let (r, g, b): (Double, Double, Double) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
            return CGColor(colorSpace: space, components: [r, g, b, 1])!
        }
        let W = Double(w), H = Double(h)
        if landscape {
            let sky = CGGradient(colorsSpace: space, colors: [rgb(0.58, 0.25, 0.98), rgb(0.58, 0.55, 0.85)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
            ctx.setFillColor(rgb(hue, 0.45, 0.55))
            ctx.move(to: CGPoint(x: 0, y: 0)); ctx.addLine(to: CGPoint(x: W * 0.35, y: H * 0.72))
            ctx.addLine(to: CGPoint(x: W * 0.6, y: H * 0.4)); ctx.addLine(to: CGPoint(x: W * 0.82, y: H * 0.62))
            ctx.addLine(to: CGPoint(x: W, y: H * 0.3)); ctx.addLine(to: CGPoint(x: W, y: 0)); ctx.closePath(); ctx.fillPath()
        } else {
            let g = CGGradient(colorsSpace: space, colors: [rgb(hue, 0.35, 0.98), rgb(hue, 0.65, 0.78)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
            ctx.setFillColor(rgb(hue, 0.15, 1))
            ctx.fillEllipse(in: CGRect(x: W * 0.32, y: H * 0.42, width: W * 0.36, height: H * 0.36))
            ctx.fillEllipse(in: CGRect(x: W * 0.16, y: -H * 0.3, width: W * 0.68, height: H * 0.62))
        }
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

/// The server's `previewText` (prism `apps/server/src/comms/naming.ts`), for demo data: a
/// thread's one-line preview of its latest event.
public enum DemoPreview {
    static let tapbackVerb: [String: String] = [
        "❤️": "loved", "❤": "loved", "👍": "liked", "👎": "disliked", "😂": "laughed at", "‼️": "emphasized", "❓": "questioned",
    ]

    public static func firstName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func clipQuote(_ text: String) -> String {
        let cps = Array(collapse(text).unicodeScalars)
        return cps.count > 24 ? String(String.UnicodeScalarView(cps.prefix(24))) + "…" : String(String.UnicodeScalarView(cps))
    }

    static func clock(_ ms: Int) -> String {
        let total = max(0, Int((Double(ms) / 1000).rounded()))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    public static func text(_ m: CommsMessage, senderFirstName: String, isGroup: Bool, reactionKey: String? = nil) -> String {
        let quoted = clipQuote(m.body?.plain ?? m.email?.subject ?? "")
        if let reactionKey {
            let target = quoted.isEmpty ? " a message" : " “\(quoted)”"
            if let verb = tapbackVerb[reactionKey] { return "\(senderFirstName) \(verb)\(target)" }
            return "\(senderFirstName) reacted \(reactionKey) to\(target)"
        }
        let caption = collapse(m.body?.plain ?? "")
        let text: String
        if m.redacted {
            text = "Message deleted"
        } else if let system = m.system {
            text = system.text
        } else if let a = m.attachments.first {
            let label: String
            switch a.kind {
            case .image: label = "📷 Photo"
            case .video: label = "🎥 Video"
            case .voice: label = "Voice message \(clock(a.durationMs ?? 0))"
            case .audio: label = "🎵 Audio"
            case .sticker: label = "Sticker"
            case .location: label = "📍 Location"
            default: label = "📎 \(a.name ?? "File")"
            }
            text = !caption.isEmpty && a.kind != .voice && a.kind != .file ? "\(label) \(caption)" : label
        } else {
            text = caption.isEmpty ? (m.email?.subject ?? "") : caption
        }
        return isGroup && !m.sender.isSelf && !senderFirstName.isEmpty ? "\(senderFirstName): \(text)" : text
    }
}
