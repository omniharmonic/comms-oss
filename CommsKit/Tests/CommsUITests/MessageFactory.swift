import Foundation
import PrismModels

/// Builds synthetic `CommsMessage`s for tests. The wire models have no public memberwise
/// initialisers, so this assembles the server's JSON and decodes it. Synthetic data only.
enum MessageFactory {
    static let selfID = "@owner:example.test"

    struct Reaction {
        var key: String
        var count = 1
        var mine = false
        /// Other reactors' names; padded with "Sender i" up to `count` (the owner, when
        /// `mine`, is a sender with id `selfID`, as the server sends it).
        var names: [String] = []
    }

    static func senders(_ r: Reaction) -> [[String: Any]] {
        var out: [[String: Any]] = r.mine ? [["id": selfID, "name": "Owner"]] : []
        var i = 0
        while out.count < r.count {
            let name = i < r.names.count ? r.names[i] : "Sender \(i)"
            out.append(["id": "@s\(i):example.test", "name": name])
            i += 1
        }
        return out
    }

    static func message(
        id: String = "$m1",
        network: String = "imessage",
        outgoing: Bool = false,
        sender: String = "Alex",
        text: String? = nil,
        spans: [CommsSpan]? = nil,
        jumboEmoji: Bool = false,
        attachments: [[String: Any]] = [],
        linkPreviews: [[String: Any]] = [],
        reactions: [Reaction] = [],
        redacted: Bool = false,
        system: (kind: String, text: String)? = nil,
        replyTo: (sender: String, snippet: String)? = nil
    ) -> CommsMessage {
        var json: [String: Any] = [
            "id": id,
            "threadId": "th_test",
            "channel": ["network": network],
            "source": ["network": network, "eventId": id, "ref": id],
            "sender": [
                "id": outgoing ? selfID : "@\(network)_1:example.test",
                "name": outgoing ? "Me" : sender,
                "isSelf": outgoing,
                "isOmni": false,
            ],
            "sentAt": "2026-11-21T09:30:00.000Z",
            "attachments": attachments,
            "linkPreviews": linkPreviews,
            "reactions": reactions.map { r -> [String: Any] in
                [
                    "key": r.key, "count": r.count, "mine": r.mine,
                    "senders": senders(r),
                ]
            },
            "redacted": redacted,
        ]
        if let system { json["system"] = ["kind": system.kind, "text": system.text] }
        if let replyTo { json["replyTo"] = ["messageId": "$parent", "snippet": replyTo.snippet, "senderName": replyTo.sender] }
        if text != nil || spans != nil {
            let body = CommsRichText(
                spans: spans ?? [.text(text ?? "")],
                plain: text ?? plain(spans ?? []),
                jumboEmoji: jumboEmoji
            )
            json["body"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(body))
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! PrismJSON.decoder().decode(CommsMessage.self, from: data)
    }

    static func image(token: String = "tok_photo", w: Int, h: Int) -> [String: Any] {
        ["kind": "image", "mime": "image/jpeg", "w": w, "h": h, "mediaToken": token, "thumbToken": token + "_thumb"]
    }

    private static func plain(_ spans: [CommsSpan]) -> String {
        spans.map { span -> String in
            switch span {
            case .text(let s), .pre(let s): return s
            case .bold(let c), .italic(let c), .strike(let c), .code(let c), .quote(let c), .listItem(let c):
                return plain(c)
            case .link(_, let c): return plain(c)
            case .mention(_, let name): return name
            case .br: return "\n"
            case .unknown: return ""
            }
        }.joined()
    }
}
