import CommsClient
import Foundation

/// One way to call or reach someone from Comms' call menus (owner's choice 2026-11-22:
/// "Offer a menu"). Comms never places a call itself: every option is a URL the system
/// hands to FaceTime, Phone or the network's own app.
public struct CallOption: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable, Hashable { case audio, video, app }

    public var title: String
    /// The number or address it goes to (shown under the title when there are several).
    public var detail: String?
    public var systemImage: String
    public var url: URL
    public var kind: Kind

    public var id: String { "\(kind)|\(url.absoluteString)" }

    public init(title: String, detail: String? = nil, systemImage: String, url: URL, kind: Kind) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.url = url
        self.kind = kind
    }
}

extension CommsContact {
    /// This contact with `other`'s phones, emails and handles added (deduplicated, this
    /// contact's first). Details unions the thread's own contact with the person's: the
    /// person page can lack a DM counterpart's ghost facts the thread detail carries, and an
    /// empty person contact must never hide what the toolbar offers.
    public func merged(with other: CommsContact?) -> CommsContact {
        guard let other else { return self }
        func key(_ p: CommsContactPoint) -> String { p.value.lowercased().filter { !" -().".contains($0) } }
        var phones = self.phones, emails = self.emails, handles = self.handles
        var seen = Set(phones.map(key))
        for p in other.phones where seen.insert(key(p)).inserted { phones.append(p) }
        seen = Set(emails.map(key))
        for e in other.emails where seen.insert(key(e)).inserted { emails.append(e) }
        func hkey(_ h: CommsHandle) -> String { "\(h.network.wire)|\(h.kind.wire)|\(h.value.lowercased())" }
        seen = Set(handles.map(hkey))
        for h in other.handles where seen.insert(hkey(h)).inserted { handles.append(h) }
        return CommsContact(phones: phones, emails: emails, handles: handles)
    }
}

/// Builds the call menus from a contact (pure; contract §3).
///
/// Order: for each phone FaceTime Audio, FaceTime, Phone; for each email FaceTime Audio,
/// FaceTime; then "Open in <App>" for each network handle (handles on the conversation's own
/// networks first). Deep links used — each from the network's own documentation:
/// - FaceTime / FaceTime Audio / Phone: Apple's `facetime://`, `facetime-audio://`, `tel:`.
/// - WhatsApp: `https://wa.me/<number>` (WhatsApp Help Center "click to chat").
/// - Telegram: `tg://resolve?domain=<username>` and `tg://resolve?phone=<number>`
///   (core.telegram.org/api/links), `tg://user?id=<id>` (Bot API mention links).
/// - Signal: `https://signal.me/#p/<+number>` (the link Signal's apps generate and open).
/// - Slack: `slack://user?team=<TEAM>&id=<USER>` (Slack deep-linking reference).
/// - X: `https://x.com/messages/compose?recipient_id=<id>` (X for Websites, DM button).
/// - Instagram: `https://ig.me/m/<username>` (Meta's Instagram Messaging "ig.me links").
/// - LinkedIn: `https://www.linkedin.com/in/<public id>` (the public profile URL; LinkedIn
///   documents no messaging link). Only for a public id (`username`), never a member URN.
/// Discord and Messenger have no documented link to a person, so they offer none.
public enum CallRoutes {
    public static func options(contact: CommsContact?, networks: [CommsNetwork] = []) -> [CallOption] {
        guard let contact else { return [] }
        var out: [CallOption] = []
        var seen = Set<String>()
        func add(_ o: CallOption?) { if let o, seen.insert(o.id).inserted { out.append(o) } }

        let phones = contact.phones.compactMap { p in phoneNumber(p.value).map { ($0, p.label) } }
        let emails = contact.emails.compactMap { e in emailAddress(e.value).map { ($0, e.label) } }
        for (number, _) in phones {
            add(url("facetime-audio://\(number)").map { CallOption(title: "FaceTime Audio", detail: number, systemImage: "phone", url: $0, kind: .audio) })
            add(url("facetime://\(number)").map { CallOption(title: "FaceTime", detail: number, systemImage: "video", url: $0, kind: .video) })
            add(url("tel:\(number)").map { CallOption(title: "Phone", detail: number, systemImage: "phone.arrow.up.right", url: $0, kind: .audio) })
        }
        for (address, _) in emails {
            add(url("facetime-audio://\(address)").map { CallOption(title: "FaceTime Audio", detail: address, systemImage: "phone", url: $0, kind: .audio) })
            add(url("facetime://\(address)").map { CallOption(title: "FaceTime", detail: address, systemImage: "video", url: $0, kind: .video) })
        }
        // Handles on this conversation's networks first, then the rest, each in server order.
        let ranked = contact.handles.enumerated().sorted { a, b in
            let ia = networks.firstIndex(of: a.element.network) ?? Int.max
            let ib = networks.firstIndex(of: b.element.network) ?? Int.max
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map(\.element)
        for h in ranked { add(appOption(h)) }
        return out
    }

    /// The audio button's menu: audio calls, then the apps.
    public static func audio(_ options: [CallOption]) -> [CallOption] {
        options.filter { $0.kind == .audio } + options.filter { $0.kind == .app }
    }

    /// The video button's menu: video calls, then the apps.
    public static func video(_ options: [CallOption]) -> [CallOption] {
        options.filter { $0.kind == .video } + options.filter { $0.kind == .app }
    }

    /// The first email address, for the Details card's mail button.
    public static func mail(contact: CommsContact?) -> URL? {
        contact?.emails.lazy.compactMap { emailAddress($0.value) }.first.flatMap { url("mailto:\($0)") }
    }

    // MARK: Apps

    static func appOption(_ h: CommsHandle) -> CallOption? {
        func app(_ name: String, _ link: URL?) -> CallOption? {
            link.map { CallOption(title: "Open in \(name)", detail: h.value, systemImage: "arrow.up.forward.app", url: $0, kind: .app) }
        }
        switch (h.network, h.kind) {
        case (.whatsapp, .phone):
            return phoneNumber(h.value).flatMap { app("WhatsApp", url("https://wa.me/\($0.dropFirst())")) }
        case (.unknown("signal"), .phone):
            return phoneNumber(h.value).flatMap { app("Signal", url("https://signal.me/#p/\($0)")) }
        case (.telegram, .username):
            let name = h.value.hasPrefix("@") ? String(h.value.dropFirst()) : h.value
            guard name.matchesWhole(#"[A-Za-z][A-Za-z0-9_]{3,31}"#) else { return nil }
            return app("Telegram", url("tg://resolve?domain=\(name)"))
        case (.telegram, .phone):
            return phoneNumber(h.value).flatMap { app("Telegram", url("tg://resolve?phone=\($0.dropFirst())")) }
        case (.telegram, .userId):
            return digits(h.value).flatMap { app("Telegram", url("tg://user?id=\($0)")) }
        case (.unknown("slack"), .userId):
            // The server writes Slack ids as "TEAM-USER" (bridge ghost localpart).
            let parts = h.value.uppercased().split(separator: "-")
            guard parts.count == 2, parts.allSatisfy({ $0.matchesWhole(#"[A-Z0-9]{2,32}"#) }),
                  parts[0].hasPrefix("T") || parts[0].hasPrefix("E") else { return nil }
            return app("Slack", url("slack://user?team=\(parts[0])&id=\(parts[1])"))
        case (.instagram, .username):
            let name = h.value.hasPrefix("@") ? String(h.value.dropFirst()) : h.value
            guard name.matchesWhole(#"[A-Za-z0-9._]{1,30}"#) else { return nil }
            return app("Instagram", url("https://ig.me/m/\(name)"))
        case (.linkedin, .username):
            guard h.value.matchesWhole(#"[A-Za-z0-9-]{3,100}"#) else { return nil }
            return app("LinkedIn", url("https://www.linkedin.com/in/\(h.value)"))
        case (.x, .userId):
            return digits(h.value).flatMap { app("X", url("https://x.com/messages/compose?recipient_id=\($0)")) }
        default:
            return nil
        }
    }

    // MARK: Values (strict: anything else offers nothing)

    /// `+` and 7–15 digits (E.164) from a stored number; spaces, dashes, dots and brackets dropped.
    static func phoneNumber(_ raw: String) -> String? {
        let kept = raw.filter { !" -().\u{00A0}".contains($0) }
        let body = kept.hasPrefix("+") ? kept.dropFirst() : Substring(kept)
        // E.164: no country code starts with 0 (a "00…" international prefix is not E.164).
        guard (7...15).contains(body.count), body.first != "0", body.allSatisfy(\.isASCII), body.allSatisfy(\.isNumber) else { return nil }
        return "+" + body
    }

    static func emailAddress(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard v.count <= 254, v.matchesWhole(CallLinks.email) else { return nil }
        return v
    }

    static func digits(_ raw: String) -> String? {
        (1...20).contains(raw.count) && raw.allSatisfy({ $0.isASCII && $0.isNumber }) ? raw : nil
    }

    static func url(_ s: String) -> URL? { URL(string: s) }
}

/// The exact URL shapes call menus may open — separate from message links (`SafeLinks`),
/// which open only http(s). Each is matched against the WHOLE string (`\A…\z`): what a
/// `CallOption` builds passes, any other host, path, query or trailing byte does not.
public enum CallLinks {
    static let e164 = #"\+[1-9][0-9]{6,14}"#
    /// No `%` in the local part: a percent-escape would be decoded differently from what
    /// the menu shows.
    static let email = #"[A-Za-z0-9._+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#
    static let shapes: [String] = [
        #"tel:"# + e164,
        #"facetime(-audio)?://("# + e164 + "|" + email + ")",
        #"mailto:"# + email,
        #"tg://resolve\?domain=[A-Za-z][A-Za-z0-9_]{3,31}"#,
        #"tg://resolve\?phone=[1-9][0-9]{6,14}"#,
        #"tg://user\?id=[0-9]{1,20}"#,
        #"slack://user\?team=[A-Z0-9]{2,32}&id=[A-Z0-9]{2,32}"#,
        #"https://wa\.me/[1-9][0-9]{6,14}"#,
        #"https://signal\.me/#p/"# + e164,
        #"https://x\.com/messages/compose\?recipient_id=[0-9]{1,20}"#,
        #"https://ig\.me/m/[A-Za-z0-9._]{1,30}"#,
        #"https://www\.linkedin\.com/in/[A-Za-z0-9-]{3,100}"#,
    ]

    public static func isAllowed(_ url: URL) -> Bool {
        let s = url.absoluteString
        return shapes.contains { s.matchesWhole($0) }
    }
}

extension StringProtocol {
    /// Whether the whole string (no trailing newline) matches `pattern`.
    func matchesWhole(_ pattern: String) -> Bool {
        range(of: #"\A(?:"# + pattern + #")\z"#, options: .regularExpression) != nil
    }
}
